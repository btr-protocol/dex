import { getStorage } from '../storage.js';
import type { AgentConfig, KnowledgeChunk, FileDigest } from '@shared/types';
import { getEmbeddingProvider } from '../providers.js';
import { getVectorDB } from './vector.js';
import { knowledgeConfig, embeddingChunkingConfig, embeddingConfig } from './config.js';
import { loadDigestCache, saveDigestBatch } from './digest-storage.js';
import { glob } from 'glob';
import { createHash } from 'crypto';
import { logger } from '@btr/sdk/utils';
import { PROJECT_ROOT, inferLanguage, inferSourceType } from './utils.js';
import { ensureStorageDirectories } from './storage-init.js';

const log = logger.withContext('indexer');

const FILE_PROCESSING_CONCURRENCY = 10;

async function computeFileDigest(filePath: string): Promise<string> {
  const content = await Bun.file(filePath).text();
  return createHash('sha256').update(content).digest('hex');
}

async function getFileInfo(filePath: string): Promise<{ size: number; lastModified: number }> {
  const file = Bun.file(filePath);
  return {
    size: file.size,
    lastModified: file.lastModified
  };
}

/**
 * Index knowledge using the shared knowledge config.
 * Supports both agent-specific configs and the shared search config.
 */
export async function indexKnowledge(agentId: string, forceReindex = false): Promise<void> {
  await ensureStorageDirectories();
  
  const storage = await getStorage();
  const agentConfig = storage.getAgent(agentId);

  // Use agent config if available, otherwise fall back to shared config
  const knowledge = agentConfig?.knowledge?.include?.length
    ? agentConfig.knowledge
    : knowledgeConfig;

  const chunking = agentConfig?.chunking || embeddingChunkingConfig;

  log.info(`═══════════════════════════════════════════════════════════════`);
  log.info(`📚 INDEXING KNOWLEDGE${forceReindex ? ' (FORCED)' : ''}`);
  log.info(`═══════════════════════════════════════════════════════════════`);
  log.info(`   Agent: ${agentId}`);
  log.info(`   Patterns: ${knowledge.include.join(', ')}`);
  log.info(`   Chunk size: ${chunking.chunkSize}, overlap: ${chunking.overlap}`);
  log.info(`   Embedding: ${embeddingConfig.model} (${embeddingConfig.dimensions}D)`);
  log.info('');

  const startTime = performance.now();

  // Load existing digest cache
  const digestCache = await loadDigestCache();
  const newDigestCache = new Map<string, FileDigest>();

  // Collect all files
  const allFiles: string[] = [];
  for (const includePattern of knowledge.include) {
    const files = await glob(includePattern, {
      cwd: PROJECT_ROOT,
      ignore: knowledge.exclude,
      absolute: true
    });
    log.info(`   Found ${files.length} files matching: ${includePattern}`);
    allFiles.push(...files);
  }

  log.info(`\n┌─ PROCESSING ${allFiles.length} FILES ──────────────────────────────`);

  // Process files in parallel batches
  const fileResults: Array<{
    filePath: string;
    chunks: KnowledgeChunk[];
    oldDigest: string | undefined;  // Previous digest if file was modified
    digest: string;
    fileInfo: { size: number; lastModified: number };
    skipped: boolean;
  }> = [];

  for (let i = 0; i < allFiles.length; i += FILE_PROCESSING_CONCURRENCY) {
    const batch = allFiles.slice(i, Math.min(i + FILE_PROCESSING_CONCURRENCY, allFiles.length));

    const batchResults = await Promise.all(
      batch.map(async (filePath) => {
        const fileName = filePath.split('/').pop() || filePath;

        try {
          const currentDigest = await computeFileDigest(filePath);
          const fileInfo = await getFileInfo(filePath);
          const cachedDigest = digestCache.get(filePath);

          // Skip if unchanged (unless force reindex)
          if (!forceReindex && cachedDigest && cachedDigest.digest === currentDigest) {
            newDigestCache.set(filePath, cachedDigest);
            return { filePath, chunks: [], oldDigest: undefined, digest: currentDigest, fileInfo, skipped: true };
          }

          // File is new or modified - track the old digest for cleanup
          const oldDigest = cachedDigest?.digest;  // undefined if new file

          // Process changed/new file
          const chunks = await chunkFile(filePath, { chunking } as AgentConfig, currentDigest);
          newDigestCache.set(filePath, {
            path: filePath,
            digest: currentDigest,
            size: fileInfo.size,
            lastModified: fileInfo.lastModified,
            chunkCount: chunks.length
          });

          return { filePath, chunks, oldDigest, digest: currentDigest, fileInfo, skipped: false };
        } catch (error) {
          log.warn(`   ⚠️  Error processing ${fileName}: ${error}`);
          return { filePath, chunks: [], oldDigest: undefined, digest: '', fileInfo: { size: 0, lastModified: 0 }, skipped: true };
        }
      })
    );

    fileResults.push(...batchResults);

    // Progress update
    const progress = Math.min(i + FILE_PROCESSING_CONCURRENCY, allFiles.length);
    const pct = ((progress / allFiles.length) * 100).toFixed(1);
    log.info(`   [${pct}%] Processed ${progress}/${allFiles.length} files`);
  }

  // Collect all chunks from processed files
  const chunks: KnowledgeChunk[] = [];
  let skippedCount = 0;
  let processedCount = 0;

  for (const result of fileResults) {
    if (result.skipped) {
      skippedCount++;
    } else {
      processedCount++;
      chunks.push(...result.chunks);
    }
  }

  log.info(`\n┌─ SUMMARY ────────────────────────────────────────────────────`);
  log.info(`   Files processed: ${processedCount}`);
  log.info(`   Files skipped (unchanged): ${skippedCount}`);
  log.info(`   Total chunks: ${chunks.length}`);

  if (chunks.length > 0) {
    // First, delete old chunks for modified files
    const vectorDB = getVectorDB();
    const modifiedFiles = fileResults.filter(r => !r.skipped && r.oldDigest);
    if (modifiedFiles.length > 0) {
      log.info(`\n┌─ CLEANING UP STALE CHUNKS ──────────────────────────────────`);
      let deletedCount = 0;
      for (const result of modifiedFiles) {
        const deleted = await vectorDB.deleteChunksByFileDigest(result.filePath, result.oldDigest!);
        deletedCount += deleted;
      }
      log.info(`   ✓ Deleted ${deletedCount} stale chunks from ${modifiedFiles.length} modified files`);
    }

    log.info(`\n┌─ GENERATING EMBEDDINGS ──────────────────────────────────────`);
    const embeddingStart = performance.now();

    const provider = await getEmbeddingProvider();
    const texts = chunks.map(c => c.text);

    // Show progress for large batches
    if (chunks.length > 50) {
      log.info(`   Processing ${chunks.length} chunks...`);
    }

    const embeddings = await provider.generateEmbeddings(texts);

    for (let i = 0; i < chunks.length; i++) {
      const embedding = embeddings[i];
      if (embedding) {
        chunks[i]!.vector = embedding;
      }
    }

    const embeddingDuration = performance.now() - embeddingStart;
    log.info(`   ✓ Generated ${embeddings.length} embeddings in ${(embeddingDuration / 1000).toFixed(1)}s`);

    log.info(`\n┌─ STORING IN VECTOR DB ───────────────────────────────────────`);
    const storeStart = performance.now();
    await vectorDB.addChunks(chunks);
    const storeDuration = performance.now() - storeStart;
    log.info(`   ✓ Stored ${chunks.length} chunks in ${(storeDuration / 1000).toFixed(1)}s`);
  } else {
    log.info('   No new or changed files to index');
  }

  // Save updated digest cache to SQLite
  await saveDigestBatch(Array.from(newDigestCache.entries()));

  const totalDuration = performance.now() - startTime;
  log.info(`\n═══════════════════════════════════════════════════════════════`);
  log.info(`✅ INDEXING COMPLETE`);
  log.info(`   Total time: ${(totalDuration / 1000).toFixed(1)}s`);
  log.info(`   Chunks indexed: ${chunks.length}`);
  log.info(`═══════════════════════════════════════════════════════════════\n`);
}

async function chunkFile(filePath: string, config: AgentConfig, fileDigest: string): Promise<KnowledgeChunk[]> {
  try {
    const content = await Bun.file(filePath).text();
    const { chunkSize, overlap } = config.chunking;

    // Extract location info aligned with SearchResultLocation
    const language = inferLanguage(filePath);
    const type = inferSourceType(filePath);
    const section = extractSection(content, 0);

    const chunks: KnowledgeChunk[] = [];
    let offset = 0;

    while (offset < content.length) {
      const end = Math.min(offset + chunkSize, content.length);
      const chunkText = content.slice(offset, end);

      if (chunkText.trim().length >= config.chunking.minChunkSize) {
        chunks.push({
          id: 0,
          vector: [],
          text: chunkText.trim(),
          language,
          type,
          file: filePath,
          section,
          indexedAt: new Date().toISOString(),
          fileDigest
        });
      }

      if (end >= content.length) {
        break;
      }

      offset += chunkSize - overlap;
    }

    return chunks;
  } catch (error) {
    log.warn(`Error chunking ${filePath}: ${error}`);
    return [];
  }
}

function extractSection(content: string, offset: number): string {
  const before = content.slice(Math.max(0, offset - 100), offset);
  const match = before.match(/#{1,3}\s+(.+)/g);
  return match ? match[match.length - 1]!.slice(2).trim() : '';
}

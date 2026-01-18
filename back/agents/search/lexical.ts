import { glob } from 'glob';
import { log } from '../../shared/logger.js';

import type { SearchResult, AgentConfig } from '../core/types.js';


/**
 * Find the project root by looking for package.json or markers.
 * This works regardless of where the server is started from.
 */
let cachedProjectRoot: string | null = null;
function getProjectRoot(): string {
  if (cachedProjectRoot) return cachedProjectRoot;

  // Start from current directory and search upward
  let currentDir = process.cwd();

  // If we're in back/agents, go up to project root
  if (currentDir.endsWith('/back/agents')) {
    cachedProjectRoot = currentDir.replace(/\/back\/agents$/, '');
    return cachedProjectRoot;
  }

  // If we're in back/, go up one level
  if (currentDir.endsWith('/back')) {
    cachedProjectRoot = currentDir.replace(/\/back$/, '');
    return cachedProjectRoot;
  }

  // Search upward for markers (package.json at root, contracts/, docs/, etc.)
  const maxIterations = 10;
  for (let i = 0; i < maxIterations; i++) {
    try {
      // Check for root markers
      const hasPackageJson = Bun.file(`${currentDir}/package.json`).exists();
      const hasContracts = Bun.file(`${currentDir}/contracts`).exists();
      const hasDocs = Bun.file(`${currentDir}/docs`).exists();
      const hasFront = Bun.file(`${currentDir}/front`).exists();

      // If we find multiple markers, this is likely the project root
      if (hasPackageJson && (hasContracts || hasDocs || hasFront)) {
        cachedProjectRoot = currentDir;
        log(`Project root found: ${currentDir}`);
        return currentDir;
      }
    } catch {}

    // Go up one directory
    const parentDir = currentDir.split('/').slice(0, -1).join('/');
    if (parentDir === currentDir || !parentDir) break; // Reached root
    currentDir = parentDir;
  }

  // Fallback: assume we're in the project root
  log(`Using current directory as project root: ${process.cwd()}`);
  cachedProjectRoot = process.cwd();
  return cachedProjectRoot;
}

/**
 * BM25 ranking algorithm parameters
 * Based on Robertson-Sparck Jones IDF with saturation
 */
const BM25_PARAMS = {
  k1: 1.2,  // Term frequency saturation parameter (1.0-2.0 typical)
  b: 0.75,  // Length normalization parameter (0.0-1.0, 0.75 is standard)
} as const;

/**
 * Document representation for BM25 indexing
 */
interface LexicalDocument {
  id: string;
  content: string;
  filePath: string;
  lineIndex: number;
  tokens: string[];
  tokenCount: number;
}

/**
 * BM25 index structure
 */
interface BM25Index {
  documents: Map<string, LexicalDocument>;
  inverseDocumentFrequency: Map<string, number>;
  averageDocumentLength: number;
  totalDocuments: number;
}

/**
 * Cached indices per agent
 */
const indexCache = new Map<string, BM25Index>();

/**
 * Tokenize text with proper handling for code and technical documentation.
 *
 * Handles:
 * - camelCase → camel case
 * - snake_case → snake case
 * - kebab-case → kebab case
 * - Technical terms with numbers (e.g., EIP-20, ERC721)
 *
 * @param text - The text to tokenize
 * @returns Array of normalized tokens
 */
function tokenize(text: string): string[] {
  // Normalize: lowercase and handle separators
  let normalized = text.toLowerCase();

  // Replace separators with spaces
  normalized = normalized
    .replace(/[-_/]/g, ' ')
    .replace(/([a-z])([A-Z])/g, '$1 $2');  // camelCase splitting

  // Extract alphanumeric tokens (preserves technical terms like EIP20, ERC721)
  const tokens = normalized.match(/[a-z0-9]+/g) || [];

  // Apply stemming to reduce inflectional forms
  return tokens.map(stemToken).filter(t => t.length >= 2);
}

/**
 * Apply Porter-style stemming to reduce words to root form.
 *
 * Examples:
 * - "pricing" → "price"
 * - "liquidity" → "liquid"
 * - "trading" → "trade"
 *
 * Preserves technical terms that shouldn't be stemmed.
 */
function stemToken(word: string): string {
  if (word.length <= 3) return word;

  // Preserve common technical acronyms and terms
  const preserveTerms = ['amm', 'clmm', 'lvr', 'twap', 'vwap', 'eth', 'usdc', 'usdt', 'wbtc', 'weth'];
  if (preserveTerms.includes(word)) return word;

  // Remove common suffixes (simplified Porter stemming)
  const suffixes = [
    'ing',   // pricing → pric(ing)
    'ly',    // quickly → quick
    'ed',    // priced → pric(ed) (but careful with past tense)
    'ies',   // policies → polic(ies)
    'es',    // taxes → tax
    's',     // tokens → token
    'ment',  // deployment → deploy(ment)
    'ness',  // effectiveness → effect(ive)ness
    'tion',  // calculation → calcula(tion)
    'ation', // creation → crea(tion)
    'ition', // position → posi(tion)
    'ize',   // normalize → normal(ize)
    'ise',   // standardise → standard
    'ful',   // powerful → power
    'able',  // scalable → scal(able)
    'ible',  // visible → vis(ible)
  ];

  for (const suffix of suffixes) {
    if (word.endsWith(suffix) && word.length > suffix.length + 3) {
      return word.slice(0, -suffix.length);
    }
  }

  return word;
}

/**
 * Calculate Inverse Document Frequency (IDF) using Robertson-Sparck Jones variant.
 *
 * IDF(term) = log((N - df(term) + 0.5) / (df(term) + 0.5) + 1)
 *
 * Where N = total documents, df = document frequency
 */
function calculateInverseDocumentFrequency(totalDocuments: number, documentFrequency: number): number {
  if (documentFrequency === 0) return 0;
  return Math.log((totalDocuments - documentFrequency + 0.5) / (documentFrequency + 0.5) + 1);
}

/**
 * Build BM25 index from a collection of documents.
 *
 * Pre-computes:
 * - Token frequency per document
 * - Document frequency per term (how many docs contain each term)
 * - Inverse Document Frequency (IDF) for each term
 * - Average document length
 */
async function buildBM25Index(documents: LexicalDocument[]): Promise<BM25Index> {
  const inverseDocumentFrequency = new Map<string, number>();
  const totalDocuments = documents.length;
  const totalTokens = documents.reduce((sum, d) => sum + d.tokenCount, 0);
  const averageDocumentLength = totalTokens / totalDocuments;

  // Count document frequency for each unique term
  const termDocumentFrequency = new Map<string, number>();

  for (const doc of documents) {
    const uniqueTerms = new Set(doc.tokens);
    for (const term of uniqueTerms) {
      termDocumentFrequency.set(term, (termDocumentFrequency.get(term) || 0) + 1);
    }
  }

  // Calculate IDF for each term
  for (const [term, df] of termDocumentFrequency.entries()) {
    inverseDocumentFrequency.set(term, calculateInverseDocumentFrequency(totalDocuments, df));
  }

  return {
    documents: new Map(documents.map(d => [d.id, d])),
    inverseDocumentFrequency,
    averageDocumentLength,
    totalDocuments
  };
}

/**
 * Calculate BM25 score for a document given query terms.
 *
 * BM25 formula:
 * score(D,Q) = Σ IDF(qi) × (f(qi,D) × (k1 + 1)) / (f(qi,D) + k1 × (1 - b + b × |D|/avgDl))
 *
 * Where:
 * - qi = query term
 * - f(qi,D) = frequency of term in document
 * - |D| = document length
 * - avgDl = average document length
 */
function calculateBM25Score(
  document: LexicalDocument,
  queryTerms: Set<string>,
  inverseDocumentFrequency: Map<string, number>,
  averageDocumentLength: number
): number {
  let score = 0;

  for (const term of queryTerms) {
    if (!document.tokens.includes(term)) continue;

    const termFrequency = document.tokens.filter(t => t === term).length;
    const idf = inverseDocumentFrequency.get(term) || 0;

    const { k1, b } = BM25_PARAMS;
    const numerator = termFrequency * (k1 + 1);
    const denominator = termFrequency + k1 * (1 - b + b * (document.tokenCount / averageDocumentLength));

    score += idf * (numerator / denominator);
  }

  return score;
}

/**
 * Extract documents from files matching the knowledge config patterns.
 *
 * Files are chunked into sliding windows for granular retrieval.
 */
async function extractDocumentsFromConfig(config: AgentConfig): Promise<LexicalDocument[]> {
  const { knowledge } = config;
  if (!knowledge) return [];

  const documents: LexicalDocument[] = [];
  let docId = 0;

  // Get project root reliably
  const projectRoot = getProjectRoot();

  for (const includePattern of knowledge.include) {
    const files = await glob(includePattern, {
      cwd: projectRoot,
      ignore: knowledge.exclude,
      absolute: false
    });

    for (const file of files) {
      const absolutePath = `${projectRoot}/${file}`;
      try {
        const content = await Bun.file(absolutePath).text();
        const lines = content.split('\n');

        // Create overlapping windows for better context matching
        const windowSize = 5;
        const overlap = 2;

        for (let i = 0; i < lines.length; i += (windowSize - overlap)) {
          const windowLines = lines.slice(i, Math.min(i + windowSize, lines.length));
          const windowContent = windowLines.join('\n');

          // Skip sparse windows
          if (windowContent.trim().length < 20) continue;

          const tokens = tokenize(windowContent);

          documents.push({
            id: `${file}:${i}:${docId++}`,
            content: windowContent,
            filePath: file,
            lineIndex: i,
            tokens,
            tokenCount: tokens.length
          });
        }
      } catch (error) {
        log(`Error processing ${file}: ${error}`);
      }
    }
  }

  return documents;
}

/**
 * BM25-based lexical search with proper tokenization and ranking.
 *
 * This is a state-of-the-art lexical search algorithm that:
 * - Handles tokenization with stemming
 * - Ranks by TF-IDF with document length normalization
 * - Returns top-k results with relevance scores
 *
 * @param searchString - The search query (may include expanded terms)
 * @param config - Agent configuration with knowledge patterns
 * @returns Ranked search results
 */
export async function lexicalSearch(searchString: string, config?: AgentConfig): Promise<SearchResult[]> {
  if (!config) {
    const mod = await import('../core/storage.js');
    const storage = await mod.getStorage();
    const agentConfig = storage.getAgent('archivist');
    if (!agentConfig) {
      log('No archivist config found');
      return [];
    }
    config = agentConfig;
  }

  const cacheKey = config.agentId || 'archivist';
  let index = indexCache.get(cacheKey);

  // Build index if not cached
  if (!index) {
    log(`Building BM25 index for ${cacheKey}...`);
    const documents = await extractDocumentsFromConfig(config);
    index = await buildBM25Index(documents);
    indexCache.set(cacheKey, index);
    log(`BM25 index built: ${index.totalDocuments} documents, ${index.inverseDocumentFrequency.size} unique terms`);
  }

  // Tokenize search query
  const queryTerms = new Set(tokenize(searchString));
  log(`Lexical search with ${queryTerms.size} terms: [${[...queryTerms].join(', ')}]`);

  // Score all documents with progress logging
  const scoredDocuments: Array<{ doc: LexicalDocument; score: number }> = [];

  for (const [id, doc] of index.documents) {
    const score = calculateBM25Score(doc, queryTerms, index.inverseDocumentFrequency, index.averageDocumentLength);
    if (score > 0) {
      scoredDocuments.push({ doc, score });
    }
  }

  // Sort by BM25 score descending
  scoredDocuments.sort((a, b) => b.score - a.score);

  // Convert to SearchResult format
  const maxResults = config?.retrieval?.maxResults || 15;
  const results: SearchResult[] = [];

  for (const item of scoredDocuments.slice(0, maxResults)) {
    const { doc, score } = item;

    // Extract extended context for display
    const lines = await getFileLinesWithContext(doc.filePath, doc.lineIndex);
    const context = lines.join('\n');

    results.push({
      content: context || doc.content,
      sourceType: inferSourceType(doc.filePath),
      sourceRef: `${doc.filePath}:${doc.lineIndex + 1}`,
      metadata: {
        language: inferLanguage(doc.filePath),
        lineRange: [doc.lineIndex + 1, doc.lineIndex + lines.length] as [number, number],
        bm25Score: score,
        matchCount: [...queryTerms].filter(t => doc.tokens.includes(t)).length
      },
      score: Math.min(score / 10, 1.0)  // Normalize BM25 to 0-1 range
    });
  }

  log(`Lexical search complete: ${results.length} results (top BM25: ${scoredDocuments[0]?.score.toFixed(2) || 0})`);

  return results;
}

/**
 * Get file lines with surrounding context for result display.
 */
async function getFileLinesWithContext(filePath: string, lineIndex: number): Promise<string[]> {
  try {
    const projectRoot = getProjectRoot();
    const absolutePath = `${projectRoot}/${filePath}`;
    const content = await Bun.file(absolutePath).text();
    const lines = content.split('\n');
    // Return lines before and after the match for context
    return lines.slice(Math.max(0, lineIndex - 2), Math.min(lines.length, lineIndex + 8));
  } catch {
    return [];
  }
}

/**
 * Clear cached index (useful for rebuilds after file changes).
 */
export function clearLexicalIndex(agentId?: string): void {
  if (agentId) {
    indexCache.delete(agentId);
  } else {
    indexCache.clear();
  }
  // Also clear project root cache to force re-detection
  cachedProjectRoot = null;
  log(`Cleared lexical index${agentId ? ` for ${agentId}` : ''}`);
}

/**
 * Get index statistics for monitoring.
 */
export function getLexicalIndexStats(agentId: string): {
  totalDocuments: number;
  uniqueTerms: number;
  averageDocLength: number;
} | null {
  const index = indexCache.get(agentId);
  if (!index) return null;

  return {
    totalDocuments: index.totalDocuments,
    uniqueTerms: index.inverseDocumentFrequency.size,
    averageDocLength: index.averageDocumentLength
  };
}

function inferSourceType(filePath: string): 'code' | 'doc' | 'markdown' {
  const ext = filePath.split('.').pop()?.toLowerCase();
  if (!ext) return 'doc';

  if (['ts', 'tsx', 'js', 'jsx', 'sol'].includes(ext)) return 'code';
  if (['md', 'markdown'].includes(ext)) return 'markdown';
  return 'doc';
}

function inferLanguage(filePath: string): string | undefined {
  const ext = filePath.split('.').pop()?.toLowerCase();
  if (!ext) return undefined;

  const langMap: Record<string, string> = {
    'ts': 'typescript',
    'tsx': 'typescript',
    'sol': 'solidity',
    'js': 'javascript',
    'md': 'markdown'
  };

  return langMap[ext as string];
}

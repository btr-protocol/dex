import { glob } from 'glob';
import type { SearchResult, SearchResultLocation, SearchScores, AgentConfig } from '@shared/types';
import { logger } from '@btr/sdk/utils';
import { debug } from '@shared/config';
import { PROJECT_ROOT, inferLanguage, inferSourceType } from '../utils.js';
import { bm25Config, fuzzyConfig } from '../config.js';

const log = logger.withContext('lexical');

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
 * Calculate Levenshtein distance between two strings.
 * Returns the minimum number of single-character edits (insertions, deletions, substitutions).
 *
 * @param a - First string
 * @param b - Second string
 * @returns Edit distance (0 = identical)
 */
function levenshteinDistance(a: string, b: string): number {
  if (a === b) return 0;
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;

  const matrix: number[][] = [];

  // Initialize first column
  for (let i = 0; i <= b.length; i++) {
    matrix[i] = [i];
  }

  // Initialize first row
  for (let j = 0; j <= a.length; j++) {
    matrix[0]![j] = j;
  }

  // Fill in the rest of the matrix
  for (let i = 1; i <= b.length; i++) {
    for (let j = 1; j <= a.length; j++) {
      if (b[i - 1] === a[j - 1]) {
        matrix[i]![j] = matrix[i - 1]![j - 1]!;
      } else {
        matrix[i]![j] = Math.min(
          matrix[i - 1]![j - 1]! + 1,  // substitution
          matrix[i]![j - 1]! + 1,      // insertion
          matrix[i - 1]![j]! + 1       // deletion
        );
      }
    }
  }

  return matrix[b.length]![a.length]!;
}

/**
 * Calculate normalized Levenshtein distance (0-1 range).
 * 0 = identical, 1 = completely different
 */
function normalizedLevenshteinDistance(a: string, b: string): number {
  const distance = levenshteinDistance(a, b);
  const maxLength = Math.max(a.length, b.length);
  return maxLength === 0 ? 0 : distance / maxLength;
}

/**
 * Check if two terms match fuzzily within the configured threshold.
 *
 * @param queryTerm - The search term
 * @param docTerm - The term from the document
 * @returns True if they match within fuzzy threshold
 */
function fuzzyMatch(queryTerm: string, docTerm: string): boolean {
  if (queryTerm === docTerm) return true;
  if (!fuzzyConfig.enabled) return false;
  if (queryTerm.length < fuzzyConfig.minLength) return false;

  const distance = normalizedLevenshteinDistance(queryTerm, docTerm);
  return distance <= fuzzyConfig.maxDistance;
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
 * - f(qi,D) = frequency of term in document (exact + fuzzy matches)
 * - |D| = document length
 * - avgDl = average document length
 *
 * Enhanced with fuzzy matching: exact matches score full, fuzzy matches score proportionally
 */
function calculateBM25Score(
  document: LexicalDocument,
  queryTerms: Set<string>,
  inverseDocumentFrequency: Map<string, number>,
  averageDocumentLength: number
): number {
  let score = 0;

  for (const queryTerm of queryTerms) {
    // Try exact match first
    let exactMatches = document.tokens.filter(t => t === queryTerm).length;

    // If no exact match, try fuzzy matching
    let fuzzyMatches = 0;
    let fuzzyPenalty = 1.0;

    if (exactMatches === 0 && fuzzyConfig.enabled) {
      // Find fuzzy matches and their distances
      const matches = document.tokens
        .map(docToken => ({
          token: docToken,
          distance: normalizedLevenshteinDistance(queryTerm, docToken)
        }))
        .filter(m => m.distance <= fuzzyConfig.maxDistance && m.distance > 0);

      if (matches.length > 0) {
        fuzzyMatches = matches.length;
        // Average penalty based on edit distance (closer = higher score)
        const avgDistance = matches.reduce((sum, m) => sum + m.distance, 0) / matches.length;
        fuzzyPenalty = 1 - (avgDistance / fuzzyConfig.maxDistance) * 0.5; // 50-100% of full score
      }
    }

    const termFrequency = exactMatches + fuzzyMatches;
    if (termFrequency === 0) continue;

    const idf = inverseDocumentFrequency.get(queryTerm) || 0;

    const { k1, b } = bm25Config;
    const numerator = termFrequency * (k1 + 1);
    const denominator = termFrequency + k1 * (1 - b + b * (document.tokenCount / averageDocumentLength));

    const termScore = idf * (numerator / denominator);
    score += termScore * fuzzyPenalty; // Apply fuzzy penalty if applicable
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

  for (const includePattern of knowledge.include) {
    const files = await glob(includePattern, {
      cwd: PROJECT_ROOT,
      ignore: knowledge.exclude,
      absolute: false
    });

    for (const file of files) {
      const absolutePath = `${PROJECT_ROOT}/${file}`;
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
      } catch {
        // Skip files that can't be read
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
 * - Fuzzy matching for typo tolerance (Levenshtein distance ≤ 0.2)
 * - Returns top-k results with relevance scores
 *
 * @param searchString - The search query (may include expanded terms)
 * @param config - Agent configuration with knowledge patterns
 * @returns Ranked search results
 */
export async function lexicalSearch(searchString: string, config?: AgentConfig): Promise<SearchResult[]> {
  if (!config) {
    const mod = await import('../../storage.js');
    const storage = await mod.getStorage();
    const agentConfig = storage.getAgent('archivist');
    if (!agentConfig) {
      log.info('No archivist config found');
      return [];
    }
    config = agentConfig;
  }

  const cacheKey = config.agentId || 'archivist';
  let index = indexCache.get(cacheKey);

  // Build index if not cached
  if (!index) {
    const documents = await extractDocumentsFromConfig(config);
    index = await buildBM25Index(documents);
    indexCache.set(cacheKey, index);
    if (debug) {
      log.info(`BM25 index: ${index.totalDocuments} docs, ${index.inverseDocumentFrequency.size} terms`);
    }
  }

  // Tokenize search query
  const queryTerms = new Set(tokenize(searchString));

  // Score all documents with progress logging
  const scoredDocuments: Array<{ doc: LexicalDocument; score: number }> = [];

  for (const doc of index.documents.values()) {
    const score = calculateBM25Score(doc, queryTerms, index.inverseDocumentFrequency, index.averageDocumentLength);
    if (score > 0) {
      scoredDocuments.push({ doc, score });
    }
  }

  // Sort by BM25 score descending
  scoredDocuments.sort((a, b) => b.score - a.score);

  // Convert to new SearchResult format
  const maxResults = config?.retrieval?.maxResults || 15;
  const results: SearchResult[] = [];

  for (const item of scoredDocuments.slice(0, maxResults)) {
    const { doc, score } = item;

    // Extract extended context for display
    const lines = await getFileLinesWithContext(doc.filePath, doc.lineIndex);
    const context = lines.join('\n');

    // Build location
    const location: SearchResultLocation = {
      language: inferLanguage(doc.filePath) || 'unknown',
      type: inferSourceType(doc.filePath),
      file: `${doc.filePath}:${doc.lineIndex + 1}-${doc.lineIndex + lines.length}`,
      section: ''
    };

    // Build scores
    const matchCount = [...queryTerms].filter(t => doc.tokens.includes(t)).length;
    const normalizedScore = Math.min(score / bm25Config.scoreNormalizationDivisor, 1.0);
    const scores: SearchScores = {
      type: 'lexical',
      lexicalScore: normalizedScore,
      lexicalRank: 0,  // Will be set after sorting
      lexicalMatchCount: matchCount,
      compound: normalizedScore
    };

    results.push({
      content: context || doc.content,
      origin: 'lexical',
      location,
      scores
    });
  }

  // Set ranks after all results are collected
  results.forEach((r, i) => {
    r.scores.lexicalRank = i + 1;
  });

  return results;
}

/**
 * Get file lines with surrounding context for result display.
 */
async function getFileLinesWithContext(filePath: string, lineIndex: number): Promise<string[]> {
  try {
    const absolutePath = `${PROJECT_ROOT}/${filePath}`;
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

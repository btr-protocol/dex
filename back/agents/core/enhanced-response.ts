import type {
  SearchResult,
  SearchSource,
  QueryEnhancement,
  EnhancedSearchResponse,
  ChatMessage
} from './types.js';
import { getChatProvider } from './models.js';
import { renderMarkdown, type RenderMarkdownOptions } from '../../../scripts/precompile-markdown.js';
import { formatSearchSource } from '../search/hybrid.js';
import { slugify, slugifyDoc } from '@btr/dex-sdk';

const log = (msg: string) => console.log(`[${new Date().toISOString().slice(11,23)}] enhanced-response: ${msg}`);

/**
 * Generate an enhanced response with full metadata for frontend display.
 *
 * This function:
 * 1. Formats search results into the SearchSource format
 * 2. Generates the LLM response
 * 3. Returns complete metadata including timing, enhancement details, and categorized sources
 */
export async function generateEnhancedResponse(options: {
  /** Original user query */
  userQuery: string;
  /** Search results with timing */
  searchResults: SearchResult[];
  /** Query enhancement metadata */
  queryEnhancement: QueryEnhancement;
  /** System prompt for the agent */
  systemPrompt: string;
  /** Persistent memories for the agent */
  memories: string;
  /** Conversation history (compacted) */
  conversationHistory: ChatMessage[];
  /** Maximum context characters */
  maxContextChars?: number;
  /** Timing metadata from search */
  searchTiming: {
    totalDurationMs: number;
    queryOptimizationMs: number;
    lexicalSearchMs: number;
    semanticSearchMs: number;
    fusionMs: number;
  };
  /** Search mode used */
  searchMode: 'hybrid' | 'lexical-only' | 'semantic-only';
  /** Session ID */
  sessionId: string;
  /** Session stats */
  sessionStats: {
    messageCount: number;
    totalTokens: number;
    compactedCount: number;
  };
}): Promise<EnhancedSearchResponse> {
  const {
    userQuery,
    searchResults,
    queryEnhancement,
    systemPrompt,
    memories,
    conversationHistory,
    maxContextChars = 12000,
    searchTiming,
    searchMode,
    sessionId,
    sessionStats
  } = options;

  log(`Generating enhanced response for query: "${userQuery.slice(0, 50)}..."`);
  log(`  Search results: ${searchResults.length}`);
  log(`  Search timing: total=${searchTiming.totalDurationMs}ms, search=${searchTiming.lexicalSearchMs + searchTiming.semanticSearchMs}ms`);

  // Step 1: Format search results for the prompt
  const formattedContext = formatSearchResults(searchResults, maxContextChars);

  // Step 2: Build conversation context
  const conversationContext = formatConversationHistory(conversationHistory);

  // Step 3: Build prompt
  const prompt = buildResponsePrompt({
    userQuery,
    formattedContext,
    conversationContext,
    systemPrompt,
    memories
  });

  const chatProvider = await getChatProvider();

  // Build messages array
  const messages: ChatMessage[] = [
    { role: 'system', content: systemPrompt },
    { role: 'user', content: prompt }
  ];

  log(`Sending LLM request...`);

  const responseStart = performance.now();
  const llmResponse = await chatProvider.chatCompletion(messages, {
    temperature: 0.4,
    maxTokens: 4096
  });
  const responseDuration = performance.now() - responseStart;

  // Handle both streaming and non-streaming responses
  const responseText = typeof llmResponse === 'string'
    ? llmResponse
    : await (async () => {
        let text = '';
        for await (const chunk of llmResponse as AsyncIterable<string>) {
          text += chunk;
        }
        return text;
      })();

  log(`LLM response received in ${responseDuration.toFixed(0)}ms`);
  log(`  Response length: ${responseText.length} chars`);

  // Step 4: Format sources for frontend
  const sources = searchResults
    .map((result, index) => formatSearchSource(result, index))
    .sort((a, b) => b.score - a.score); // Ensure sorted by relevance

  // Step 5: Prefix markdown headers (shifts down by 2 levels for UI consistency)
  const prefixedMarkdown = prefixMarkdownHeaders(responseText);

  // Step 6: Compile markdown
  const markdownOptions: RenderMarkdownOptions = { includeMermaid: false, includeCopyButton: false };
  let compiledResponse = await renderMarkdown(prefixedMarkdown, markdownOptions);

  // Step 7: Post-process compiled markdown (transform source references to clickable URLs)
  compiledResponse = postProcessMarkdown(compiledResponse);

  // Step 8: Build metrics
  const totalDurationMs = searchTiming.totalDurationMs + responseDuration;

  log(`Total pipeline duration: ${totalDurationMs.toFixed(0)}ms`);

  return {
    response: compiledResponse,
    rawResponse: responseText,
    enhancement: queryEnhancement,
    sources,
    metrics: {
      totalDurationMs: Math.round(totalDurationMs),
      queryOptimizationMs: searchTiming.queryOptimizationMs,
      lexicalSearchMs: searchTiming.lexicalSearchMs,
      responseGenerationMs: Math.round(responseDuration),
      documentsRetrieved: searchResults.length,
      searchMode
    },
    sessionId,
    stats: {
      sessionId,
      messageCount: sessionStats.messageCount,
      totalTokens: sessionStats.totalTokens,
      compactedCount: sessionStats.compactedCount
    }
  };
}

/**
 * Format search results for LLM prompt.
 */
function formatSearchResults(results: SearchResult[], maxChars: number): string {
  if (results.length === 0) return '';

  let formatted = '';
  let totalChars = 0;

  for (const result of results) {
    const refParts = result.sourceRef.split(':');
    const filePath = refParts[0] || result.sourceRef;
    const lineNum = refParts[1] ? `:${refParts[1]}` : '';

    let sourceType = 'documentation';
    if (result.sourceType === 'code') {
      const ext = filePath.split('.').pop();
      sourceType = ext === 'sol' ? 'Solidity contract' : `TypeScript source (${ext})`;
    }

    const refHeader = `### [${sourceType}] ${filePath}${lineNum}`;
    const lineRange = result.metadata.lineRange
      ? ` (lines ${result.metadata.lineRange[0]}-${result.metadata.lineRange[1]})`
      : '';

    let scopeInfo = '';
    if (result.metadata.contract) {
      scopeInfo += `\n// Contract: ${result.metadata.contract}`;
    }
    if (result.metadata.function) {
      scopeInfo += `\n// Function: ${result.metadata.function}`;
    }
    if (result.metadata.section) {
      scopeInfo += `\n// Section: ${result.metadata.section}`;
    }

    const chunk = `${refHeader}${lineRange}${scopeInfo}\n\`\`\`${result.metadata.language || 'text'}\n${result.content}\n\`\`\`\n\n`;

    if (totalChars + chunk.length > maxChars) {
      const remaining = maxChars - totalChars;
      if (remaining > 100) {
        formatted += chunk.slice(0, remaining - 20) + '\n...\n\n';
      }
      break;
    }

    formatted += chunk;
    totalChars += chunk.length;
  }

  return formatted;
}

/**
 * Format conversation history.
 */
function formatConversationHistory(history: ChatMessage[]): string {
  if (history.length === 0) return '';

  const recentHistory = history.slice(-12);

  return recentHistory.map(msg => {
    const role = msg.role === 'user' ? 'User' : 'Assistant';
    return `${role}: ${msg.content}`;
  }).join('\n\n');
}

/**
 * Build the response prompt.
 * Note: Detailed markdown and math formatting instructions are in the agent's system prompt (agent.md).
 * This function provides the contextual structure; formatting rules come from systemPrompt.
 */
function buildResponsePrompt(options: {
  userQuery: string;
  formattedContext: string;
  conversationContext: string;
  systemPrompt: string;
  memories: string;
}): string {
  const { userQuery, formattedContext, conversationContext, memories } = options;

  const hasContext = formattedContext.length > 0;
  const hasHistory = conversationContext.length > 0;
  const hasMemories = memories.length > 0;

  return `<retrieved_context>
${hasContext ? formattedContext : '(No relevant context found - answer from general knowledge)'}
</retrieved_context>

${hasMemories ? `<persistent_memories>\n${memories}\n</persistent_memories>\n\n` : ''}

${hasHistory ? `<conversation_history>
${conversationContext}
</conversation_history>\n\n` : ''}

<user_question>
${userQuery}
</user_question>

  ---

  Provide your answer following the markdown, math, and citation formatting rules specified in your system prompt.`;
}

/**
 * Prefix markdown headers with ## to shift them down by 2 levels.
 * This ensures headers are H3/H4/H5 in the final rendered output for UI consistency.
 * Pattern: # -> ###, ## -> ####, ### -> #####
 */
function prefixMarkdownHeaders(markdown: string): string {
  return markdown
    .replace(/^### /gm, '##### ')
    .replace(/^## /gm, '#### ')
    .replace(/^# /gm, '### ');
}

/**
 * Post-process compiled markdown to transform source references to clickable URLs.
 */
function postProcessMarkdown(html: string): string {
  let result = html;

  // Transform source references to clickable URLs
  // Pattern: [source: sdk/path/file.ts] or [source: contracts/path/file.sol] or [source: docs/path/file.md]
  result = result.replace(
    /\[source:\s*([^\]]+)\]/gi,
    (match, sourcePath) => {
      const trimmedPath = sourcePath.trim();

      // Docs: convert to /docs/slug format
      if (trimmedPath.startsWith('docs/')) {
        // Extract path after docs/, remove .md extension
        const docPath = trimmedPath.slice(5); // Remove 'docs/'
        const filename = docPath.replace(/\.md$/i, '');

        // Extract directory and file for category prefix
        const lastSlash = filename.lastIndexOf('/');
        let category = '';
        let baseFile = filename;
        if (lastSlash !== -1) {
          category = filename.slice(0, lastSlash);
          baseFile = filename.slice(lastSlash + 1);
        }

        // Use slugifyDoc from SDK
        const slug = slugifyDoc(baseFile, category);
        return `<a href="/docs/${slug}" class="text-primary hover:underline">${trimmedPath}</a>`;
      }

      // Code files: convert to GitHub links
      const githubBase = 'https://github.com/btr-supply/dex/tree/main/';
      const githubBlobBase = 'https://github.com/btr-supply/dex/blob/main/';

      // For .sol files, use blob (view file)
      if (trimmedPath.endsWith('.sol')) {
        return `<a href="${githubBlobBase}${trimmedPath}" target="_blank" rel="noopener noreferrer" class="text-primary hover:underline">${trimmedPath}</a>`;
      }

      // For TypeScript/JS files, use tree (browse)
      if (trimmedPath.endsWith('.ts') || trimmedPath.endsWith('.tsx') || trimmedPath.endsWith('.js')) {
        return `<a href="${githubBase}${trimmedPath}" target="_blank" rel="noopener noreferrer" class="text-primary hover:underline">${trimmedPath}</a>`;
      }

      // Default: return as-is with basic styling
      return `<span class="text-primary">${trimmedPath}</span>`;
    }
  );

  return result;
}


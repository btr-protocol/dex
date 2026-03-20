import type {
  SearchResult,
  QueryEnhancement,
  EnhancedSearchResponse,
  ChatMessage
} from '@shared/types';
import { getChatProviderForReasoning } from './providers.js';
import { renderMarkdown, type RenderMarkdownOptions } from '@shared/markdown';
import { formatSearchSource } from './search/hybrid.js';
import { contextConfig } from './search/config.js';
import { slugifyDoc } from '@btr/sdk';
import { logger } from '@btr/sdk/utils';
import { debug } from '@shared/config';

const log = logger.withContext('handlers');

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
    maxContextChars,
    searchTiming,
    searchMode,
    sessionId,
    sessionStats
  } = options;

  if (debug) {
    log.info(`Response generation: ${searchResults.length} results, search=${searchTiming.totalDurationMs}ms`);
  }

  // Step 1: Format search results for the prompt
  // Use contextConfig if maxContextChars not explicitly provided
  const formattedContext = formatSearchResults(searchResults, maxContextChars, contextConfig);

  // Step 2: Build conversation context
  // Filter out any messages that match the current userQuery to avoid duplication in the prompt
  const filteredHistory = conversationHistory.filter(m => m.content.trim() !== userQuery.trim());
  const conversationContext = formatConversationHistory(filteredHistory);

  if (debug) {
    log.info(`Prompt breakdown: system=${systemPrompt.length} chars, context=${formattedContext.length} chars, memories=${memories.length} chars, history=${conversationContext.length} chars (from ${conversationHistory.length} messages, filtered to ${filteredHistory.length})`);
  }

  // Step 3: Build prompt
  const prompt = buildResponsePrompt({
    userQuery,
    formattedContext,
    conversationContext,
    systemPrompt,
    memories
  });

  const chatProvider = await getChatProviderForReasoning();

  // Build messages array
  const messages: ChatMessage[] = [
    { role: 'system', content: systemPrompt },
    { role: 'user', content: prompt }
  ];

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

  if (debug) {
    log.info(`LLM: ${responseDuration.toFixed(0)}ms, ${responseText.length} chars`);
  }

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

  return {
    response: compiledResponse,
    rawResponse: responseText,
    enhancement: queryEnhancement,
    sources,
    metrics: {
      totalDurationMs: Math.round(totalDurationMs),
      queryOptimizationMs: searchTiming.queryOptimizationMs,
      lexicalSearchMs: searchTiming.lexicalSearchMs,
      semanticSearchMs: searchTiming.semanticSearchMs,
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
 * Format search results for LLM prompt with configurable context limiting.
 *
 * Strategy:
 * 1. Prioritize hybrid results (both lexical + semantic) for minimal payload
 * 2. Take only top N results by score (already sorted)
 * 3. Truncate each result's content to maxCharsPerResult
 * 4. Stop when maxTotalChars is reached
 *
 * This keeps context small for fast LLM responses while preserving relevance.
 * Exported for use by WebSocket streaming.
 */
export function formatSearchResults(results: SearchResult[], maxChars?: number, limits?: typeof contextConfig): string {
  if (results.length === 0) return '';

  const effectiveLimits = limits || contextConfig;
  const effectiveMaxChars = Math.min(maxChars || effectiveLimits.maxTotalChars, effectiveLimits.maxTotalChars);

  // Prioritize: hybrid > semantic > lexical (for minimizing payload while maximizing relevance)
  const prioritizedResults = [...results].sort((a, b) => {
    // First, by origin priority (hybrid first)
    const originPriority = { hybrid: 3, semantic: 2, lexical: 1 };
    const priorityDiff = originPriority[b.origin!] - originPriority[a.origin!];
    if (priorityDiff !== 0) return priorityDiff;
    // Then by score
    return b.scores.compound - a.scores.compound;
  });

  const topResults = prioritizedResults.slice(0, effectiveLimits.maxResults);

  if (debug) {
    const hybridCount = topResults.filter(r => r.origin === 'hybrid').length;
    log.info(`formatSearchResults: ${results.length} input → ${topResults.length} results (${hybridCount} hybrid), maxChars=${effectiveMaxChars}`);
  }

  let formatted = '';
  let totalChars = 0;

  for (const result of topResults) {
    const { file } = result.location;
    const { language, type } = result.location;

    let sourceType = 'documentation';
    if (type === 'code') {
      const ext = file.split('.').pop();
      sourceType = ext === 'sol' ? 'Solidity contract' : `TypeScript source (${ext})`;
    }

    const originIcon = result.origin === 'hybrid' ? '🔗' : result.origin === 'semantic' ? '🧠' : '📝';
    const refHeader = `### [${sourceType}] ${file} ${originIcon}`;

    // Truncate content to maxCharsPerResult
    let content = result.content;
    if (content.length > effectiveLimits.maxCharsPerResult) {
      content = content.slice(0, effectiveLimits.maxCharsPerResult) + '...';
    }

    const chunk = `${refHeader}\n\`\`\`${language || 'text'}\n${content}\n\`\`\`\n\n`;

    if (totalChars + chunk.length > effectiveMaxChars) {
      // Add partial chunk if there's room
      const remaining = effectiveMaxChars - totalChars;
      if (remaining > 100) {
        formatted += chunk.slice(0, remaining - 20) + '\n...\n\n';
      }
      break;
    }

    formatted += chunk;
    totalChars += chunk.length;
  }

  if (debug) {
    log.info(`formatSearchResults output: ${totalChars} chars (${formatted.length} actual)`);
  }

  return formatted;
}

/**
 * Format conversation history.
 * Exported for use by WebSocket streaming.
 */
export function formatConversationHistory(history: ChatMessage[]): string {
  if (history.length === 0) return '';

  // Only include recent messages to reduce context size
  // Take last 2 exchanges (4 messages: user, assistant, user, assistant)
  const recentHistory = history.slice(-4);

  return recentHistory.map(msg => {
    const role = msg.role === 'user' ? 'User' : 'Assistant';
    return `${role}: ${msg.content}`;
  }).join('\n\n');
}

/**
 * Build the response prompt.
 * NB: Detailed markdown and math formatting instructions are in the agent's system prompt (agent.md).
 * This function provides the contextual structure; formatting rules come from systemPrompt.
 * Exported for use by WebSocket streaming.
 */
export function buildResponsePrompt(options: {
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


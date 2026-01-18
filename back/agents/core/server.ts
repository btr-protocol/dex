import { serve } from 'bun';
import type { ServerWebSocket } from 'bun';
import type { ChatMessage, AgentConfig, Storage, SessionContext, WSClient } from './types.js';
import { port, corsEnabled, rateLimitPerSession, debug } from './config.js';
import { hybridSearch, formatSearchSource } from '../search/hybrid.js';
import { indexKnowledge } from '../search/indexing.js';
import { loadArchivistConfig } from './configLoader.js';
import { log } from '../../shared/logger.js';

interface RateLimit {
  count: number;
  resetAt: number;
}

const rateLimitMap = new Map<string, RateLimit>();

function checkRateLimit(sessionId: string): boolean {
  const now = Date.now();
  const limit = rateLimitMap.get(sessionId);

  if (!limit || now > limit.resetAt) {
    rateLimitMap.set(sessionId, { count: 1, resetAt: now + 60000 });
    return true;
  }

  if (limit.count >= rateLimitPerSession) {
    log(`Rate limit exceeded for session ${sessionId}`);
    return false;
  }

  limit.count++;
  return true;
}

function corsHeaders(): Record<string, string> {
  if (!corsEnabled) return {};
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, X-Session-ID',
  };
}

function jsonHeaders(): Record<string, string> {
  return {
    ...corsHeaders(),
    'Content-Type': 'application/json',
  };
}

function getSessionId(req: Request): string {
  return req.headers.get('X-Session-ID') || req.headers.get('x-session-id') || 'default';
}

let storage: Storage | null = null;
let storageInit: Promise<void> | null = null;

async function getStorageInstance(): Promise<Storage> {
  if (!storage) {
    const mod = await import('./storage.js');
    storage = await mod.getStorage();
    storageInit = Promise.resolve();
  }
  if (storageInit) {
    await storageInit;
  }
  return storage;
}

const server = serve({
  port,
  async fetch(req) {
    const url = new URL(req.url);
    const sessionId = getSessionId(req);

    if (req.method === 'OPTIONS') {
      return new Response(null, { headers: corsHeaders() });
    }

    if (url.pathname === '/health') {
      return new Response(JSON.stringify({ status: 'ok', timestamp: Date.now() }), {
        headers: jsonHeaders()
      });
    }

    if (url.pathname === '/agents' && req.method === 'GET') {
      const st = await getStorageInstance();
      const agents = st.listAgents();
      return new Response(JSON.stringify({ agents }), {
        headers: jsonHeaders()
      });
    }

    if (url.pathname === '/' || url.pathname === '/info') {
      const st = await getStorageInstance();
      const agents = st.listAgents();
      return new Response(
        JSON.stringify({
          server: 'BTR Agents Server',
          version: '1.0.0',
          agents: agents.map((a) => ({
            id: a.agentId,
            name: a.name,
            model: a.model,
          })),
          endpoints: {
            rest: {
              'GET /agents': 'List available agents',
              'POST /agents/{id}/chat': 'Chat with agent',
            },
            websocket: {
              'WS /agents/{id}/ws': 'Real-time streaming chat',
            },
            note: 'Knowledge indexing is automatic on server startup (incremental)',
          },
        }),
        { headers: jsonHeaders() }
      );
    }

    if (url.pathname.startsWith('/agents/') && url.pathname.endsWith('/chat') && req.method === 'POST') {
      const agentId = url.pathname.split('/')[2];

      if (!checkRateLimit(sessionId)) {
        return new Response(JSON.stringify({ error: 'Rate limit exceeded' }), {
          status: 429,
          headers: jsonHeaders()
        });
      }

      try {
        const body = await req.json() as { message: string; userId?: string };
        const { message, userId } = body;

        if (!message) {
          return new Response(JSON.stringify({ error: 'Message is required' }), {
            status: 400,
            headers: jsonHeaders()
          });
        }

        const st = await getStorageInstance();
        const agentConfig = st.getAgent(agentId);

        if (!agentConfig) {
          return new Response(JSON.stringify({ error: 'Agent not found', agentId }), {
            status: 404,
            headers: jsonHeaders()
          });
        }

        const sessionContext = st.getSession(sessionId);

        if (!sessionContext) {
          await st.createSession(sessionId, agentId, userId);
        }

        await st.updateSessionActivity(sessionId);

        // Load system prompt and memories
        const systemPrompt = await loadSystemPrompt(agentId);
        const memories = await loadMemories(agentId);

        if (debug) log(`Processing chat for ${agentId} (session: ${sessionId})`);

        // Step 1: Hybrid search with timing (LLM query optimization + BM25 + RAG)
        const searchWithTiming = await hybridSearch(message, agentConfig);

        // Step 2: Build query enhancement metadata
        const queryEnhancement = {
          originalQuery: message,
          rephrasedQuery: searchWithTiming.optimizedQuery.rephrasedQuery,
          synonyms: searchWithTiming.optimizedQuery.synonyms,
          relatedTerms: searchWithTiming.optimizedQuery.relatedTerms,
          durationMs: searchWithTiming.timing.queryOptimizationMs
        };

        // Step 3: Generate enhanced response
        const stats = st.getSessionStats(sessionId);
        const enhancedResponse = await generateEnhancedResponse({
          userQuery: message,
          searchResults: searchWithTiming.results,
          queryEnhancement,
          systemPrompt,
          memories,
          conversationHistory: sessionContext?.messages || [],
          maxContextChars: agentConfig?.retrieval?.maxContextTokens || 12000,
          searchTiming: searchWithTiming.timing,
          searchMode: searchWithTiming.searchMode,
          sessionId,
          sessionStats: {
            messageCount: stats.messageCount,
            totalTokens: stats.totalTokens,
            compactedCount: stats.compactedCount
          }
        });

        // Store retrieval context for debugging
        for (const result of searchWithTiming.results) {
          await st.addRetrievalContext(sessionId, 'rag', result.sourceRef, result.content, result.score);
        }

        // Store messages in session
        await st.addMessage(sessionId, 'user', message, Math.ceil(message.length / 4));
        await st.addMessage(sessionId, 'assistant', enhancedResponse.rawResponse, Math.ceil(enhancedResponse.rawResponse.length / 4));

        return new Response(JSON.stringify(enhancedResponse), {
          headers: jsonHeaders()
        });

      } catch (error) {
        log(`Chat error: ${error}`);
        return new Response(JSON.stringify({
          error: 'Internal server error',
          message: error instanceof Error ? error.message : String(error)
        }), {
          status: 500,
          headers: jsonHeaders()
        });
      }
    }

    if (url.pathname.includes('/sessions') && req.method === 'GET') {
      const st = await getStorageInstance();
      const parts = url.pathname.split('/');
      const agentId = parts[2];
      const sessionId = parts[4];
      const sessionContext = st.getSession(sessionId);

      if (!sessionContext || sessionContext.agentId !== agentId) {
        return new Response(JSON.stringify({ error: 'Session not found' }), {
          status: 404,
          headers: jsonHeaders()
        });
      }

      return new Response(JSON.stringify({
        sessionId: sessionContext.sessionId,
        agentId: sessionContext.agentId,
        messages: sessionContext.messages,
        totalTokens: sessionContext.totalTokens
      }), {
        headers: jsonHeaders()
      });
    }

    return new Response(JSON.stringify({ error: 'Not found', path: url.pathname }), {
      status: 404,
      headers: jsonHeaders()
    });
  },

  websocket: {
    async message(ws, message) {
      const data = ws.data as WSClient | undefined;

      if (!data) return;

      const { sessionId, agentId } = data;

      if (typeof message === 'string') {
        try {
          const msgData = JSON.parse(message);

          if (msgData.type === 'chat') {
            const st = await getStorageInstance();
            const sessionContext = st.getSession(sessionId);

            if (!sessionContext) {
              ws.send(JSON.stringify({ error: 'Session not found' }));
              return;
            }

            const systemPrompt = await loadSystemPrompt(agentId);
            const memories = await loadMemories(agentId);

            ws.send(JSON.stringify({ type: 'start', sessionId }));

            // Hybrid search with timing
            const agentConfig = st.getAgent(agentId);
            const searchWithTiming = agentConfig
              ? await hybridSearch(msgData.message, agentConfig)
              : { results: [], optimizedQuery: { rephrasedQuery: msgData.message, synonyms: [], relatedTerms: [], optimizationReasoning: '' }, timing: { totalDurationMs: 0, queryOptimizationMs: 0, lexicalSearchMs: 0, semanticSearchMs: 0, fusionMs: 0 }, searchMode: 'lexical-only' };

            // Send search metadata
            ws.send(JSON.stringify({
              type: 'search',
              resultsCount: searchWithTiming.results.length,
              timing: searchWithTiming.timing,
              searchMode: searchWithTiming.searchMode,
              queryEnhancement: {
                originalQuery: msgData.message,
                rephrasedQuery: searchWithTiming.optimizedQuery.rephrasedQuery,
                synonyms: searchWithTiming.optimizedQuery.synonyms,
                relatedTerms: searchWithTiming.optimizedQuery.relatedTerms,
                durationMs: searchWithTiming.timing.queryOptimizationMs
              }
            }));

            // Send sources
            const sources = searchWithTiming.results.map((r, i) => formatSearchSource(r, i));
            ws.send(JSON.stringify({
              type: 'sources',
              sources: sources.sort((a, b) => b.score - a.score)
            }));

            // Generate streaming response
            const chatProvider = await (async () => {
              const mod = await import('./models.js');
              return mod.getChatProvider();
            })();

            const formattedContext = formatSearchResultsForStream(searchWithTiming.results);
            const conversationContext = formatConversationHistory(sessionContext.messages || []);
            const prompt = buildStreamPrompt({
              userQuery: msgData.message,
              formattedContext,
              conversationContext,
              systemPrompt,
              memories
            });

            const messages = [
              { role: 'system', content: systemPrompt },
              { role: 'user', content: prompt }
            ];

            const responseStream = await chatProvider.chatCompletion(messages, { stream: true });

            if (typeof responseStream === 'string') {
              ws.send(JSON.stringify({ type: 'chunk', content: responseStream, done: false }));
            } else {
              for await (const chunk of responseStream as AsyncIterable<string>) {
                ws.send(JSON.stringify({ type: 'chunk', content: chunk, done: false }));
              }
            }
            ws.send(JSON.stringify({ type: 'chunk', content: '', done: true }));

            await st.updateSessionActivity(sessionId);
          }
        } catch (error) {
          ws.send(JSON.stringify({ type: 'error', message: error instanceof Error ? error.message : String(error) }));
        }
      }
    },

    open(ws) {
      const data = ws.data as WSClient | undefined;

      if (!data) return;

      const { sessionId, agentId } = data;
      log(`WebSocket opened: ${sessionId} -> ${agentId}`);
      ws.send(JSON.stringify({ type: 'connected', sessionId }));
    },

    close(ws, code, message) {
      const data = ws.data as WSClient | undefined;

      if (!data) return;

      const { sessionId } = data;
      log(`WebSocket closed: ${sessionId} (${code}) ${message}`);
    }
  }
});

async function initializeAgents(): Promise<void> {
  const st = await getStorageInstance();
  const archivistConfig = await loadArchivistConfig();

  if (archivistConfig) {
    try {
      await st.registerAgent(archivistConfig);
      log('✅ Archivist agent registered');

      // Auto-index on startup only if RAG is enabled
      const ragEnabled = archivistConfig.retrieval?.enableRAG !== false;
      if (ragEnabled) {
        log('🔄 Starting automatic incremental indexing (RAG enabled)...');
        indexKnowledge('archivist').catch(error => {
          log(`⚠️  Background indexing error: ${error}`);
        });
      } else {
        log('⏭️  Indexing skipped (RAG disabled via config.enableRAG=false)');
        log('📊 Lexical search (BM25) will be used exclusively');
      }
    } catch (error) {
      log(`❌ Failed to register archivist: ${error}`);
    }
  } else {
    log('⚠️  Archivist config not found');
  }
}

initializeAgents().then(() => {
  log(`📚 Agents server started on http://localhost:${port}`);
});

async function loadSystemPrompt(agentId: string): Promise<string> {
  try {
    // Resolve path from server directory (core/) up to agents/ then to agent directory
    const serverDir = new URL('.', import.meta.url).pathname;
    const path = `${serverDir}/../${agentId}/agent.md`;

    if (debug) {
      log(`Loading system prompt from: ${path}`);
      log(`Server dir: ${serverDir}`);
    }

    const content = await Bun.file(path).text();
    const match = content.match(/---[\s\S]*?---\n([\s\S]*)/);
    const prompt = match ? match[1]!.trim() : content;

    if (debug) log(`System prompt loaded, length: ${prompt.length}, starts with: "${prompt.slice(0, 100)}..."`);

    return prompt;
  } catch (error) {
    log(`Failed to load system prompt for ${agentId}: ${error}`);
    return 'You are a helpful AI assistant.';
  }
}

async function loadMemories(agentId: string): Promise<string> {
  try {
    const serverDir = new URL('.', import.meta.url).pathname;
    const path = `${serverDir}/../${agentId}/memories.md`;
    const content = await Bun.file(path).text();
    return content;
  } catch (error) {
    log(`Failed to load memories for ${agentId}: ${error}`);
    return '';
  }
}

/**
 * Format search results for WebSocket streaming.
 */
function formatSearchResultsForStream(results: SearchResult[], maxChars = 12000): string {
  if (results.length === 0) return '(No relevant context found)';

  let formatted = '';
  let totalChars = 0;

  for (const result of results) {
    const refParts = result.sourceRef.split(':');
    const filePath = refParts[0] || result.sourceRef;
    const lineNum = refParts[1] ? `:${refParts[1]}` : '';

    let sourceType = 'documentation';
    if (result.sourceType === 'code') {
      const ext = filePath.split('.').pop();
      sourceType = ext === 'sol' ? 'Solidity contract' : `TypeScript (${ext})`;
    }

    const chunk = `### [${sourceType}] ${filePath}${lineNum}\n\`\`\`${result.metadata.language || 'text'}\n${result.content}\n\`\`\`\n\n`;

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
 * Format conversation history for WebSocket streaming.
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
 * Build prompt for WebSocket streaming.
 * Note: Detailed markdown formatting instructions are in the agent's system prompt (agent.md).
 * This function provides the contextual structure; formatting rules come from systemPrompt.
 */
function buildStreamPrompt(options: {
  userQuery: string;
  formattedContext: string;
  conversationContext: string;
  systemPrompt: string;
  memories: string;
}): string {
  const { userQuery, formattedContext, conversationContext, memories } = options;

  const hasContext = formattedContext.length > 0 && formattedContext !== '(No relevant context found)';
  const hasHistory = conversationContext.length > 0;
  const hasMemories = memories.length > 0;

  return `<retrieved_context>
${hasContext ? formattedContext : '(No relevant context found - answer from general knowledge)'}
</retrieved_context>

${hasMemories ? `<persistent_memories>\n${memories}\n</persistent_memories>\n\n` : ''}

${hasHistory ? `<conversation_history>\n${conversationContext}\n</conversation_history>\n\n` : ''}

<user_question>
${userQuery}
</user_question>

---

Provide your answer following the markdown and math formatting rules specified in your system prompt. Reference sources inline using the format: [source: file.sol:123].`;
}

process.on('SIGINT', () => {
  log('Shutting down...');
  storage?.close();
  process.exit(0);
});

process.on('SIGTERM', () => {
  log('Shutting down...');
  storage?.close();
  process.exit(0);
});

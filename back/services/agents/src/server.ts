import { serve } from 'bun';
import type { ChatMessage, Storage, WSClient } from '@shared/types';
import { port, corsEnabled, rateLimitPerSession, debug } from '@shared/config';
import { hybridSearch, formatSearchSource } from './search/hybrid.js';
import { indexKnowledge } from './search/indexer.js';
import { clearLexicalIndex } from './search/lexical/search.js';
import { invalidateVectorDBCache } from './search/semantic/search.js';
import { ensureTEIRunning, stopTEI } from './search/tei-manager.js';
import { config as archivistConfig } from './archivist/config.js';
import { initializeProviders, getChatProviderForReasoning } from './providers.js';
import { generateEnhancedResponse, formatSearchResults, formatConversationHistory, buildResponsePrompt } from './handlers.js';
import { optimizeQuery } from './search/optimizer.js';
import { renderMarkdown, type RenderMarkdownOptions } from '@shared/markdown';
import { logger as sdkLogger } from '@btr/sdk/utils';
import { getUserStorage, type User } from '@shared/user-storage';
import { verifyEthereumSignature } from '@shared/crypto';
import { generateToken, verifyToken, extractBearerToken } from '@shared/auth';

const log = sdkLogger.withContext('server');

// Cached agent resources (loaded once at startup)
const agentCache = new Map<string, { systemPrompt: string; memories: string }>();

// Flag to track if server is ready to accept requests
let serverReady = false;

/**
 * Check if an endpoint is read-only (allowed before indexing completes)
 */
function isReadOnlyEndpoint(pathname: string, method: string): boolean {
  const readOnlyPaths = ['/health', '/agents', '/info', '/'];
  const isReadOnlyPath = readOnlyPaths.some(p => pathname === p || pathname.startsWith(p));
  const isAuthPath = pathname.startsWith('/api/auth');
  return (isReadOnlyPath && method === 'GET') || isAuthPath;
}

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
    log.info(`Rate limit exceeded for session ${sessionId}`);
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

    // Always allow OPTIONS, health, and agents list
    if (req.method === 'OPTIONS') {
      return new Response(null, { headers: corsHeaders() });
    }

    if (url.pathname === '/health') {
      return new Response(JSON.stringify({
        status: 'ok',
        ready: serverReady,
        timestamp: Date.now()
      }), {
        headers: jsonHeaders()
      });
    }

    // Block non-readiness requests until indexing completes
    if (!serverReady && !isReadOnlyEndpoint(url.pathname, req.method)) {
      return new Response(JSON.stringify({
        error: 'Server not ready',
        message: 'Knowledge indexing in progress, please wait...'
      }), {
        status: 503,
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

        // Step 1: Classify and optimize the query (fast LLM call)
        const optimizationStart = performance.now();
        const optimizedQuery = await optimizeQuery(message);
        const optimizationDuration = performance.now() - optimizationStart;

        // Step 2: Short-circuit for non-technical queries (direct/inappropriate)
        if (optimizedQuery.queryType !== 'technical' && optimizedQuery.directResponse) {
          const directResponse = optimizedQuery.directResponse;
          const shouldStore = optimizedQuery.queryType === 'direct'; // Don't store inappropriate queries

          // Compile markdown for direct response
          const markdownOptions: RenderMarkdownOptions = { includeMermaid: false, includeCopyButton: false };
          const compiledResponse = await renderMarkdown(directResponse, markdownOptions);

          // Store messages in session (only for direct responses, not inappropriate)
          if (shouldStore) {
            await st.addMessage(sessionId, 'user', message, Math.ceil(message.length / 4));
            await st.addMessage(sessionId, 'assistant', directResponse, Math.ceil(directResponse.length / 4));
          }

          const stats = (shouldStore ? st.getSessionStats(sessionId) : null) ?? { messageCount: 0, totalTokens: 0, compactedCount: 0 };

          return new Response(JSON.stringify({
            response: compiledResponse,
            rawResponse: directResponse,
            enhancement: {
              originalQuery: message,
              rephrasedQuery: message,
              synonyms: [],
              relatedTerms: [],
              durationMs: Math.round(optimizationDuration)
            },
            sources: [],
            metrics: {
              totalDurationMs: Math.round(optimizationDuration),
              queryOptimizationMs: Math.round(optimizationDuration),
              lexicalSearchMs: 0,
              semanticSearchMs: 0,
              responseGenerationMs: 0,
              documentsRetrieved: 0,
              searchMode: optimizedQuery.queryType
            },
            sessionId,
            stats: {
              sessionId,
              messageCount: stats.messageCount + (shouldStore ? 1 : 0),
              totalTokens: stats.totalTokens + (shouldStore ? Math.ceil(directResponse.length / 4) : 0),
              compactedCount: stats.compactedCount
            }
          }), {
            headers: jsonHeaders()
          });
        }

        // Step 3: For technical queries, continue with hybrid search
        // Get cached system prompt and memories
        const { systemPrompt, memories } = getAgentResources(agentId);

        if (debug) log.info(`Processing chat for ${agentId} (session: ${sessionId})`);

        // Hybrid search with timing (BM25 + RAG) - using pre-optimized query
        const searchWithTiming = await hybridSearch(message, agentConfig, optimizedQuery);

        // Build query enhancement metadata
        const queryEnhancement = {
          originalQuery: message,
          rephrasedQuery: optimizedQuery.rephrasedQuery,
          synonyms: optimizedQuery.synonyms,
          relatedTerms: optimizedQuery.relatedTerms,
          durationMs: optimizationDuration + searchWithTiming.timing.queryOptimizationMs
        };

        // Generate enhanced response
        const stats = st.getSessionStats(sessionId) ?? { messageCount: 0, totalTokens: 0, compactedCount: 0 };
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
          await st.addRetrievalContext(sessionId, 'rag', result.location.file, result.content, result.scores.compound);
        }

        // Store messages in session
        await st.addMessage(sessionId, 'user', message, Math.ceil(message.length / 4));
        await st.addMessage(sessionId, 'assistant', enhancedResponse.rawResponse, Math.ceil(enhancedResponse.rawResponse.length / 4));

        return new Response(JSON.stringify(enhancedResponse), {
          headers: jsonHeaders()
        });

      } catch (error) {
        log.info(`Chat error: ${error}`);
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

    // ─────────────────────────────────────────────────────
    // Auth Endpoints
    // ─────────────────────────────────────────────────────

    if (url.pathname === '/api/auth/invite' && req.method === 'POST') {
      try {
        const body = await req.json() as { inviteCode: string; signature: string; message: string; address: string };

        // Validate request
        if (!body.inviteCode || !body.signature || !body.message || !body.address) {
          return new Response(JSON.stringify({ error: 'Missing required fields' }), {
            status: 400,
            headers: jsonHeaders()
          });
        }

        // Get user storage
        const userStorage = await getUserStorage();
        const inviter = userStorage.getUserByInviteCode(body.inviteCode);

        // Validate invite code
        if (!inviter) {
          return new Response(JSON.stringify({ error: 'Invalid invite code' }), {
            status: 404,
            headers: jsonHeaders()
          });
        }

        if (inviter.invite_remaining_uses <= 0) {
          return new Response(JSON.stringify({ error: 'Invite code has no remaining uses' }), {
            status: 403,
            headers: jsonHeaders()
          });
        }

        // Verify signature
        const isValid = verifyEthereumSignature(body.signature as `0x${string}`, body.message, body.address as `0x${string}`);
        if (!isValid) {
          return new Response(JSON.stringify({ error: 'Invalid signature' }), {
            status: 401,
            headers: jsonHeaders()
          });
        }

        // Upsert user
        await userStorage.upsertUser(body.address, undefined, body.inviteCode);

        // Generate token
        const token = await generateToken({
          address: body.address,
          role: 'user'
        });

        log.info(`User ${body.address} authenticated with invite code ${body.inviteCode}`);

        return new Response(JSON.stringify({
          token,
          user: {
            wallet_address: body.address,
            role: 'user',
            invited: 1
          }
        }), {
          headers: jsonHeaders()
        });
      } catch (error) {
        log.info(`Auth error: ${error}`);
        return new Response(JSON.stringify({
          error: 'Authentication failed',
          message: error instanceof Error ? error.message : String(error)
        }), {
          status: 500,
          headers: jsonHeaders()
        });
      }
    }

    if (url.pathname === '/api/auth/disconnect' && req.method === 'POST') {
      try {
        const token = extractBearerToken(req);

        if (!token) {
          return new Response(JSON.stringify({ error: 'No token provided' }), {
            status: 401,
            headers: jsonHeaders()
          });
        }

        const payload = verifyToken(token);
        if (!payload) {
          return new Response(JSON.stringify({ error: 'Invalid token' }), {
            status: 401,
            headers: jsonHeaders()
          });
        }

        log.info(`User ${payload.address} disconnected`);
        return new Response(JSON.stringify({ success: true }), {
          headers: jsonHeaders()
        });
      } catch (error) {
        log.info(`Disconnect error: ${error}`);
        return new Response(JSON.stringify({ error: 'Disconnect failed' }), {
          status: 500,
          headers: jsonHeaders()
        });
      }
    }

    if (url.pathname === '/api/auth/disclaimer-sign' && req.method === 'POST') {
      try {
        const body = await req.json() as { signature: string; message: string; address: string };

        if (!body.signature || !body.message || !body.address) {
          return new Response(JSON.stringify({ error: 'Missing required fields' }), {
            status: 400,
            headers: jsonHeaders()
          });
        }

        // Get user storage to check if user exists
        const userStorage = await getUserStorage();
        const existingUser = userStorage.getUserByAddress(body.address);

        if (!existingUser) {
          return new Response(JSON.stringify({ error: 'User not found. Please enter invite code first.' }), {
            status: 404,
            headers: jsonHeaders()
          });
        }

        // Verify signature
        const isValid = verifyEthereumSignature(body.signature as `0x${string}`, body.message, body.address as `0x${string}`);
        if (!isValid) {
          return new Response(JSON.stringify({ error: 'Invalid signature' }), {
            status: 401,
            headers: jsonHeaders()
          });
        }

        // Mark disclaimer as signed (configurable expiry)
        await userStorage.markDisclaimerSigned(body.address);

        // Generate token
        const token = await generateToken({
          address: body.address,
          role: existingUser.role
        });

        log.info(`User ${body.address} signed disclaimer`);
        return new Response(JSON.stringify({
          token,
          user: {
            wallet_address: body.address,
            role: existingUser.role,
            disclaimer_signed: true
          }
        }), {
          headers: jsonHeaders()
        });
      } catch (error) {
        log.error(`Disclaimer sign error: ${error}`);
        return new Response(JSON.stringify({
          error: 'Failed to sign disclaimer',
          message: error instanceof Error ? error.message : String(error)
        }), {
          status: 500,
          headers: jsonHeaders()
        });
      }
    }

    if (url.pathname === '/api/user/me' && req.method === 'GET') {
      try {
        const token = extractBearerToken(req);

        if (!token) {
          return new Response(JSON.stringify({ error: 'Unauthorized' }), {
            status: 401,
            headers: jsonHeaders()
          });
        }

        const payload = verifyToken(token);
        if (!payload) {
          return new Response(JSON.stringify({ error: 'Invalid token' }), {
            status: 401,
            headers: jsonHeaders()
          });
        }

        // Get user info
        const userStorage = await getUserStorage();
        const user = userStorage.getUserByAddress(payload.address);

        if (!user) {
          return new Response(JSON.stringify({ error: 'User not found' }), {
            status: 404,
            headers: jsonHeaders()
          });
        }

        const response = {
          wallet_address: user.wallet_address,
          role: user.role,
          invited: user.invited === 1,
          disclaimer_signed: user.disclaimer_signed === 1,
          disclaimer_signed_at: user.disclaimer_signed_at,
          disclaimer_expiry: user.disclaimer_expiry,
          can_use_agents: user.can_use_agents === 1,
          coop_arb_status: user.coop_arb_status === 1,
          banned: user.banned === 1,
          invite_code: user.invite_code,
          invite_remaining_uses: user.invite_remaining_uses,
          parent_invite_code: user.parent_invite_code,
          created_at: user.created_at,
          updated_at: user.updated_at,
        };

        return new Response(JSON.stringify(response), {
          headers: jsonHeaders()
        });
      } catch (error) {
        log.info(`Get user error: ${error}`);
        return new Response(JSON.stringify({ error: 'Failed to get user' }), {
          status: 500,
          headers: jsonHeaders()
        });
      }
    }

    if (url.pathname === '/api/auth/check-invite' && req.method === 'POST') {
      try {
        const body = await req.json() as { inviteCode: string };

        if (!body.inviteCode) {
          return new Response(JSON.stringify({ error: 'Invite code required' }), {
            status: 400,
            headers: jsonHeaders()
          });
        }

        const userStorage = await getUserStorage();
        const user = userStorage.getUserByInviteCode(body.inviteCode);

        if (!user) {
          return new Response(JSON.stringify({ valid: false, message: 'Invite code not found' }), {
            status: 404,
            headers: jsonHeaders()
          });
        }

        if (user.invite_remaining_uses <= 0) {
          return new Response(JSON.stringify({ valid: false, message: 'Invite code has no remaining uses' }), {
            status: 403,
            headers: jsonHeaders()
          });
        }

        return new Response(JSON.stringify({ valid: true }), {
          headers: jsonHeaders()
        });
      } catch (error) {
        log.info(`Check invite error: ${error}`);
        return new Response(JSON.stringify({ error: 'Failed to check invite' }), {
          status: 500,
          headers: jsonHeaders()
        });
      }
    }

    // ─────────────────────────────────────────────────────
    // Admin Endpoints
    // ─────────────────────────────────────────────────────

    const adminPath = url.pathname.match(/^\/api\/admin\/user\/(0x[a-fA-F0-9]{40})\/(.+)$/);

    if (adminPath && req.method === 'POST') {
      try {
        const address = adminPath[1];
        const action = adminPath[2];

        const token = extractBearerToken(req);
        if (!token) {
          return new Response(JSON.stringify({ error: 'Unauthorized' }), {
            status: 401,
            headers: jsonHeaders()
          });
        }

        const payload = verifyToken(token);
        if (!payload || payload.role !== 'admin') {
          return new Response(JSON.stringify({ error: 'Forbidden: admin only' }), {
            status: 403,
            headers: jsonHeaders()
          });
        }

        const userStorage = await getUserStorage();

        switch (action) {
          case 'ban':
          case 'unban': {
            userStorage.updateUserBanStatus(address, action === 'ban');
            return new Response(JSON.stringify({ success: true, banned: action === 'ban' }), {
              headers: jsonHeaders()
            });
          }

          case 'revoke': {
            userStorage.updateUserInvitedStatus(address, false);
            return new Response(JSON.stringify({ success: true, revoked: true }), {
              headers: jsonHeaders()
            });
          }

          case 'grant': {
            const body = await req.json() as { inviteCode?: string };
            if (!body.inviteCode) {
              return new Response(JSON.stringify({ error: 'Invite code required' }), {
                status: 400,
                headers: jsonHeaders()
              });
            }

            const inviter = userStorage.getUserByInviteCode(body.inviteCode);
            if (!inviter || inviter.invite_remaining_uses <= 0) {
              return new Response(JSON.stringify({ error: 'Invalid or exhausted invite code' }), {
                status: 400,
                headers: jsonHeaders()
              });
            }

            userStorage.updateUserInvitedStatus(address, true);
            userStorage.updateUserInviteRemainingUses(inviter.wallet_address, inviter.invite_remaining_uses - 1);
            return new Response(JSON.stringify({ success: true, granted: true }), {
              headers: jsonHeaders()
            });
          }

          case 'invite-count': {
            const body = await req.json() as { count: number };
            if (typeof body.count !== 'number' || body.count < 0 || body.count > 4294967295) {
              return new Response(JSON.stringify({ error: 'Invalid count (0-4294967295)' }), {
                status: 400,
                headers: jsonHeaders()
              });
            }

            userStorage.updateUserInviteRemainingUses(address, body.count);
            return new Response(JSON.stringify({ success: true, count: body.count }), {
              headers: jsonHeaders()
            });
          }

          case 'coop-arb': {
            const body = await req.json() as { status: boolean };
            userStorage.updateCoopArbStatus(address, body.status);
            return new Response(JSON.stringify({ success: true, coop_arb_status: body.status }), {
              headers: jsonHeaders()
            });
          }

          case 'can-use-agents': {
            const body = await req.json() as { status: boolean };
            userStorage.updateUserCanUseAgents(address, body.status);
            return new Response(JSON.stringify({ success: true, can_use_agents: body.status }), {
              headers: jsonHeaders()
            });
          }

          default:
            return new Response(JSON.stringify({ error: 'Unknown action' }), {
              status: 400,
              headers: jsonHeaders()
            });
        }
      } catch (error) {
        log.info(`Admin action error: ${error}`);
        return new Response(JSON.stringify({
          error: 'Admin action failed',
          message: error instanceof Error ? error.message : String(error)
        }), {
          status: 500,
          headers: jsonHeaders()
        });
      }
    }

    if (url.pathname === '/api/admin/users' && req.method === 'GET') {
      try {
        const token = extractBearerToken(req);
        if (!token) {
          return new Response(JSON.stringify({ error: 'Unauthorized' }), {
            status: 401,
            headers: jsonHeaders()
          });
        }

        const payload = verifyToken(token);
        if (!payload || payload.role !== 'admin') {
          return new Response(JSON.stringify({ error: 'Forbidden: admin only' }), {
            status: 403,
            headers: jsonHeaders()
          });
        }

        const userStorage = await getUserStorage();
        const users = userStorage.listUsers();

        return new Response(JSON.stringify({ users }), {
          headers: jsonHeaders()
        });
      } catch (error) {
        log.info(`List users error: ${error}`);
        return new Response(JSON.stringify({ error: 'Failed to list users' }), {
          status: 500,
          headers: jsonHeaders()
        });
      }
    }

    // ─────────────────────────────────────────────────────
    // Default 404
    // ─────────────────────────────────────────────────────

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

            const { systemPrompt, memories } = getAgentResources(agentId);

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
            const chatProvider = await getChatProviderForReasoning();

            const formattedContext = formatSearchResults(searchWithTiming.results, 12000);
            const conversationContext = formatConversationHistory(sessionContext.messages || []);
            const prompt = buildResponsePrompt({
              userQuery: msgData.message,
              formattedContext,
              conversationContext,
              systemPrompt,
              memories
            });

            const messages: ChatMessage[] = [
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
      log.info(`WebSocket opened: ${sessionId} -> ${agentId}`);
      ws.send(JSON.stringify({ type: 'connected', sessionId }));
    },

    close(ws, code, message) {
      const data = ws.data as WSClient | undefined;

      if (!data) return;

      const { sessionId } = data;
      log.info(`WebSocket closed: ${sessionId} (${code}) ${message}`);
    }
  }
});

async function initializeAgents(): Promise<void> {
  const st = await getStorageInstance();

  if (archivistConfig) {
    // Ensure hybrid search is always enabled
    archivistConfig.retrieval = archivistConfig.retrieval || {};
    archivistConfig.retrieval.enableRAG = true;
    archivistConfig.retrieval.useHybridSearch = true;

    try {
      await st.registerAgent(archivistConfig);
      log.info('✅ Archivist agent registered');

      // Cache system prompt and memories at startup
      await loadAgentResources('archivist');

      // Index knowledge and wait for completion
      log.info('🔄 Starting knowledge indexing...');
      const indexStart = Date.now();
      await indexKnowledge('archivist');
      const indexDuration = ((Date.now() - indexStart) / 1000).toFixed(1);
      log.info(`✅ Indexing completed in ${indexDuration}s`);

      // Invalidate search caches to ensure fresh results after reindexing
      clearLexicalIndex('archivist');
      invalidateVectorDBCache();
      log.info('✅ Search caches invalidated');

    } catch (error) {
      log.info(`❌ Failed to initialize archivist: ${error}`);
      throw error;
    }
  } else {
    log.info('⚠️  Archivist config not found');
    throw new Error('Archivist config is required');
  }
}

async function initializeServers(): Promise<void> {
  log.info('═══════════════════════════════════════════════════════════════');
  log.info('🚀 INITIALIZING AGENTS SERVER');
  log.info('═══════════════════════════════════════════════════════════════');

  // Step 0: Ensure TEI is running (starts via Docker if needed)
  // Skip TEI startup if TEI_EXTERNAL is set (TEI runs as external service)
  const teiExternal = process.env.TEI_EXTERNAL === 'true';
  if (teiExternal) {
    log.info('ℹ️  TEI_EXTERNAL is set - assuming TEI runs as external service');
  }
  try {
    await ensureTEIRunning();
  } catch (error) {
    if (teiExternal) {
      log.info(`⚠️  TEI not available (expected for external service): ${error}`);
      log.info('⚠️  Server will start but semantic search will fail until TEI is available');
    } else {
      log.info(`❌ Failed to start TEI: ${error}`);
      log.info('⚠️  Server cannot start without TEI. Please ensure Docker is running.');
      process.exit(1);
    }
  }

  // Step 1: Pre-initialize LLM providers
  log.info('⏳ Initializing LLM providers...');
  const providerStatus = await initializeProviders();
  if (!providerStatus.chatProviderReady) {
    log.info('⚠️  Chat provider not available - chat features will fail');
  }
  if (!providerStatus.embeddingProviderReady) {
    if (teiExternal) {
      log.info('⚠️  Embedding provider not available (TEI_EXTERNAL set - waiting for external TEI)');
    } else {
      log.info('❌ Embedding provider not available - server cannot start without semantic search');
      process.exit(1);
    }
  }
  log.info('✅ LLM providers ready');

  // Step 2: Initialize agents and wait for indexing to complete
  await initializeAgents();

  // Step 3: Mark server as ready
  serverReady = true;

  log.info('═══════════════════════════════════════════════════════════════');
  log.info(`📚 Agents server started on http://localhost:${port}`);
  log.info('   ✅ Hybrid search enabled (RAG + Lexical)');
  log.info('   ✅ Ready to process requests');
  log.info('═══════════════════════════════════════════════════════════════');
}

initializeServers();

/**
 * Get cached agent resources (system prompt + memories).
 * Loaded once at startup and cached for all requests.
 */
function getAgentResources(agentId: string): { systemPrompt: string; memories: string } {
  const cached = agentCache.get(agentId);
  if (cached) return cached;
  // Fallback if somehow cache is empty (shouldn't happen after init)
  return { systemPrompt: 'You are a helpful AI assistant.', memories: '' };
}

/**
 * Load and cache agent resources at startup.
 */
async function loadAgentResources(agentId: string): Promise<void> {
  const serverDir = new URL('.', import.meta.url).pathname;
  let systemPrompt = 'You are a helpful AI assistant.';
  let memories = '';

  try {
    const promptPath = `${serverDir}/${agentId}/agent.md`;
    const content = await Bun.file(promptPath).text();
    const match = content.match(/---[\s\S]*?---\n([\s\S]*)/);
    systemPrompt = match ? match[1]!.trim() : content;
  } catch (error) {
    log.info(`Failed to load system prompt for ${agentId}: ${error}`);
  }

  try {
    const memoriesPath = `${serverDir}/${agentId}/memories.md`;
    memories = await Bun.file(memoriesPath).text();
  } catch {
    // Memories are optional
  }

  agentCache.set(agentId, { systemPrompt, memories });
  if (debug) log.info(`Cached resources for ${agentId}: prompt=${systemPrompt.length} chars, memories=${memories.length} chars`);
}


async function shutdown() {
  log.info('Shutting down...');
  storage?.close();
  await stopTEI();
  process.exit(0);
}

process.on('SIGINT', () => shutdown());
process.on('SIGTERM', () => shutdown());

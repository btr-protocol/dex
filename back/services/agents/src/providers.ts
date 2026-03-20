import type { EmbeddingProvider, ChatProvider, ChatMessage, ChatOptions, StreamCompletionOptions } from '@shared/types';
import { zaiBaseUrl, zaiApiKey, zaiModelEnhancement, zaiModelReasoning } from '@shared/config';
import { TEIEmbeddingProvider } from './search/semantic/tei.js';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('zai');

export class ZAIChatProvider implements ChatProvider {
  private client: any = null;
  private baseUrl: string;
  private apiKey: string;
  private model: string;

  constructor(model?: string) {
    this.baseUrl = zaiBaseUrl;
    this.apiKey = zaiApiKey;
    this.model = model || 'glm-4.7';
  }

  async isAvailable(): Promise<boolean> {
    if (!this.apiKey || this.apiKey.length < 10) return false;

    try {
      const response = await fetch(`${this.baseUrl.replace('/chat/completions', '')}/models`, {
        method: 'GET',
        headers: {
          'Authorization': `Bearer ${this.apiKey}`
        },
        signal: AbortSignal.timeout(5000)
      });
      return response.ok;
    } catch {
      return false;
    }
  }

  async getClient(): Promise<any> {
    if (!this.client) {
      const { default: OpenAI } = await import('openai');
      this.client = new OpenAI({
        apiKey: this.apiKey,
        baseURL: this.baseUrl,
        // httpAgent is not supported in OpenAI SDK v4+, use default fetch
      });
    }
    return this.client;
  }

  async chatCompletion(
    messages: ChatMessage[],
    options: ChatOptions = {}
  ): Promise<string | AsyncGenerator<string>> {
    const client = await this.getClient();
    const {
      temperature = 0.4,
      maxTokens = 4096,
      stream = false,
      thinkingDisabled = true,  // Disabled by default for faster responses
      jsonMode = false
    } = options;

    const body: Record<string, unknown> = {
      model: this.model,
      messages,
      temperature,
      max_tokens: maxTokens,
      stream
    };

    // Add thinking parameter for faster responses when disabled
    if (thinkingDisabled) {
      body.thinking = { type: 'disabled' };
    }

    // Enforce JSON mode for structured outputs
    if (jsonMode) {
      body.response_format = { type: 'json_object' };
    }

    // Detailed logging for debugging
    const estimatedInputTokens = messages.reduce((sum, m) => sum + Math.ceil((m.content?.length || 0) / 4), 0);
    log.info('═══════════════════════════════════════════════════════════════');
    log.info('  ZAI API REQUEST');
    log.info('═══════════════════════════════════════════════════════════════');
    log.info(`  Endpoint: ${this.baseUrl}/chat/completions`);
    log.info(`  Model: ${this.model}`);
    log.info(`  Headers:`);
    log.info(`    Authorization: Bearer ${this.apiKey.slice(0, 10)}...${this.apiKey.slice(-4)}`);
    log.info(`  Body:`);
    log.info(`    model: ${body.model}`);
    log.info(`    temperature: ${body.temperature}`);
    log.info(`    max_tokens: ${body.max_tokens}`);
    log.info(`    stream: ${body.stream}`);
    if (body.thinking) log.info(`    thinking: ${JSON.stringify(body.thinking)}`);
    if (body.response_format) log.info(`    response_format: ${JSON.stringify(body.response_format)}`);
    log.info(`  Messages: ${messages.length} messages (~${estimatedInputTokens} tokens)`);
    messages.forEach((m, i) => {
      const contentLength = m.content?.length || 0;
      log.info(`    [${i}] ${m.role}: ${contentLength} chars`);
      // Log FULL message content for debugging
      if (m.role === 'user') {
        log.info(`    ┌─ FULL USER MESSAGE (${contentLength} chars) ─`);
        log.info(m.content || '');
        log.info(`    └─────────────────────────────────────────────────`);
      } else {
        const contentPreview = m.content?.slice(0, 200) || '';
        log.info(`      "${contentPreview}${contentLength > 200 ? '...' : ''}"`);
      }
    });
    log.info('═══════════════════════════════════════════════════════════════');

    const requestStart = performance.now();

    if (stream) {
      const response = await client.chat.completions.create(body);
      return this.streamResponse(response);
    } else {
      const response = await client.chat.completions.create(body);

      const requestDuration = performance.now() - requestStart;

      // Log response details
      const usage = (response as any).usage;
      const cachedTokens = usage?.prompt_tokens_details?.cached_tokens || 0;
      const promptTokens = usage?.prompt_tokens || 0;
      const completionTokens = usage?.completion_tokens || 0;
      const totalTokens = usage?.total_tokens || 0;

      log.info('═══════════════════════════════════════════════════════════════');
      log.info('  ZAI API RESPONSE');
      log.info('═══════════════════════════════════════════════════════════════');
      log.info(`  Request ID: ${(response as any).id}`);
      log.info(`  Duration: ${requestDuration.toFixed(0)}ms`);
      log.info(`  Usage:`);
      log.info(`    prompt_tokens: ${promptTokens}`);
      log.info(`    completion_tokens: ${completionTokens}`);
      log.info(`    total_tokens: ${totalTokens}`);
      log.info(`    cached_tokens: ${cachedTokens}`);
      if (cachedTokens > 0) {
        log.info(`  ⚡ Cache hit! ${(cachedTokens / promptTokens * 100).toFixed(1)}% of prompt was cached`);
      }
      log.info('═══════════════════════════════════════════════════════════════');

      return response.choices[0]?.message?.content || '';
    }
  }

  /**
   * Stream with early abort callback.
   * The callback receives each accumulated chunk and can return true to abort the stream.
   */
  async chatCompletionStreamWithAbort(
    messages: ChatMessage[],
    options: StreamCompletionOptions = {}
  ): Promise<string> {
    const client = await this.getClient();
    const {
      temperature = 0.1,
      maxTokens = 256,
      thinkingDisabled = true,
      jsonMode = true,
      abortCallback
    } = options;

    const body: Record<string, unknown> = {
      model: this.model,
      messages,
      temperature,
      max_tokens: maxTokens,
      stream: true
    };

    if (thinkingDisabled) {
      body.thinking = { type: 'disabled' };
    }

    if (jsonMode) {
      body.response_format = { type: 'json_object' };
    }

    const response = await client.chat.completions.create(body);
    let fullContent = '';

    for await (const chunk of response) {
      const delta = (chunk as { choices?: Array<{ delta?: { content?: string } }> }).choices?.[0]?.delta;
      const content = delta?.content;
      if (content) {
        fullContent += content;

        // Check if callback wants to abort early
        if (abortCallback && abortCallback(fullContent)) {
          // Close the connection and return what we have
          break;
        }
      }
    }

    return fullContent;
  }

  private async *streamResponse(response: any): AsyncGenerator<string> {
    for await (const chunk of response) {
      const delta = (chunk as { choices?: Array<{ delta?: { content?: string } }> }).choices?.[0]?.delta;
      const content = delta?.content;
      if (content) {
        yield content;
      }
    }
  }

  countTokens(text: string): number {
    return Math.ceil(text.length / 4);
  }
}

let embeddingProviderInstance: EmbeddingProvider | null = null;
let chatProviderEnhancementInstance: ChatProvider | null = null;
let chatProviderReasoningInstance: ChatProvider | null = null;

/**
 * Get the TEI embedding provider.
 * TEI (Text Embeddings Inference) provides high-performance embeddings via Docker.
 */
export async function getEmbeddingProvider(): Promise<EmbeddingProvider> {
  if (!embeddingProviderInstance) {
    embeddingProviderInstance = new TEIEmbeddingProvider();

    const available = await embeddingProviderInstance.isAvailable();
    if (!available) {
      throw new Error(
        'TEI embedding provider not available. Start the TEI container with:\n' +
        '  bun run back/agents/search/semantic/start-tei.ts'
      );
    }
    await embeddingProviderInstance.warmUp?.();
  }
  return embeddingProviderInstance;
}

/**
 * Get the chat provider for query enhancement (GLM-4.5-airx by default)
 */
export async function getChatProviderForEnhancement(): Promise<ChatProvider> {
  if (!chatProviderEnhancementInstance) {
    chatProviderEnhancementInstance = new ZAIChatProvider(zaiModelEnhancement);
    const available = await chatProviderEnhancementInstance.isAvailable();
    if (!available) {
      throw new Error('ZAI chat provider (enhancement) not available');
    }
  }
  return chatProviderEnhancementInstance;
}

/**
 * Get the chat provider for reasoning/response generation (GLM-4.7 by default)
 */
export async function getChatProviderForReasoning(): Promise<ChatProvider> {
  if (!chatProviderReasoningInstance) {
    chatProviderReasoningInstance = new ZAIChatProvider(zaiModelReasoning);
    const available = await chatProviderReasoningInstance.isAvailable();
    if (!available) {
      throw new Error('ZAI chat provider (reasoning) not available');
    }
  }
  return chatProviderReasoningInstance;
}

/**
 * Get the default chat provider (reasoning model)
 * @deprecated Use getChatProviderForEnhancement() or getChatProviderForReasoning() instead
 */
export async function getChatProvider(): Promise<ChatProvider> {
  return getChatProviderForReasoning();
}

/**
 * Pre-initialize all providers on server startup.
 * This ensures providers are ready before the first request.
 */
export async function initializeProviders(): Promise<{
  chatProviderReady: boolean;
  embeddingProviderReady: boolean;
}> {
  const results = {
    chatProviderReady: false,
    embeddingProviderReady: false
  };

  try {
    await getChatProviderForEnhancement();
    await getChatProviderForReasoning();
    results.chatProviderReady = true;
    log.info(`✅ Chat providers initialized (enhancement: ${zaiModelEnhancement}, reasoning: ${zaiModelReasoning})`);
  } catch (error) {
    log.warn(`⚠️  Chat provider initialization failed: ${error}`);
  }

  try {
    await getEmbeddingProvider();
    results.embeddingProviderReady = true;
    log.info('✅ Embedding provider initialized');
  } catch (error) {
    log.warn(`⚠️  Embedding provider initialization failed: ${error}`);
  }

  return results;
}

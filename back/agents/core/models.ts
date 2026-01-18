import type { EmbeddingProvider, ChatProvider, ChatMessage, ChatOptions } from './types.js';
import { zaiBaseUrl, zaiApiKey, ollamaUrl, embeddingModel, embeddingDimensions } from './config.js';

export class ZAIEmbeddingProvider implements EmbeddingProvider {
  private url: string;
  private apiKey: string;
  private model: string;
  private dimensions: number;

  constructor() {
    this.url = ollamaUrl;
    this.apiKey = zaiApiKey;
    this.model = embeddingModel;
    this.dimensions = embeddingDimensions;
  }

  async isAvailable(): Promise<boolean> {
    try {
      const response = await fetch(`${this.url}/api/tags`, {
        method: 'GET',
        signal: AbortSignal.timeout(5000)
      });
      return response.ok;
    } catch {
      return false;
    }
  }

  async warmUp(): Promise<void> {
    await this.generateEmbeddings(['warmup']);
  }

  getDimensions(): number {
    return this.dimensions;
  }

  async generateEmbeddings(texts: string[]): Promise<number[][]> {
    const concurrency = 5; // Reduced for embeddinggemma stability
    const allEmbeddings: (number[] | undefined)[] = new Array(texts.length);

    const generateOne = async (text: string): Promise<number[]> => {
      try {
        // Explicitly set a longer timeout for embeddinggemma
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 180000); // 3 minutes

        const response = await fetch(`${this.url}/api/embeddings`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            model: this.model,
            prompt: text
          }),
          signal: controller.signal
        });

        clearTimeout(timeoutId);

        if (!response.ok) {
          throw new Error(`Ollama error: ${response.statusText}`);
        }

        const json = await response.json() as Record<string, unknown>;
        const embedding = json.embedding as number[] ?? [];

        if (embedding.length !== this.dimensions) {
          console.warn(
            `Embedding dimension mismatch: expected ${this.dimensions}, got ${embedding.length}`
          );
        }

        return embedding;
      } catch (error) {
        console.error('Failed to generate embedding:', error);
        return new Array(this.dimensions).fill(0);
      }
    };

    for (let i = 0; i < texts.length; i += concurrency) {
      const batch = texts.slice(i, Math.min(i + concurrency, texts.length));
      const results = await Promise.all(batch.map(text => generateOne(text)));
      
      for (let j = 0; j < results.length; j++) {
        allEmbeddings[i + j] = results[j];
      }
      
      console.log(`Generated embeddings: ${Math.min(i + concurrency, texts.length)}/${texts.length}`);
    }

    return allEmbeddings.filter((e): e is number[] => e !== undefined);
  }
}

export class ZAIChatProvider implements ChatProvider {
  private client: any = null;
  private baseUrl: string;
  private apiKey: string;
  private model: string;

  constructor() {
    this.baseUrl = zaiBaseUrl;
    this.apiKey = zaiApiKey;
    this.model = 'glm-4.7';
  }

  async isAvailable(): Promise<boolean> {
    if (!this.apiKey || this.apiKey.length < 10) return false;

    try {
      const response = await fetch(`${this.baseUrl}/models`, {
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
        baseURL: this.baseUrl
      });
    }
    return this.client;
  }

  async chatCompletion(
    messages: ChatMessage[],
    options: ChatOptions = {}
  ): Promise<string | AsyncGenerator<string>> {
    const client = await this.getClient();
    const { temperature = 0.4, maxTokens = 4096, stream = false } = options;

    if (stream) {
      const response = await client.chat.completions.create({
        model: this.model,
        messages,
        temperature,
        maxTokens: maxTokens,
        stream: true
      });

      return this.streamResponse(response);
    } else {
      const response = await client.chat.completions.create({
        model: this.model,
        messages,
        temperature,
        maxTokens: maxTokens,
        stream: false
      });

      return response.choices[0]?.message?.content || '';
    }
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
let chatProviderInstance: ChatProvider | null = null;

export async function getEmbeddingProvider(): Promise<EmbeddingProvider> {
  if (!embeddingProviderInstance) {
    embeddingProviderInstance = new ZAIEmbeddingProvider();
    const available = await embeddingProviderInstance.isAvailable();
    if (!available) {
      throw new Error('Ollama embedding provider not available');
    }
    await embeddingProviderInstance.warmUp?.();
  }
  return embeddingProviderInstance;
}

export async function getChatProvider(): Promise<ChatProvider> {
  if (!chatProviderInstance) {
    chatProviderInstance = new ZAIChatProvider();
    const available = await chatProviderInstance.isAvailable();
    if (!available) {
      throw new Error('ZAI chat provider not available');
    }
  }
  return chatProviderInstance;
}

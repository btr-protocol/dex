/**
 * Base HTTP/WebSocket service with common functionality
 * - Port configuration from env
 * - CORS middleware
 * - Rate limiting
 * - Health checks
 * - Graceful shutdown
 */

import { logger } from '@btr/sdk/utils';

export interface HttpServiceConfig {
  name: string;
  portEnvVar: string;
  defaultPort: number;
  corsEnabled?: boolean;
  rateLimit?: {
    requestsPerMinute: number;
  };
}

export interface RateLimit {
  count: number;
  resetAt: number;
}

export abstract class HttpService {
  protected server: any = null;
  protected port: number;
  protected corsEnabled: boolean;
  protected rateLimitMap = new Map<string, RateLimit>();
  protected rateLimitPerMinute: number;
  protected log: ReturnType<typeof logger.withContext>;
  protected serviceName: string;
  protected ready = false;

  constructor(config: HttpServiceConfig) {
    this.serviceName = config.name;
    this.log = logger.withContext(config.name);

    // Port resolution: explicit env var > PORT > default
    const portFromEnv = process.env[config.portEnvVar];
    const portFromGeneric = process.env.PORT;
    this.port = parseInt(
      portFromEnv || portFromGeneric || config.defaultPort.toString(),
      10
    );

    this.corsEnabled = config.corsEnabled ?? (process.env.CORS_ENABLED !== 'false');
    this.rateLimitPerMinute = config.rateLimit?.requestsPerMinute ?? 60;

    this.log.info(`Configured on port ${this.port}`);
  }

  /**
   * CORS headers for responses
   */
  protected corsHeaders(): Record<string, string> {
    if (!this.corsEnabled) return {};
    return {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Session-ID',
      'Access-Control-Max-Age': '86400',
    };
  }

  /**
   * JSON response headers
   */
  protected jsonHeaders(): Record<string, string> {
    return {
      ...this.corsHeaders(),
      'Content-Type': 'application/json',
    };
  }

  /**
   * Extract session ID from request
   */
  protected getSessionId(req: Request): string {
    return req.headers.get('X-Session-ID') || req.headers.get('x-session-id') || 'default';
  }

  /**
   * Check rate limit for a session
   */
  protected checkRateLimit(sessionId: string): boolean {
    const now = Date.now();
    const limit = this.rateLimitMap.get(sessionId);

    if (!limit || now > limit.resetAt) {
      this.rateLimitMap.set(sessionId, { count: 1, resetAt: now + 60000 });
      return true;
    }

    if (limit.count >= this.rateLimitPerMinute) {
      this.log.warn(`Rate limit exceeded for session ${sessionId}`);
      return false;
    }

    limit.count++;
    return true;
  }

  /**
   * Handle OPTIONS requests for CORS
   */
  protected handleOptions(): Response {
    return new Response(null, {
      status: 204,
      headers: this.corsHeaders(),
    });
  }

  /**
   * Default health check response
   */
  protected healthCheckResponse(): Response {
    return new Response(
      JSON.stringify({
        status: this.ready ? 'ok' : 'starting',
        ready: this.ready,
        service: this.serviceName,
        port: this.port,
        timestamp: Date.now(),
      }),
      {
        status: this.ready ? 200 : 503,
        headers: this.jsonHeaders(),
      }
    );
  }

  /**
   * Mark service as ready
   */
  protected markReady(): void {
    this.ready = true;
    this.log.info(`Service ready on http://localhost:${this.port}`);
  }

  /**
   * Abstract method - implement the request handler
   */
  protected abstract handleRequest(req: Request): Promise<Response> | Response;

  /**
   * Start the HTTP server
   */
  async start(): Promise<void> {
    this.server = Bun.serve({
      port: this.port,
      fetch: async (req) => {
        const url = new URL(req.url);

        // Handle OPTIONS
        if (req.method === 'OPTIONS') {
          return this.handleOptions();
        }

        // Health check
        if (url.pathname === '/health') {
          return this.healthCheckResponse();
        }

        // Delegate to service implementation
        return this.handleRequest(req);
      },
    });

    this.log.info(`HTTP server listening on http://localhost:${this.port}`);
  }

  /**
   * Stop the HTTP server
   */
  async stop(): Promise<void> {
    if (this.server) {
      this.server.stop();
      this.log.info('HTTP server stopped');
    }
  }

  /**
   * Get the server port
   */
  getPort(): number {
    return this.port;
  }

  /**
   * Check if service is ready
   */
  isReady(): boolean {
    return this.ready;
  }
}

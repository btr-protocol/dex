/**
 * Safe operation utilities - property access, retries, timing
 */

// ─────────────────────────────────────────────────────────────
// Safe Property Access
// ─────────────────────────────────────────────────────────────

/**
 * Safe property access with type checking
 */
export const safeGet = <T extends object, K extends keyof T>(
  obj: T | undefined,
  key: K,
): T[K] | undefined => {
  return obj ? obj[key] : undefined;
};

// ─────────────────────────────────────────────────────────────
// Timing & Retry
// ─────────────────────────────────────────────────────────────

/**
 * Sleep utility
 */
export function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * Retry with exponential backoff
 */
export async function retryWithBackoff<T>(
  fn: () => Promise<T>,
  maxRetries: number = 3,
  baseDelay: number = 1000,
): Promise<T> {
  let lastError: Error | undefined;

  for (let i = 0; i < maxRetries; i++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error as Error;
      if (i < maxRetries - 1) {
        const delay = baseDelay * Math.pow(2, i);
        await sleep(delay);
      }
    }
  }

  throw lastError;
}

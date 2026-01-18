/**
 * ID generation utilities
 * Provides consistent ID generation patterns across the app
 */

/**
 * Generate a session ID with timestamp and random component
 * Format: session-{timestamp}-{random}
 */
export function generateSessionId(): string {
  return `session-${Date.now()}-${Math.random().toString(36).substring(2, 11)}`;
}

/**
 * Generate a custom ID with prefix
 * Format: {prefix}-{timestamp}-{random}
 */
export function generateId(prefix: string = ''): string {
  return prefix ? `${prefix}-${Date.now()}-${Math.random().toString(36).substring(2, 11)}` : generateSessionId();
}

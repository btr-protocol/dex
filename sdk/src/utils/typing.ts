/**
 * Type utilities - guards, casting, JSON parsing
 */

// ─────────────────────────────────────────────────────────────
// Type Guards
// ─────────────────────────────────────────────────────────────

/**
 * Type guard: check if value is a non-null object
 */
export const isObject = (value: unknown): value is Record<string, unknown> => {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
};

/**
 * Type guard: check if object has property with specific type
 */
export const hasProperty = <K extends PropertyKey>(
  obj: unknown,
  key: K,
): obj is Record<K, unknown> => {
  return isObject(obj) && key in obj;
};

// ─────────────────────────────────────────────────────────────
// Safe Casting
// ─────────────────────────────────────────────────────────────

/**
 * Safe type casting for values from untyped sources
 * Use as intermediate step: (value as unknown as T)
 */
export const safeCast = <T>(value: unknown): T => {
  return value as unknown as T;
};

// ─────────────────────────────────────────────────────────────
// Safe JSON Parsing
// ─────────────────────────────────────────────────────────────

/**
 * Safe JSON parsing with type safety
 * Validates that result is an object (not array, not null)
 */
export const safeJson = <T extends object>(text: string): T | undefined => {
  try {
    const v = JSON.parse(text);
    return (v && typeof v === 'object' && !Array.isArray(v)) ? (v as T) : undefined;
  } catch {
    return undefined;
  }
};

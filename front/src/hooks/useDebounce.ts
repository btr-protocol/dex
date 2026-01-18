/**
 * useDebounce hook - Debounces a value with a configurable delay
 * Useful for search inputs, auto-save, etc.
 */
import { useState, useEffect } from 'preact/hooks';

export function useDebounce<T>(value: T, delay: number = 300): T {
  const [debouncedValue, setDebouncedValue] = useState<T>(value);

  useEffect(() => {
    const timer = setTimeout(() => {
      setDebouncedValue(value);
    }, delay);

    return () => clearTimeout(timer);
  }, [value, delay]);

  return debouncedValue;
}

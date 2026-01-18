import { useState, useCallback } from 'preact/hooks';

/**
 * Hook for managing filter state with reset functionality
 * Provides a consistent pattern for filter reset across the app
 */
export function useFilters<T extends Record<string, any>>(
  initialFilters: T,
  onReset?: () => void
) {
  const [filters, setFilters] = useState(initialFilters);

  const resetFilters = useCallback(() => {
    setFilters(initialFilters);
    onReset?.();
  }, [initialFilters, onReset]);

  const updateFilter = useCallback(<K extends keyof T>(key: K, value: T[K]) => {
    setFilters({ ...filters, [key]: value });
  }, [filters]);

  const hasActiveFilters = !Object.entries(filters).every(([key, value]) =>
    value === initialFilters[key as keyof T]
  );

  return { filters, setFilters, resetFilters, updateFilter, hasActiveFilters };
}

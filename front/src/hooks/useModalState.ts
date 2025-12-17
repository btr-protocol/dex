import { useState, useEffect } from 'preact/hooks';

/**
 * Generic hook for managing modal state with automatic reset on open/close
 * Consolidates repeated pattern: useState + useEffect reset across modals
 *
 * @example
 * const [query, setQuery] = useModalState<string>({
 *   isOpen,
 *   initialState: '',
 *   resetDeps: [isOpen]
 * });
 */
export function useModalState<T>(
  initialState: T,
  isOpen: boolean,
  resetDeps: any[] = []
): [T, (value: T | ((prev: T) => T)) => void] {
  const [state, setState] = useState<T>(initialState);

  useEffect(() => {
    if (isOpen) {
      setState(initialState);
    }
  }, [isOpen, ...resetDeps]);

  return [state, setState];
}

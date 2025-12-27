import { useState, useEffect } from 'preact/hooks';

type Dependency = string | number | boolean | symbol | object | null | undefined;
type DependencyList = readonly Dependency[];

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
  resetDeps: DependencyList = []
): [T, (value: T | ((prev: T) => T)) => void] {
  const [state, setState] = useState<T>(initialState);

  useEffect(() => {
    if (isOpen) {
      setState(initialState);
    }
  }, [isOpen, ...resetDeps]);

  return [state, setState];
}

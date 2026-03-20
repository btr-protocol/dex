/**
 * useAsync - Generic async data fetching hook
 * Replaces pattern: useState + useEffect for data fetching
 *
 * Usage:
 * const { data, loading, error } = useAsync(fetchFunction, dependencies);
 */
import { useState, useEffect, useCallback, useRef } from 'preact/hooks';
import { logger } from '@sdk/utils';

const log = logger.withContext('useAsync');

export interface AsyncState<T> {
  data: T | null;
  loading: boolean;
  error: Error | null;
}

type AsyncFunction<T> = () => Promise<T>;
type Dependency = string | number | boolean | symbol | object | null | undefined;
type DependencyList = readonly Dependency[];

export function useAsync<T>(
  asyncFunction: AsyncFunction<T>,
  immediate = true,
  dependencies: DependencyList = []
): AsyncState<T> & { refetch: () => Promise<void> } {
  const [state, setState] = useState<AsyncState<T>>({
    data: null,
    loading: immediate,
    error: null,
  });

  const isMountedRef = useRef(true);

  const execute = useCallback(async () => {
    setState(prev => ({ ...prev, loading: true, error: null }));
    try {
      const response = await asyncFunction();
      if (isMountedRef.current) {
        setState({ data: response, loading: false, error: null });
      }
    } catch (error) {
      if (isMountedRef.current) {
        setState({
          data: null,
          loading: false,
          error: error instanceof Error ? error : new Error(String(error)),
        });
      }
    }
  }, [asyncFunction]);

  useEffect(() => {
    if (immediate) {
      execute();
    }
    return () => {
      isMountedRef.current = false;
    };
  }, dependencies);

  return {
    ...state,
    refetch: execute,
  };
}

/**
 * useAsyncEffect - For side effects that need async handling
 */
export function useAsyncEffect(
  effect: () => Promise<void> | void,
  dependencies?: DependencyList
) {
  useEffect(() => {
    let isMounted = true;

    (async () => {
      try {
        await effect();
      } catch (error) {
        if (isMounted) {
          log.error('useAsyncEffect error', error);
        }
      }
    })();

    return () => {
      isMounted = false;
    };
  }, dependencies);
}

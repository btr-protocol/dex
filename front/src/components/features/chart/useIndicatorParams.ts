/**
 * Hook for managing indicator parameters
 */
import { useState, useCallback } from 'preact/hooks';
import type { IndicatorParams } from '@utils/indicators';
import { type IndicatorKey, DEFAULT_PARAMS } from './indicatorsConfig';

export interface InitialIndicator {
  preset: IndicatorKey;
  params: IndicatorParams;
}

export function useIndicatorParams(initial: InitialIndicator[] = []) {
  const [paramsMap, setParamsMap] = useState<Map<IndicatorKey, IndicatorParams>>(() => {
    const map = new Map<IndicatorKey, IndicatorParams>();
    initial.forEach(i => map.set(i.preset, i.params));
    return map;
  });

  const getParams = useCallback((key: IndicatorKey): IndicatorParams => {
    return paramsMap.get(key) ?? { ...DEFAULT_PARAMS };
  }, [paramsMap]);

  const setParams = useCallback((key: IndicatorKey, params: IndicatorParams) => {
    setParamsMap(prev => {
      const next = new Map(prev);
      next.set(key, params);
      return next;
    });
  }, []);

  return { getParams, setParams, paramsMap };
}

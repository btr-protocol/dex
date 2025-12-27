import { useState, useEffect } from 'preact/hooks';
import { useWallet } from '@lib/wallet';
import * as eth from '@sdk/eth';

// ─────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────

// Dependency array type - values used for cache key generation via JSON.stringify
// Permits objects that may not be perfectly JSON-serializable since we rely on
// reference equality for complex types like provider, Call[], etc.
type DependencyValue = string | number | boolean | bigint | null | undefined | object;
type DependencyArray = readonly DependencyValue[];

// ─────────────────────────────────────────────────────────────
// Internal Helpers
// ─────────────────────────────────────────────────────────────

// Generic fetcher with cancellation & state management
function useFetch<T>(
  fn: () => Promise<T>,
  deps: DependencyArray,
  enabled = true
) {
  const [state, setState] = useState<{ data?: T; loading: boolean; error?: Error | object }>({
    loading: enabled,
    data: undefined
  });

  // Deep compare deps (simple JSON version for brevity/robustness)
  const depKey = JSON.stringify(deps);

  useEffect(() => {
    if (!enabled) return;
    let active = true;
    setState(s => ({ ...s, loading: true, error: undefined }));

    fn().then(
      res => active && setState({ data: res, loading: false }),
      (err: Error | object) => active && setState({ data: undefined, loading: false, error: err })
    );

    return () => { active = false; };
  }, [depKey, enabled]);

  return state;
}

// ─────────────────────────────────────────────────────────────
// Hooks
// ─────────────────────────────────────────────────────────────

export function useReadContract<T = object>(p: {
  address?: eth.Address;
  abi: eth.Abi;
  functionName: string;
  args?: DependencyArray;
  query?: { enabled?: boolean }
}) {
  const { provider } = useWallet();
  const enabled = (p.query?.enabled ?? true) && !!p.address && !!provider;

  return useFetch<T>(
    () => eth.readContract(provider!, p.address!, p.abi, p.functionName, p.args),
    [p.address, p.functionName, p.args, provider],
    enabled
  );
}

export function useReadContracts(p: { 
  contracts: eth.Call[]; 
  query?: { enabled?: boolean } 
}) {
  const { provider } = useWallet();
  const enabled = (p.query?.enabled ?? true) && !!provider && p.contracts.length > 0;

  // Transform results to match previous API { result, error }
  const { data, ...rest } = useFetch(
    async () => {
      const res = await eth.multicall(provider!, p.contracts.map(c => ({ ...c, allowFailure: true })));
      return res.map((r: { success: boolean; result?: object; error?: Error | object }) => ({ result: r.success ? r.result : undefined, error: r.success ? undefined : r.error }));
    },
    [p.contracts, provider],
    enabled
  );

  return { ...rest, data: data || [] };
}

export function useBlockNumber(interval = 12000) {
  const { provider } = useWallet();
  const [block, setBlock] = useState<bigint>();

  useEffect(() => {
    if (!provider) return;
    const tick = () => eth.getBlockNumber(provider).then(setBlock).catch(() => {});
    tick();
    const id = setInterval(tick, interval);
    return () => clearInterval(id);
  }, [provider, interval]);

  return { data: block };
}

// Passthrough alias (optional, can just use useWallet directly)
export const useAccount = () => {
  const { address, isConnected } = useWallet();
  return { address, isConnected };
};

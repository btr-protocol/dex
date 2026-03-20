import { useEffect, useCallback } from 'preact/hooks';
import { useWallet } from '@lib/wallet';
import type { Eip1193Provider } from '@sdk/eth';
import { healthStore, type HealthStatus } from '@/lib/health/HealthStore';

// Re-export for backward compatibility
export type { HealthStatus };

interface HealthMonitorState {
  api: HealthStatus;
  static: HealthStatus;
  rpc: HealthStatus;
}

// Fallback public RPC endpoints for when wallet is not connected
const FALLBACK_RPC_URLS: Record<number, string> = {
  1: 'https://eth.llamarpc.com', // Ethereum mainnet
  8453: 'https://mainnet.base.org', // Base
  42161: 'https://arb1.arbitrum.io/rpc', // Arbitrum
  10: 'https://mainnet.optimism.io', // Optimism
  137: 'https://polygon-rpc.com', // Polygon
};

// Health check intervals with jitter to avoid rate limiting
const API_POLL_INTERVAL = 5000; // 5 seconds for API (local backend)
const STATIC_POLL_INTERVAL = 10000; // 10 seconds for static files
const RPC_POLL_INTERVAL = 30000; // 30 seconds for RPC (to stay under provider limits)

const API_URL = 'http://localhost:3000/health';
const STATIC_URL = '/health.json';

// Add jitter to intervals to avoid synchronized bursts
function getJitteredInterval(baseInterval: number): number {
  const jitter = Math.random() * 5000; // 0-5 seconds
  return baseInterval + jitter;
}

function getStatusFromLatency(latency: number | null): 'healthy' | 'degraded' | 'down' {
  if (latency === null) return 'down';
  if (latency < 150) return 'healthy';
  if (latency < 500) return 'degraded';
  return 'down';
}

async function checkEndpoint(url: string): Promise<HealthStatus> {
  const start = performance.now();
  try {
    const response = await fetch(url, {
      method: 'HEAD',
      cache: 'no-cache',
    });
    const latency = Math.round(performance.now() - start);

    if (!response.ok) {
      return { latency: null, status: 'down' };
    }

    return {
      latency,
      status: getStatusFromLatency(latency),
    };
  } catch (error) {
    return { latency: null, status: 'down' };
  }
}

async function checkRPC(provider: Eip1193Provider | undefined, fallbackChainId?: number): Promise<HealthStatus> {
  const start = performance.now();

  // If we have a wallet provider, use it
  if (provider) {
    try {
      await provider.request({
        method: 'eth_blockNumber',
        params: []
      });
      const latency = Math.round(performance.now() - start);
      return {
        latency,
        status: getStatusFromLatency(latency),
      };
    } catch (error) {
      return { latency: null, status: 'down' };
    }
  }

  // Fallback to public RPC endpoint when no wallet is connected
  const chainId = fallbackChainId || 1; // Default to Ethereum mainnet
  const rpcUrl = FALLBACK_RPC_URLS[chainId];

  if (!rpcUrl) {
    return { latency: null, status: 'down' };
  }

  try {
    const response = await fetch(rpcUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'eth_blockNumber',
        params: []
      })
    });

    const latency = Math.round(performance.now() - start);

    if (!response.ok) {
      return { latency: null, status: 'down' };
    }

    const data = await response.json();

    if (data.error) {
      return { latency: null, status: 'down' };
    }

    return {
      latency,
      status: getStatusFromLatency(latency),
    };
  } catch (error) {
    return { latency: null, status: 'down' };
  }
}

export function useHealthMonitor() {
  const { provider, chainId } = useWallet();

  // Use signal-based HealthStore for fine-grained updates (each endpoint updates independently)
  const checkAPI = useCallback(async () => {
    const result = await checkEndpoint(API_URL);
    healthStore.setApiHealth(result);
  }, []);

  const checkStatic = useCallback(async () => {
    const result = await checkEndpoint(STATIC_URL);
    healthStore.setStaticHealth(result);
  }, []);

  const checkRPCHealth = useCallback(async () => {
    const result = await checkRPC(provider, chainId);
    healthStore.setRpcHealth(result);
  }, [provider, chainId]);

  useEffect(() => {
    // Initial checks
    checkAPI();
    checkStatic();
    checkRPCHealth();

    // Set up separate intervals with jitter for each endpoint
    const apiInterval = setInterval(() => checkAPI(), getJitteredInterval(API_POLL_INTERVAL));
    const staticInterval = setInterval(() => checkStatic(), getJitteredInterval(STATIC_POLL_INTERVAL));
    const rpcInterval = setInterval(() => checkRPCHealth(), getJitteredInterval(RPC_POLL_INTERVAL));

    return () => {
      clearInterval(apiInterval);
      clearInterval(staticInterval);
      clearInterval(rpcInterval);
    };
  }, [checkAPI, checkStatic, checkRPCHealth]);

  // Re-check RPC immediately when chain or provider changes
  useEffect(() => {
    checkRPCHealth();
  }, [chainId, provider, checkRPCHealth]);

  // Return signal values for backward compatibility
  return healthStore.getState();
}

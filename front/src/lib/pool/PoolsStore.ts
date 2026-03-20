/**
 * PoolsStore - Signal-based pools API state management
 * Replaces 3 useState calls in usePoolsAPI.ts (pools, loading, error)
 * Optimizes 5-second polling with batched updates
 */
import { signal, computed, batch } from '@preact/signals';
import type { PoolAssetAPI } from './types';

// Re-export for backward compatibility
export type { PoolAssetAPI as PoolAsset };
export type { PoolAssetAPI };

export interface Pool {
  name: string;
  address: string;
  assets: PoolAssetAPI[];
}

export class PoolsStore {
  // Pools data signals
  public pools = signal<Pool[]>([]);
  public loading = signal(true);
  public error = signal<string | null>(null);

  // Computed: has pools loaded
  public hasPools = computed(() => this.pools.value.length > 0);

  // Computed: is ready (has data and not loading)
  public isReady = computed(() =>
    !this.loading.value && this.pools.value.length > 0
  );

  // Computed: pool count
  public poolCount = computed(() => this.pools.value.length);

  /**
   * Set pools data (batched update)
   */
  public setPools(pools: Pool[]) {
    batch(() => {
      this.pools.value = pools;
      this.loading.value = false;
      this.error.value = null;
    });
  }

  /**
   * Set error state (batched update)
   */
  public setError(error: string) {
    batch(() => {
      this.error.value = error;
      this.loading.value = false;
    });
  }

  /**
   * Start loading
   */
  public startLoading() {
    this.loading.value = true;
  }

  /**
   * Update pools without changing loading state
   * Used for background refresh while pools are already loaded
   */
  public updatePools(pools: Pool[]) {
    batch(() => {
      this.pools.value = pools;
      this.error.value = null;
    });
  }

  /**
   * Get pool by address
   */
  public getPoolByAddress(address: string): Pool | undefined {
    return this.pools.value.find(p =>
      p.address.toLowerCase() === address.toLowerCase()
    );
  }

  /**
   * Get pool by name
   */
  public getPoolByName(name: string): Pool | undefined {
    return this.pools.value.find(p =>
      p.name.toLowerCase() === name.toLowerCase()
    );
  }

  /**
   * Reset all state
   */
  public reset() {
    batch(() => {
      this.pools.value = [];
      this.loading.value = true;
      this.error.value = null;
    });
  }
}

// Singleton instance for global pool data
export const poolsStore = new PoolsStore();

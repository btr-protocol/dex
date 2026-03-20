import { signal, computed, type Signal } from '@preact/signals';
import { AssetData } from '@/hooks/useLiquidityData';

export type Timeframe = '1h' | '4h' | '12h' | '24h' | '3d' | '7d' | '30d';

export class LiquidityStore {
    // UI State signals
    public searchQuery = signal('');
    public timeframe = signal<Timeframe>('24h');
    public expandedPool = signal<string>('Genesis');
    public expandedAsset = signal<string | null>(null);

    // Methods to update state
    public setSearchQuery = (query: string) => {
        this.searchQuery.value = query;
    };

    public setTimeframe = (tf: Timeframe) => {
        this.timeframe.value = tf;
    };

    public togglePool = (poolName: string) => {
        this.expandedPool.value = this.expandedPool.value === poolName ? '' : poolName;
    };

    public toggleAsset = (assetId: string) => {
        this.expandedAsset.value = this.expandedAsset.value === assetId ? null : assetId;
    };

    /**
     * Derived state for filtering (method-based, backward compatible)
     * @deprecated Use createFilteredAssets() for reactive computed signals
     */
    public getFilteredAssets(assets: AssetData[]) {
        const query = this.searchQuery.value.toLowerCase().trim();
        if (!query) return assets;

        return assets.filter(asset =>
            asset.symbol.toLowerCase().includes(query) ||
            asset.name.toLowerCase().includes(query) ||
            asset.address.toLowerCase().includes(query)
        );
    }

    /**
     * Create a computed signal for filtered assets
     * Reactively filters assets based on searchQuery signal
     *
     * @param assetsSignal - Signal containing the assets to filter
     * @returns Computed signal with filtered assets
     *
     * @example
     * const pool = signal({ name: 'Genesis', assets: [...] });
     * const filteredAssets = liquidityStore.createFilteredAssets(
     *   computed(() => pool.value.assets)
     * );
     * // filteredAssets.value updates automatically when searchQuery or assets change
     */
    public createFilteredAssets(assetsSignal: Signal<AssetData[]>) {
        return computed(() => {
            const assets = assetsSignal.value;
            const query = this.searchQuery.value.toLowerCase().trim();

            if (!query) return assets;

            return assets.filter(asset =>
                asset.symbol.toLowerCase().includes(query) ||
                asset.name.toLowerCase().includes(query) ||
                asset.address.toLowerCase().includes(query)
            );
        });
    }

    /**
     * Helper to filter assets from a plain array (creates computed on-the-fly)
     * Use this when you have a static/memoized array but want reactive filtering
     *
     * @param assets - Array of assets to filter
     * @returns Filtered array
     */
    public filterAssets = (assets: AssetData[]) => {
        const query = this.searchQuery.value.toLowerCase().trim();
        if (!query) return assets;

        return assets.filter(asset =>
            asset.symbol.toLowerCase().includes(query) ||
            asset.name.toLowerCase().includes(query) ||
            asset.address.toLowerCase().includes(query)
        );
    };
}

// Global instance for the page (could also be provided via context)
export const liquidityStore = new LiquidityStore();

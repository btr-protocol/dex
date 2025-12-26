import { signal } from '@preact/signals';
import { AssetData } from '@/hooks/useLiquidityData';

export type Timeframe = '1h' | '4h' | '12h' | '24h' | '3d' | '7d' | '30d';

export class LiquidityStore {
    // UI State
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

    // Derived state for filtering
    public getFilteredAssets(assets: AssetData[]) {
        const query = this.searchQuery.value.toLowerCase().trim();
        if (!query) return assets;
        
        return assets.filter(asset =>
            asset.symbol.toLowerCase().includes(query) ||
            asset.name.toLowerCase().includes(query) ||
            asset.address.toLowerCase().includes(query)
        );
    }
}

// Global instance for the page (could also be provided via context)
export const liquidityStore = new LiquidityStore();

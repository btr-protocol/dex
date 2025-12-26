import { signal } from '@preact/signals';
import { Address } from '@sdk/eth';

export interface PoolAsset {
  address: Address;
  symbol: string;
  decimals: number;
  reserves: bigint;
  liabilities: bigint;
  coverageRatio: bigint;
  price: bigint;
}

export class PoolStore {
  public assets = signal<PoolAsset[]>([]);
  public isLoading = signal<boolean>(false);
  public error = signal<string | null>(null);

  public setAssets = (assets: PoolAsset[]) => {
    this.assets.value = assets;
  };

  public setLoading = (loading: boolean) => {
    this.isLoading.value = loading;
  };

  public setError = (error: string | null) => {
    this.error.value = error;
  };
}

export const poolStore = new PoolStore();

/**
 * Shared pool types
 * Consolidated from multiple locations to eliminate duplication
 */

import type { Address } from '@sdk/eth';

/**
 * Pool asset data from contract (on-chain data, bigints)
 * Used by: usePoolState, usePoolContracts
 */
export interface PoolAssetContract {
  address: Address;
  symbol: string;
  decimals: number;
  reserves: bigint;
  liabilities: bigint;
  coverageRatio: bigint;
  price: bigint;
}

/**
 * Pool asset data from API (JSON data, strings)
 * Used by: PoolsStore, usePoolsAPI
 */
export interface PoolAssetAPI {
  token: string;
  symbol: string;
  name: string;
  decimals: number;
  reserves: string;
  liabilities: string;
  coverage: string;
}

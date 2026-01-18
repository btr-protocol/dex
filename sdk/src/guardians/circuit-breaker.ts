/**
 * Circuit Breaker Guardian
 *
 * Monitors asset deviations and triggers circuit breakers when necessary.
 * All deviation checking is performed off-chain.
 *
 * Deviation methodologies:
 * - Stablecoins: Direct oracle price comparison (USDC vs DAI should be ~1:1)
 * - Correlated assets (LSTs): Compare relative weekly price changes
 *   Example: If WETH +5% over week and wstETH +2%, deviation = 3%
 * - Volatile assets: Same relative change methodology with higher thresholds
 *
 * @module @btr/dex-sdk/guardians
 */

import type { Address, Eip1193Provider } from '../eth/index.js';
import { BaseGuardian, type OracleProvider, type PricePoint } from './base-guardian.js';
import type { GuardianConfig } from '../utils/constants.js';
import { BPS_PRECISION, ONE_DAY } from '../utils/constants.js';

export interface CircuitBreakerAssetConfig {
  address: Address;
  name: string;
  referenceAsset: Address;
  maxDivergence: number; // in basis points
}

export interface CircuitBreakerGuardianConfig {
  poolAddress: Address;
  assets: CircuitBreakerAssetConfig[];
  checkInterval: number;
  cooldownPeriod: number;
  maxDivergence: number;
}

const WEEK_IN_SECONDS = 7 * ONE_DAY;
const STABLECOIN_THRESHOLD = 200; // 2% - anything below this is treated as stablecoin

/**
 * Check stablecoin deviation using direct price comparison
 */
function checkStablecoinDeviation(assetPrice: bigint, refPrice: bigint): number {
  if (refPrice === 0n) return 0;

  const diff = assetPrice > refPrice ? assetPrice - refPrice : refPrice - assetPrice;
  return Number((diff * BPS_PRECISION) / refPrice);
}

/**
 * Check correlated asset deviation using relative weekly price changes
 */
function checkCorrelatedAssetDeviation(
  assetPrices: PricePoint[],
  refPrices: PricePoint[],
): number {
  if (assetPrices.length < 2 || refPrices.length < 2) {
    throw new Error('Insufficient price history');
  }

  const assetPriceWeekAgo = assetPrices[0].price;
  const assetPriceNow = assetPrices[assetPrices.length - 1].price;

  const refPriceWeekAgo = refPrices[0].price;
  const refPriceNow = refPrices[refPrices.length - 1].price;

  // Calculate percentage changes (in 1e18 precision)
  const PRECISION = 10n ** 18n;
  const assetChange = ((assetPriceNow - assetPriceWeekAgo) * PRECISION) / assetPriceWeekAgo;
  const refChange = ((refPriceNow - refPriceWeekAgo) * PRECISION) / refPriceWeekAgo;

  // Deviation is the difference in relative changes
  const deviation = assetChange > refChange ? assetChange - refChange : refChange - assetChange;
  return Number((deviation * BPS_PRECISION) / PRECISION);
}

export class CircuitBreakerGuardian {
  private provider: Eip1193Provider;
  private config: CircuitBreakerGuardianConfig;
  private oracleProvider: OracleProvider;
  private poolAbi: any;
  private isRunning: boolean = false;

  constructor(
    provider: Eip1193Provider,
    config: CircuitBreakerGuardianConfig,
    poolAbi: any,
    oracleProvider: OracleProvider,
  ) {
    this.provider = provider;
    this.config = config;
    this.poolAbi = poolAbi;
    this.oracleProvider = oracleProvider;
  }

  private async checkAsset(assetAddress: Address): Promise<void> {
    const asset = this.config.assets.find(a => a.address === assetAddress);
    if (!asset) return;

    // Skip if no reference asset configured
    if (asset.referenceAsset === '0x0000000000000000000000000000000000000000') {
      return;
    }

    // Check if asset is already frozen
    const assetData = await this.getAssetData(asset.address);
    if (assetData.isFrozen) {
      console.log(`Asset ${asset.name} already frozen, skipping`);
      return;
    }

    let deviationBps: number;

    try {
      // Determine check type based on threshold
      if (asset.maxDivergence <= STABLECOIN_THRESHOLD) {
        // Stablecoin: use direct price comparison
        deviationBps = await this.checkStablecoin(asset.address, asset.referenceAsset);
      } else {
        // Correlated/volatile: use relative weekly change comparison
        deviationBps = await this.checkCorrelated(asset.address, asset.referenceAsset);
      }

      console.log(
        `${asset.name}: deviation ${deviationBps}bps, threshold ${asset.maxDivergence}bps`
      );

      // Trigger circuit breaker if deviation exceeds threshold
      if (deviationBps > asset.maxDivergence) {
        await this.triggerCircuitBreaker(asset, deviationBps);
      }
    } catch (error) {
      console.error(`Error checking ${asset.name}:`, error);
      throw error;
    }
  }

  private async checkStablecoin(assetAddress: Address, refAddress: Address): Promise<number> {
    const [assetPrice, refPrice] = await Promise.all([
      this.oracleProvider.getPrice(assetAddress),
      this.oracleProvider.getPrice(refAddress),
    ]);

    return checkStablecoinDeviation(assetPrice, refPrice);
  }

  private async checkCorrelated(assetAddress: Address, refAddress: Address): Promise<number> {
    const now = Math.floor(Date.now() / 1000);
    const weekAgo = now - WEEK_IN_SECONDS;

    const [assetPrices, refPrices] = await Promise.all([
      this.oracleProvider.getHistoricalPrices(assetAddress, weekAgo, now),
      this.oracleProvider.getHistoricalPrices(refAddress, weekAgo, now),
    ]);

    return checkCorrelatedAssetDeviation(assetPrices, refPrices);
  }

  private async triggerCircuitBreaker(
    asset: CircuitBreakerAssetConfig,
    deviationBps: number,
  ): Promise<void> {
    console.log(`🚨 CIRCUIT BREAKER TRIGGERED for ${asset.name}!`);
    console.log(`   Deviation: ${deviationBps}bps`);
    console.log(`   Threshold: ${asset.maxDivergence}bps`);

    try {
      // Use SDK eth client for transaction execution
      // See @btr/dex-sdk/eth for encodeFn, createPrivateKeyClient
      console.log(`   Action: Would call freezeAsset(${asset.address})`);
      console.log(`   Note: Implement with createPrivateKeyClient and encodeFn from @btr/dex-sdk/eth`);
    } catch (error) {
      console.error(`   ❌ Failed to trigger circuit breaker:`, error);
      throw error;
    }
  }

  private async getAssetData(asset: Address): Promise<any> {
    // Use ethCall and encodeFn from @btr/dex-sdk/eth for contract reads
    // Example: const data = encodeFn({ abi: POOL_ABI, functionName: 'getAsset', args: [asset] });
    //          const result = await ethCall(provider, poolAddress, data);
    console.warn('getAssetData: Implement with ethCall and encodeFn from @btr/dex-sdk/eth');
    return null;
  }

  async checkAllAssets(): Promise<void> {
    const timestamp = new Date().toISOString();
    console.log(`[${timestamp}] Checking ${this.config.assets.length} assets...`);

    for (const asset of this.config.assets) {
      try {
        await this.checkAsset(asset.address);
      } catch (error) {
        console.error(`Error checking asset ${asset.name}:`, error);
      }
    }
  }

  async start(): Promise<void> {
    if (this.isRunning) {
      console.warn('Guardian is already running');
      return;
    }

    this.isRunning = true;
    console.log('Circuit Breaker Guardian started');
    console.log(`Check interval: ${this.config.checkInterval / 1000}s`);
    console.log(`Monitoring pool: ${this.config.poolAddress}`);
    console.log(`Assets: ${this.config.assets.length}\n`);

    // Run immediately
    await this.checkAllAssets();

    // Then run on interval
    while (this.isRunning) {
      await new Promise(resolve => setTimeout(resolve, this.config.checkInterval));
      await this.checkAllAssets();
    }
  }

  stop(): void {
    this.isRunning = false;
    console.log('Guardian stopped');
  }
}

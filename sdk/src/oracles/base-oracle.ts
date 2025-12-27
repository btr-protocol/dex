/**
 * Base Oracle for price feeds
 * @module @btr/dex-sdk/oracles
 */

import type { Address, Eip1193Provider } from '../eth/index.js';
import type { OraclePrice } from '../utils/constants.js';
import { calculateDivergenceBps } from '../utils/business.js';
import { sleep } from '../utils/safe.js';

export interface OracleConfig {
  poolAddress: Address;
  assets: AssetOracleConfig[];
  updateInterval: number; // ms between price checks
  divergenceThreshold: number; // bps - trigger update if price diverges by this much
}

export interface AssetOracleConfig {
  address: Address;
  symbol: string;
  decimals: number;
}

export abstract class BaseOracle {
  protected provider: Eip1193Provider;
  protected config: OracleConfig;
  protected isRunning: boolean = false;
  protected lastPrices: Map<Address, bigint> = new Map();
  protected poolAbi: any;

  constructor(
    provider: Eip1193Provider,
    config: OracleConfig,
    poolAbi: any,
  ) {
    this.provider = provider;
    this.config = config;
    this.poolAbi = poolAbi;
  }

  /**
   * Fetch current price for an asset - to be implemented by subclasses
   */
  protected abstract fetchPrice(asset: AssetOracleConfig): Promise<OraclePrice>;

  /**
   * Check all assets and update prices if divergence threshold is met
   */
  protected async checkAndUpdatePrices(): Promise<void> {
    const timestamp = new Date().toISOString();
    console.log(`[${timestamp}] Checking prices for ${this.config.assets.length} assets...`);

    for (const asset of this.config.assets) {
      try {
        await this.checkAssetPrice(asset);
      } catch (error) {
        console.error(`Error checking price for ${asset.symbol}:`, error);
      }
    }
  }

  /**
   * Check a single asset's price and update if needed
   */
  protected async checkAssetPrice(asset: AssetOracleConfig): Promise<void> {
    // Fetch current market price
    const currentPrice = await this.fetchPrice(asset);

    // Get last on-chain price
    const lastPrice = this.lastPrices.get(asset.address);

    if (!lastPrice) {
      // First time - just store it
      this.lastPrices.set(asset.address, currentPrice.price);
      console.log(`${asset.symbol}: Initial price ${currentPrice.price}`);
      return;
    }

    // Calculate divergence
    const divergenceBps = calculateDivergenceBps(currentPrice.price, lastPrice);

    console.log(
      `${asset.symbol}: price ${currentPrice.price}, divergence ${divergenceBps}bps, threshold ${this.config.divergenceThreshold}bps`
    );

    // Update if divergence exceeds threshold
    if (divergenceBps >= this.config.divergenceThreshold) {
      await this.updateOnChainPrice(asset, currentPrice);
      this.lastPrices.set(asset.address, currentPrice.price);
    }
  }

  /**
   * Update price on-chain
   */
  protected async updateOnChainPrice(
    asset: AssetOracleConfig,
    price: OraclePrice,
  ): Promise<void> {
    console.log(`📡 Updating ${asset.symbol} price on-chain to ${price.price}`);

    try {
      // Note: Full transaction execution requires either:
      // 1. Viem library for contract encoding/simulation
      // 2. Manual ABI encoding for eth_call and eth_sendTransaction
      // For now, log the action that would be taken
      const encodedPrice = price.price / (10n ** BigInt(18 - 8)); // Convert to 1e8
      console.log(`   Action: Would call push(${asset.address}, ${encodedPrice}, 0)`);
      console.log(`   ❌ Transaction sending requires viem or contract encoder`);
    } catch (error) {
      console.error(`   ❌ Failed to update price:`, error);
      throw error;
    }
  }

  /**
   * Start the oracle monitoring loop
   */
  async start(): Promise<void> {
    if (this.isRunning) {
      console.warn('Oracle is already running');
      return;
    }

    this.isRunning = true;
    console.log('Oracle started');
    console.log(`Update interval: ${this.config.updateInterval / 1000}s`);
    console.log(`Divergence threshold: ${this.config.divergenceThreshold}bps`);
    console.log(`Monitoring pool: ${this.config.poolAddress}`);
    console.log(`Assets: ${this.config.assets.length}\n`);

    // Initialize last prices
    for (const asset of this.config.assets) {
      try {
        const price = await this.fetchPrice(asset);
        this.lastPrices.set(asset.address, price.price);
      } catch (error) {
        console.error(`Failed to initialize price for ${asset.symbol}:`, error);
      }
    }

    // Run monitoring loop
    while (this.isRunning) {
      await this.checkAndUpdatePrices();
      await sleep(this.config.updateInterval);
    }
  }

  /**
   * Stop the oracle
   */
  stop(): void {
    this.isRunning = false;
    console.log('Oracle stopped');
  }
}

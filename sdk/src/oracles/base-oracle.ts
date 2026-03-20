/**
 * Base Oracle for price feeds
 * @module @btr/sdk/oracles
 */

import type { Address, Eip1193Provider } from '../eth/index.js';
import type { OraclePrice } from '../utils/constants.js';
import { calculateDivergenceBps } from '../utils/business.js';
import { sleep } from '../utils/safe.js';
import { logger } from '../utils/logger.js';

const log = logger.withContext('oracle');

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
    log.info(`[${timestamp}] Checking prices for ${this.config.assets.length} assets...`);

    for (const asset of this.config.assets) {
      try {
        await this.checkAssetPrice(asset);
      } catch (error) {
        log.error(`Error checking price for ${asset.symbol}`, error);
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
      log.info(`${asset.symbol}: Initial price ${currentPrice.price}`);
      return;
    }

    // Calculate divergence
    const divergenceBps = calculateDivergenceBps(currentPrice.price, lastPrice);

    log.info(
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
    log.info(`Updating ${asset.symbol} price on-chain to ${price.price}`);

    try {
      // Use SDK eth client for transaction execution
      // See @btr/sdk/eth for encodeFn, createPrivateKeyClient
      const encodedPrice = price.price / (10n ** BigInt(18 - 8)); // Convert to 1e8
      log.info(`   Action: Would call push(${asset.address}, ${encodedPrice}, 0)`);
      log.info(`   NB: Implement with createPrivateKeyClient and encodeFn from @btr/sdk/eth`);
    } catch (error) {
      log.error(`   Failed to update price`, error);
      throw error;
    }
  }

  /**
   * Start the oracle monitoring loop
   */
  async start(): Promise<void> {
    if (this.isRunning) {
      log.warn('Oracle is already running');
      return;
    }

    this.isRunning = true;
    log.info('Oracle started');
    log.info(`Update interval: ${this.config.updateInterval / 1000}s`);
    log.info(`Divergence threshold: ${this.config.divergenceThreshold}bps`);
    log.info(`Monitoring pool: ${this.config.poolAddress}`);
    log.info(`Assets: ${this.config.assets.length}\n`);

    // Initialize last prices
    for (const asset of this.config.assets) {
      try {
        const price = await this.fetchPrice(asset);
        this.lastPrices.set(asset.address, price.price);
      } catch (error) {
        log.error(`Failed to initialize price for ${asset.symbol}`, error);
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
    log.info('Oracle stopped');
  }
}

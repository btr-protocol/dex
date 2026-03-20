/**
 * Base Guardian for monitoring AIMM pools
 * @module @btr/sdk/guardians
 */

import type {
  Address,
  Eip1193Provider,
  Hex,
  TransactionReceipt,
} from '../eth/index.js';
import { waitForTransaction as waitForTx } from '../eth/index.js';
import type { GuardianConfig } from '../utils/constants.js';
import { sleep } from '../utils/safe.js';
import { logger } from '../utils/logger.js';

const log = logger.withContext('guardian');

export interface PricePoint {
  timestamp: number;
  price: bigint; // in 1e18 precision
}

export interface OracleProvider {
  getPrice(asset: Address): Promise<bigint>;
  getHistoricalPrices(asset: Address, fromTimestamp: number, toTimestamp: number): Promise<PricePoint[]>;
}

/**
 * Base Guardian class for monitoring AIMM pools
 * Subclasses should implement specific checking logic
 */
export abstract class BaseGuardian {
  protected provider: Eip1193Provider;
  protected config: GuardianConfig;
  protected isRunning: boolean = false;

  constructor(
    provider: Eip1193Provider,
    config: GuardianConfig,
  ) {
    this.provider = provider;
    this.config = config;
  }

  /**
   * Check a single asset - to be implemented by subclasses
   */
  protected abstract checkAsset(asset: Address): Promise<void>;

  /**
   * Check all configured assets
   */
  async checkAllAssets(): Promise<void> {
    const timestamp = new Date().toISOString();
    log.info(`[${timestamp}] Checking ${this.config.assets.length} assets...`);

    for (const asset of this.config.assets) {
      try {
        await this.checkAsset(asset);
      } catch (error) {
        log.error(`Error checking asset ${asset}`, error);
      }
    }
  }

  /**
   * Start the guardian monitoring loop
   */
  async start(): Promise<void> {
    if (this.isRunning) {
      log.warn('Guardian is already running');
      return;
    }

    this.isRunning = true;
    log.info('Guardian started');
    log.info(`Check interval: ${this.config.checkInterval / 1000}s`);
    log.info(`Monitoring pool: ${this.config.poolAddress}`);
    log.info(`Assets: ${this.config.assets.length}\n`);

    // Run immediately
    await this.checkAllAssets();

    // Then run on interval
    while (this.isRunning) {
      await sleep(this.config.checkInterval);
      await this.checkAllAssets();
    }
  }

  /**
   * Stop the guardian
   */
  stop(): void {
    this.isRunning = false;
    log.info('Guardian stopped');
  }

  /**
   * Helper to wait for transaction receipt
   */
  protected async waitForTransaction(hash: Hex): Promise<TransactionReceipt> {
    return (await waitForTx(this.provider, hash)) as TransactionReceipt;
  }
}

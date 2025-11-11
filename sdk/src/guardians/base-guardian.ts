/**
 * Base Guardian for monitoring BAMM pools
 * @module @btr/dex-sdk/guardians
 */

import type {
  Address,
  PublicClient,
  WalletClient,
  Hash,
  TransactionReceipt,
} from 'viem';
import { type GuardianConfig } from '../common/types.js';
import { sleep } from '../common/utils.js';

export interface PricePoint {
  timestamp: number;
  price: bigint; // in 1e18 precision
}

export interface OracleProvider {
  getPrice(asset: Address): Promise<bigint>;
  getHistoricalPrices(asset: Address, fromTimestamp: number, toTimestamp: number): Promise<PricePoint[]>;
}

export abstract class BaseGuardian {
  protected publicClient: PublicClient;
  protected walletClient: WalletClient;
  protected config: GuardianConfig;
  protected isRunning: boolean = false;

  constructor(
    publicClient: PublicClient,
    walletClient: WalletClient,
    config: GuardianConfig,
  ) {
    this.publicClient = publicClient;
    this.walletClient = walletClient;
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
    console.log(`[${timestamp}] Checking ${this.config.assets.length} assets...`);

    for (const asset of this.config.assets) {
      try {
        await this.checkAsset(asset);
      } catch (error) {
        console.error(`Error checking asset ${asset}:`, error);
      }
    }
  }

  /**
   * Start the guardian monitoring loop
   */
  async start(): Promise<void> {
    if (this.isRunning) {
      console.warn('Guardian is already running');
      return;
    }

    this.isRunning = true;
    console.log('Guardian started');
    console.log(`Check interval: ${this.config.checkInterval / 1000}s`);
    console.log(`Monitoring pool: ${this.config.poolAddress}`);
    console.log(`Assets: ${this.config.assets.length}\n`);

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
    console.log('Guardian stopped');
  }

  /**
   * Helper to get asset data from pool
   */
  protected async getAssetData(asset: Address, poolAbi: any): Promise<any> {
    return await this.publicClient.readContract({
      address: this.config.poolAddress,
      abi: poolAbi,
      functionName: 'assets',
      args: [asset],
    });
  }

  /**
   * Helper to send transaction
   */
  protected async sendTransaction(
    to: Address,
    abi: any,
    functionName: string,
    args: any[],
  ): Promise<Hash> {
    const account = this.walletClient.account;
    if (!account) {
      throw new Error('No account configured on wallet client');
    }

    const { request } = await this.publicClient.simulateContract({
      account,
      address: to,
      abi,
      functionName,
      args,
    });

    return await this.walletClient.writeContract(request);
  }

  /**
   * Helper to wait for transaction receipt
   */
  protected async waitForTransaction(hash: Hash): Promise<TransactionReceipt> {
    return await this.publicClient.waitForTransactionReceipt({ hash });
  }
}

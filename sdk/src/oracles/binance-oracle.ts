/**
 * Binance WebSocket Oracle
 * Streams real-time prices from Binance and updates on-chain when divergence thresholds are met
 * Uses Bun's native WebSocket support
 *
 * @module @btr/sdk/oracles
 */

import type { Address, Eip1193Provider } from '../eth/index.js';
import { BaseOracle, type OracleConfig, type AssetOracleConfig } from './base-oracle.js';
import type { OraclePrice } from '../utils/constants.js';
import { PRECISION_1E18 } from '../utils/constants.js';
import { logger } from '../utils/logger.js';

const log = logger.withContext('binanceOracle');

interface BinanceTickerMessage {
  e: string; // Event type
  E: number; // Event time
  s: string; // Symbol
  p: string; // Price change
  P: string; // Price change percent
  w: string; // Weighted average price
  x: string; // First trade before 24hr rolling window
  c: string; // Last price
  Q: string; // Last quantity
  b: string; // Best bid price
  B: string; // Best bid quantity
  a: string; // Best ask price
  A: string; // Best ask quantity
  o: string; // Open price
  h: string; // High price
  l: string; // Low price
  v: string; // Total traded base asset volume
  q: string; // Total traded quote asset volume
  O: number; // Statistics open time
  C: number; // Statistics close time
  F: number; // First trade ID
  L: number; // Last trade ID
  n: number; // Total number of trades
}

export interface BinanceOracleConfig extends OracleConfig {
  wsEndpoint?: string;
  restEndpoint?: string;
}

export class BinanceOracle extends BaseOracle {
  private ws: WebSocket | null = null;
  private wsEndpoint: string;
  private restEndpoint: string;
  private prices: Map<string, bigint> = new Map();
  private symbolToAddress: Map<string, Address> = new Map();

  constructor(
    provider: Eip1193Provider,
    config: BinanceOracleConfig,
    poolAbi: any,
  ) {
    super(provider, config, poolAbi);
    this.wsEndpoint = config.wsEndpoint || 'wss://stream.binance.com:9443/ws';
    this.restEndpoint = config.restEndpoint || 'https://api.binance.com/api/v3';

    // Build symbol to address mapping
    for (const asset of config.assets) {
      this.symbolToAddress.set(asset.symbol.toLowerCase(), asset.address);
    }
  }

  /**
   * Connect to Binance WebSocket and stream prices
   */
  private connectWebSocket(): void {
    // Build stream subscriptions for all assets
    const streams = this.config.assets
      .map(asset => `${asset.symbol.toLowerCase()}usdt@ticker`)
      .join('/');

    const wsUrl = `${this.wsEndpoint}/stream?streams=${streams}`;

    this.ws = new WebSocket(wsUrl);

    this.ws.onopen = () => {
      log.info('Connected to Binance WebSocket');
    };

    this.ws.onmessage = (event: MessageEvent) => {
      try {
        const message = JSON.parse(event.data.toString());
        this.handlePriceUpdate(message);
      } catch (error) {
        log.error('Error parsing WebSocket message', error);
      }
    };

    this.ws.onerror = (error: Event) => {
      log.error('WebSocket error', error);
    };

    this.ws.onclose = () => {
      log.info('WebSocket closed. Reconnecting in 5s...');
      if (this.isRunning) {
        setTimeout(() => this.connectWebSocket(), 5000);
      }
    };
  }

  /**
   * Handle incoming price update from WebSocket
   */
  private handlePriceUpdate(message: any): void {
    if (!message.data) return;

    const data: BinanceTickerMessage = message.data;
    if (data.e !== '24hrTicker') return;

    // Extract symbol (e.g., "ETHUSDT" -> "ETH")
    const baseSymbol = data.s.replace('USDT', '').toLowerCase();
    const address = this.symbolToAddress.get(baseSymbol);

    if (!address) return;

    // Parse price and convert to 1e18 precision
    const price = parseFloat(data.c);
    const priceIn1e18 = BigInt(Math.floor(price * 10 ** 18));

    // Store latest price
    this.prices.set(baseSymbol, priceIn1e18);

    // Check if we should update on-chain (this will be handled by the monitoring loop)
  }

  /**
   * Override fetchPrice to use cached WebSocket price if available
   */
  protected override async fetchPrice(asset: AssetOracleConfig): Promise<OraclePrice> {
    const symbol = asset.symbol.toLowerCase();
    const cachedPrice = this.prices.get(symbol);

    if (cachedPrice) {
      return {
        price: cachedPrice,
        timestamp: Date.now(),
        symbol: asset.symbol,
      };
    }

    // Fallback to REST API
    const symbolUSDT = `${asset.symbol}USDT`;

    try {
      const response = await fetch(`${this.restEndpoint}/ticker/price?symbol=${symbolUSDT}`);
      if (!response.ok) {
        throw new Error(`Binance API error: ${response.statusText}`);
      }

      const data: any = await response.json();
      const price = parseFloat(data.price);

      // Convert to 1e18 precision
      const priceIn1e18 = BigInt(Math.floor(price * 10 ** 18));

      return {
        price: priceIn1e18,
        timestamp: Date.now(),
        symbol: asset.symbol,
      };
    } catch (error) {
      log.error(`Failed to fetch price for ${asset.symbol}`, error);
      throw error;
    }
  }

  /**
   * Start the oracle with WebSocket streaming
   */
  override async start(): Promise<void> {
    // Connect WebSocket for real-time prices
    this.connectWebSocket();

    // Start the base monitoring loop (checks divergence and updates on-chain)
    await super.start();
  }

  /**
   * Stop the oracle and close WebSocket
   */
  override stop(): void {
    super.stop();

    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
  }
}

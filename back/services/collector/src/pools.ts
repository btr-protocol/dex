/**
 * Pool Data API
 * Fetches on-chain pool data using SDK
 */

import { createPublicClient, createHttpProvider, getPoolData, getSwapQuote } from '@sdk';
import type { Address } from '@sdk';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('pools');

// Pool configurations (loaded from deployment.json or env)
interface PoolConfig {
  name: string;
  address: Address;
  tokens: Array<{ address: Address; symbol: string; name: string }>;
}

// BSC mainnet token addresses
const BSC_TOKENS: Record<string, Address> = {
  USDC: '0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d',
  USDT: '0x55d398326f99059fF775485246999027B3197955',
  WETH: '0x2170Ed0880ac9A755fd29B2688956BD959F933F8',
  WBTC: '0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c',
  WBNB: '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c',
  SOL: '0x570A5D26f7765Ecb712C0924E4De545B89fD43dF',
  ZEC: '0x1Ba42e5193dfA8B03D15dd1B86a3113bbBEF8Eeb',
  PAXG: '0x7950865a9140cB519342433146Ed5b40c6F210f7',
  DAI: '0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3',
  TUSD: '0x40af3827F39D0EAcBF4A168f8D4ee67c121D11c9',
  FDUSD: '0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409',
  USDD: '0xd17479997F34dd9156Deef8F95A52D81D265be9c',
  USDP: '0xb3c11196A4f3b1da7c23d9FB0A3dDE9c6340934F',
  crvUSD: '0xe2fb3F127f5450DeE44afe054385d74C392BdeF4',
  lisUSD: '0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5',
  AUSD: '0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a',
  frxUSD: '0x80Eede496655FB9047dd39d9f418d5483ED600df',
};

// Default pool configurations (will be overridden by deployment.json)
const DEFAULT_POOLS: Omit<PoolConfig, 'address'>[] = [
  {
    name: 'Pool Zero',
    tokens: [
      { address: BSC_TOKENS.USDC, symbol: 'USDC', name: 'USD Coin' },
      { address: BSC_TOKENS.USDT, symbol: 'USDT', name: 'Tether USD' },
      { address: BSC_TOKENS.WETH, symbol: 'WETH', name: 'Wrapped Ether' },
      { address: BSC_TOKENS.WBTC, symbol: 'WBTC', name: 'Wrapped Bitcoin' },
      { address: BSC_TOKENS.WBNB, symbol: 'WBNB', name: 'Wrapped BNB' },
      { address: BSC_TOKENS.SOL, symbol: 'SOL', name: 'Solana' },
      { address: BSC_TOKENS.ZEC, symbol: 'ZEC', name: 'Zcash' },
      { address: BSC_TOKENS.PAXG, symbol: 'PAXG', name: 'Paxos Gold' },
    ],
  },
  {
    name: 'Pool Stable',
    tokens: [
      { address: BSC_TOKENS.USDC, symbol: 'USDC', name: 'USD Coin' },
      { address: BSC_TOKENS.USDT, symbol: 'USDT', name: 'Tether USD' },
      { address: BSC_TOKENS.DAI, symbol: 'DAI', name: 'Dai Stablecoin' },
      { address: BSC_TOKENS.USDP, symbol: 'USDP', name: 'Pax Dollar' },
      { address: BSC_TOKENS.lisUSD, symbol: 'lisUSD', name: 'Lista USD' },
      { address: BSC_TOKENS.AUSD, symbol: 'AUSD', name: 'Agora Dollar' },
      { address: BSC_TOKENS.TUSD, symbol: 'TUSD', name: 'TrueUSD' },
      { address: BSC_TOKENS.USDD, symbol: 'USDD', name: 'Decentralized USD' },
      { address: BSC_TOKENS.FDUSD, symbol: 'FDUSD', name: 'First Digital USD' },
      { address: BSC_TOKENS.crvUSD, symbol: 'crvUSD', name: 'Curve USD' },
      { address: BSC_TOKENS.frxUSD, symbol: 'frxUSD', name: 'Frax USD' },
    ],
  },
];

export class PoolDataService {
  private rpcUrl: string;
  private poolConfigs: PoolConfig[] = [];
  private provider: any;
  private lastFetch: number = 0;
  private cacheMs: number = 5000; // 5 second cache
  private cachedData: any = null;

  constructor(rpcUrl: string) {
    this.rpcUrl = rpcUrl;
    this.provider = createHttpProvider(rpcUrl);
  }

  /**
   * Load pool addresses from deployment.json or environment
   */
  async loadPoolAddresses(): Promise<void> {
    // Try to load from deployment.json (for local dev)
    try {
      const deployPath = process.env.DEPLOY_INFO_PATH || '../../front/public/deployment.json';
      const file = Bun.file(deployPath);
      if (await file.exists()) {
        const deployInfo = await file.json();
        this.poolConfigs = [
          { ...DEFAULT_POOLS[0], address: deployInfo.pools.poolZero },
          { ...DEFAULT_POOLS[1], address: deployInfo.pools.poolStable },
        ];
        log.info('[pools] Loaded pool addresses from deployment.json');
        return;
      }
    } catch (e) {
      // Ignore
    }

    // Fall back to environment variables
    const poolZero = process.env.POOL_ZERO_ADDRESS as Address | undefined;
    const poolStable = process.env.POOL_STABLE_ADDRESS as Address | undefined;

    if (poolZero && poolStable) {
      this.poolConfigs = [
        { ...DEFAULT_POOLS[0], address: poolZero },
        { ...DEFAULT_POOLS[1], address: poolStable },
      ];
      log.info('[pools] Loaded pool addresses from environment');
    } else {
      log.warn('[pools] No pool addresses configured - API will return empty data');
    }
  }

  /**
   * Fetch all pool data
   */
  async fetchPools(): Promise<any[]> {
    // Return cached data if fresh
    const now = Date.now();
    if (this.cachedData && now - this.lastFetch < this.cacheMs) {
      return this.cachedData;
    }

    if (this.poolConfigs.length === 0) {
      return [];
    }

    const pools = await Promise.all(
      this.poolConfigs.map(async (config) => {
        try {
          const poolData = await getPoolData(this.provider, config.address, config.tokens, config.name);

          // Transform to API format
          return {
            name: poolData.name,
            address: poolData.address,
            assets: poolData.assets.map((asset) => ({
              token: asset.token,
              symbol: asset.symbol,
              name: asset.name,
              decimals: asset.decimals,
              reserves: asset.reserves.toString(),
              liabilities: asset.liabilities.toString(),
              coverage: asset.coverage.toString(),
            })),
          };
        } catch (error) {
          log.error(`[pools] Failed to fetch ${config.name}:`, error);
          return null;
        }
      })
    );

    this.cachedData = pools.filter(Boolean);
    this.lastFetch = now;
    return this.cachedData;
  }

  /**
   * Get swap quote
   */
  async getQuote(poolAddress: Address, tokenIn: Address, tokenOut: Address, amountIn: string): Promise<any> {
    try {
      const quote = await getSwapQuote(this.provider, poolAddress, tokenIn, tokenOut, BigInt(amountIn));

      return {
        amountOut: quote.amountOut.toString(),
        amountIn: quote.amountIn.toString(),
        spreadBps: quote.spreadBps,
        protoFee: quote.protoFee.toString(),
        lpFee: quote.lpFee.toString(),
        skewIn: quote.skewIn,
        skewOut: quote.skewOut,
        routeHops: quote.routeHops,
        hopAmounts: quote.hopAmounts.map((a) => a.toString()),
      };
    } catch (error) {
      throw new Error(`Failed to get quote: ${error instanceof Error ? error.message : 'Unknown error'}`);
    }
  }
}

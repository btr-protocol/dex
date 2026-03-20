import { useState, useEffect } from 'preact/hooks';
import { useWallet } from '@lib/wallet';
import { POOL_V1_ABI, type AssetData } from '@/contracts/PoolV1.abi';
import type { Address, Hex } from '@sdk/eth';
import { encodeFn, decodeFn, getContractAddress } from '@sdk/eth';
import { logger } from '@sdk/utils';

const log = logger.withContext('poolContracts');

// Pool configurations - addresses will be loaded from localStorage after deployment
export interface PoolConfig {
  name: string;
  address: Address;
  tokens: TokenConfig[];
}

export interface TokenConfig {
  symbol: string;
  name: string;
  address: Address;
  feedSymbol?: string; // External price feed symbol (e.g., 'ETHUSDC')
}

// BSC Fork token addresses (from DeployBSCFork.s.sol)
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

// Anvil mock token addresses (from salts/bbbb_bb.txt)
const ANVIL_TOKENS: Record<string, Address> = {
  mUSDC: '0xbbbb4a42775f9d01fb2870e702c7ed47ed5b04bb',
  mUSDT: '0xbbbb12e5f2e8682a731202645cf3f863e9a5e2bb',
  mWETH: '0xbbbb9d6e02822bfe346b42985f54903d16419cbb',
  mWBTC: '0xbbbb8b9e7794532c28a72cc1513fd7f76257b0bb',
  mWBNB: '0xbbbb90f51f61bf8b1f96f2528daebdfc321f91bb',
  mSOL: '0xbbbb1fb625a6fa6f8a03e1b1c6d26a41177bf7bb',
  mZEC: '0xbbbb9094f5bf727a6144b354029abafb8c384fbb',
  mPAXG: '0xbbbb91b967c1efe11f0be13b8b191bc6e71ac5bb',
  mDAI: '0xbbbbe41729d9ad375c979fe8562e05f8036b88bb',
  mTUSD: '0xbbbb4cd51926fd22943de93f5f2768e01a8da0bb',
  mFDUSD: '0xbbbb74a69995f2fe9b7f4ea221f6f790646ca5bb',
  mUSDD: '0xbbbb9a634fdb18b322a898b871e3332c6668c3bb',
  mUSDP: '0xbbbbe1658df7d5cf39ef7d538f111eadf69fe2bb',
  mcrvUSD: '0xbbbbbb9e631883d249240201322470fb55ff27bb',
  mlisUSD: '0xbbbb4a42775f9d01fb2870e702c7ed47ed5b04bb', // Reuse mUSDC salt
  mAUSD: '0xbbbb12e5f2e8682a731202645cf3f863e9a5e2bb', // Reuse mUSDT salt
  mfrxUSD: '0xbbbb9d6e02822bfe346b42985f54903d16419cbb', // Reuse mWETH salt
};

// Default pool configurations
const DEFAULT_POOLS: Omit<PoolConfig, 'address'>[] = [
  {
    name: 'Pool Zero',
    tokens: [
      { symbol: 'USDC', name: 'USD Coin', address: '' as Address, feedSymbol: 'ETHUSDC' },
      { symbol: 'USDT', name: 'Tether USD', address: '' as Address, feedSymbol: 'ETHUSDT' },
      { symbol: 'WETH', name: 'Wrapped Ether', address: '' as Address, feedSymbol: 'ETHUSDC' },
      { symbol: 'WBTC', name: 'Wrapped Bitcoin', address: '' as Address, feedSymbol: 'BTCUSDC' },
      { symbol: 'WBNB', name: 'Wrapped BNB', address: '' as Address, feedSymbol: 'BNBUSDC' },
      { symbol: 'SOL', name: 'Solana', address: '' as Address, feedSymbol: 'SOLUSDC' },
      { symbol: 'ZEC', name: 'Zcash', address: '' as Address, feedSymbol: 'ZECUSDC' },
      { symbol: 'PAXG', name: 'Paxos Gold', address: '' as Address, feedSymbol: 'XAUUSDC' },
    ],
  },
  {
    name: 'Pool Stable',
    tokens: [
      { symbol: 'USDC', name: 'USD Coin', address: '' as Address, feedSymbol: 'ETHUSDC' },
      { symbol: 'USDT', name: 'Tether USD', address: '' as Address, feedSymbol: 'ETHUSDT' },
      { symbol: 'DAI', name: 'Dai Stablecoin', address: '' as Address, feedSymbol: 'ETHUSDT' },
      { symbol: 'USDP', name: 'Pax Dollar', address: '' as Address, feedSymbol: 'ETHUSDT' },
      { symbol: 'lisUSD', name: 'Lista USD', address: '' as Address, feedSymbol: 'ETHUSDT' },
      { symbol: 'AUSD', name: 'Agora Dollar', address: '' as Address, feedSymbol: 'ETHUSDT' },
      { symbol: 'TUSD', name: 'TrueUSD', address: '' as Address, feedSymbol: 'ETHUSDT' },
      { symbol: 'USDD', name: 'Decentralized USD', address: '' as Address, feedSymbol: 'ETHUSDT' },
      { symbol: 'FDUSD', name: 'First Digital USD', address: '' as Address, feedSymbol: 'ETHUSDT' },
      { symbol: 'crvUSD', name: 'Curve USD', address: '' as Address, feedSymbol: 'ETHUSDT' },
      { symbol: 'frxUSD', name: 'Frax USD', address: '' as Address, feedSymbol: 'ETHUSDT' },
    ],
  },
];

// Get asset price (mock for now, will be replaced with live feeds)
function getAssetPrice(symbol: string): number {
  // Stablecoins
  const stables = ['USDC', 'USDT', 'DAI', 'TUSD', 'FDUSD', 'USDD', 'USDP', 'crvUSD', 'lisUSD', 'AUSD', 'frxUSD'];
  if (stables.includes(symbol)) return 1.0;

  // Mock prices for other assets (will be replaced with live feeds)
  const mockPrices: Record<string, number> = {
    WETH: 3500,
    WBTC: 95000,
    WBNB: 650,
    SOL: 200,
    ZEC: 45,
    PAXG: 2700,
  };

  return mockPrices[symbol] ?? 1.0;
}

export interface PoolAssetData {
  token: TokenConfig;
  reserves: bigint;
  liabilities: bigint;
  coverage: bigint;
  decimals: number;
  price: number; // USD price (from external feed or fallback to $1 for stables)
}

export interface PoolContractData {
  name: string;
  address: Address;
  assets: PoolAssetData[];
  loading: boolean;
  error: string | null;
}

/**
 * Fetch pool data from contract
 */
export function usePoolContracts(): PoolContractData[] {
  const { provider, chainId } = useWallet();
  const [pools, setPools] = useState<PoolContractData[]>([]);

  useEffect(() => {
    if (!provider || !chainId) {
      setPools([]);
      return;
    }

    const poolZeroAddr = getContractAddress(chainId, 'POOL_ZERO');
    const poolStableAddr = getContractAddress(chainId, 'POOL_STABLE');

    if (!poolZeroAddr || !poolStableAddr) {
      log.warn('Pool addresses not found for chain', { chainId });
      setPools([]);
      return;
    }

    // Determine which token addresses to use based on chain
    const useMockTokens = chainId === 31337;
    const tokenMap = useMockTokens ? ANVIL_TOKENS : BSC_TOKENS;

    const poolConfigs: PoolConfig[] = [
      {
        ...DEFAULT_POOLS[0],
        address: poolZeroAddr,
        tokens: DEFAULT_POOLS[0].tokens.map(t => ({
          ...t,
          address: tokenMap[t.symbol] || ('' as Address),
        })),
      },
      {
        ...DEFAULT_POOLS[1],
        address: poolStableAddr,
        tokens: DEFAULT_POOLS[1].tokens.map(t => ({
          ...t,
          address: tokenMap[t.symbol] || ('' as Address),
        })),
      },
    ];

    fetchPoolDataInner(poolConfigs, provider, setPools);
  }, [provider, chainId]);

  return pools;
}

// Fetch pool data from contracts
async function fetchPoolDataInner(
  poolConfigs: PoolConfig[],
  provider: any,
  setPools: (pools: PoolContractData[]) => void
) {
  const results: PoolContractData[] = [];

      for (const config of poolConfigs) {
        const poolData: PoolContractData = {
          name: config.name,
          address: config.address,
          assets: [],
          loading: true,
          error: null,
        };

        try {
          // Fetch asset data for each token
          for (const token of config.tokens) {
            const assetCalldata = encodeFn({ abi: POOL_V1_ABI, functionName: 'getAsset', args: [token.address] });
            const coverageCalldata = encodeFn({ abi: POOL_V1_ABI, functionName: 'getCoverageRatio', args: [token.address] });

            const [assetResult, coverageResult] = await Promise.all([
              provider.request({
                method: 'eth_call',
                params: [{ to: config.address, data: assetCalldata }, 'latest'],
              }) as Promise<Hex>,
              provider.request({
                method: 'eth_call',
                params: [{ to: config.address, data: coverageCalldata }, 'latest'],
              }) as Promise<Hex>,
            ]);

            const asset = decodeFn({ abi: POOL_V1_ABI, functionName: 'getAsset', data: assetResult });
            const coverage = decodeFn({ abi: POOL_V1_ABI, functionName: 'getCoverageRatio', data: coverageResult }) as bigint;

            // Get price: stablecoins = $1, others use mock for now
            const price = getAssetPrice(token.symbol);

            poolData.assets.push({
              token,
                reserves: asset.reserves,
                liabilities: asset.liabilities,
                coverage,
                decimals: asset.decimals,
                price,
              });
          }

          poolData.loading = false;
        } catch (error) {
          log.error(`Failed to fetch pool data for ${config.name}`, error);
          poolData.error = error instanceof Error ? error.message : 'Unknown error';
          poolData.loading = false;
        }

    results.push(poolData);
  }

  setPools(results);
}

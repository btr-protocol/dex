import { createHttpProvider, getPoolData } from '@sdk';
import type { Address } from '@sdk';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('testPoolData');

const BSC_TOKENS: Record<string, Address> = {
  USDC: '0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d',
  USDT: '0x55d398326f99059fF775485246999027B3197955',
  WETH: '0x2170Ed0880ac9A755fd29B2688956BD959F933F8',
  WBTC: '0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c',
  WBNB: '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c',
  SOL: '0x570A5D26f7765Ecb712C0924E4De545B89fD43dF',
  ZEC: '0x1Ba42e5193dfA8B03D15dd1B86a3113bbBEF8Eeb',
  PAXG: '0x7950865a9140cB519342433146Ed5b40c6F210f7',
};

const poolZeroTokens = [
  { address: BSC_TOKENS.USDC, symbol: 'USDC', name: 'USD Coin' },
  { address: BSC_TOKENS.USDT, symbol: 'USDT', name: 'Tether USD' },
  { address: BSC_TOKENS.WETH, symbol: 'WETH', name: 'Wrapped Ether' },
  { address: BSC_TOKENS.WBTC, symbol: 'WBTC', name: 'Wrapped Bitcoin' },
  { address: BSC_TOKENS.WBNB, symbol: 'WBNB', name: 'Wrapped BNB' },
  { address: BSC_TOKENS.SOL, symbol: 'SOL', name: 'Solana' },
  { address: BSC_TOKENS.ZEC, symbol: 'ZEC', name: 'Zcash' },
  { address: BSC_TOKENS.PAXG, symbol: 'PAXG', name: 'Paxos Gold' },
];

const provider = createHttpProvider('http://localhost:8545');
const poolZeroAddress: Address = '0x56C2b5a6EeBa48CcA63493c42719E35727bdB602';

log.info('Testing getPoolData with Pool Zero tokens...');

try {
  const poolData = await getPoolData(provider, poolZeroAddress, poolZeroTokens, 'Pool Zero');
  log.info('Success! Got pool data:', {
    name: poolData.name,
    address: poolData.address,
    assetCount: poolData.assets.length,
  });

  // Test serialization like the backend does
  const serialized = poolData.assets.map((asset) => ({
    token: asset.token,
    symbol: asset.symbol,
    name: asset.name,
    decimals: asset.decimals,
    reserves: asset.reserves.toString(),
    liabilities: asset.liabilities.toString(),
    coverage: asset.coverage.toString(),
  }));

  log.info('Serialized assets:', serialized);
} catch (error) {
  log.error('Error:', error);
  if (error instanceof Error) {
    log.error('Stack:', error.stack);
  }
}

#!/usr/bin/env bun
import { createHttpProvider, getPoolData } from './sdk/src/index';
import { logger } from './sdk/src/utils/logger';

const log = logger.withContext('testPoolSdk');

const rpcUrl = 'http://localhost:8545';
const poolAddress = '0x0785c785D04D6aBa7e15204d4E72817299cDC71e'; // Pool Stable

const tokens = [
  { address: '0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d', symbol: 'USDC', name: 'USD Coin' },
  { address: '0x55d398326f99059fF775485246999027B3197955', symbol: 'USDT', name: 'Tether USD' },
];

const provider = createHttpProvider(rpcUrl);

log.info('Testing SDK pool data fetch...');
log.info(`RPC: ${rpcUrl}`);
log.info(`Pool: ${poolAddress}`);

try {
  const poolData = await getPoolData(provider, poolAddress as any, tokens as any, 'Pool Stable');
  log.info('✓ Pool data fetched successfully!');
  log.info(`Assets: ${poolData.assets.length}`);
  poolData.assets.forEach((asset, i) => {
    log.info(`  ${i + 1}. ${asset.symbol}: reserves=${asset.reserves}, liabilities=${asset.liabilities}`);
  });
} catch (error) {
  log.error('✗ Error fetching pool data', error);
  process.exit(1);
}

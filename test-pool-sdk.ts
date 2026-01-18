#!/usr/bin/env bun
import { createHttpProvider, getPoolData } from './sdk/src/index';

const rpcUrl = 'http://localhost:8545';
const poolAddress = '0x0785c785D04D6aBa7e15204d4E72817299cDC71e'; // Pool Stable

const tokens = [
  { address: '0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d', symbol: 'USDC', name: 'USD Coin' },
  { address: '0x55d398326f99059fF775485246999027B3197955', symbol: 'USDT', name: 'Tether USD' },
];

const provider = createHttpProvider(rpcUrl);

console.log('Testing SDK pool data fetch...');
console.log('RPC:', rpcUrl);
console.log('Pool:', poolAddress);

try {
  const poolData = await getPoolData(provider, poolAddress as any, tokens as any, 'Pool Stable');
  console.log('\n✓ Pool data fetched successfully!');
  console.log('Assets:', poolData.assets.length);
  poolData.assets.forEach((asset, i) => {
    console.log(`  ${i + 1}. ${asset.symbol}: reserves=${asset.reserves}, liabilities=${asset.liabilities}`);
  });
} catch (error) {
  console.error('\n✗ Error fetching pool data:');
  console.error(error);
  process.exit(1);
}

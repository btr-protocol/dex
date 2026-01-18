// Test using the same import path as pools.ts
import { createHttpProvider, getAsset } from '@sdk';
import type { Address } from '@sdk';

const provider = createHttpProvider('http://localhost:8545');
const poolAddress: Address = '0x56C2b5a6EeBa48CcA63493c42719E35727bdB602';
const usdcAddress: Address = '0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d';

console.log('Testing with @sdk alias from backend...');

try {
  const asset = await getAsset(provider, poolAddress, usdcAddress);
  console.log('Asset result:', asset);
  console.log('Has reserves property?', 'reserves' in asset);
  console.log('Reserves value:', asset.reserves);
  console.log('Reserves type:', typeof asset.reserves);
  console.log('toString() works?', asset.reserves.toString());
} catch (error) {
  console.error('Error:', error);
}

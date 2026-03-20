// Test using the same import path as pools.ts
import { createHttpProvider, getAsset } from '@sdk';
import type { Address } from '@sdk';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('testSdkImport');

const provider = createHttpProvider('http://localhost:8545');
const poolAddress: Address = '0x56C2b5a6EeBa48CcA63493c42719E35727bdB602';
const usdcAddress: Address = '0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d';

log.info('Testing with @sdk alias from backend...');

try {
  const asset = await getAsset(provider, poolAddress, usdcAddress);
  log.info('Asset result:', asset);
  log.info('Has reserves property?', 'reserves' in asset);
  log.info('Reserves value:', asset.reserves);
  log.info('Reserves type:', typeof asset.reserves);
  log.info('toString() works?', asset.reserves.toString());
} catch (error) {
  log.error('Error', error);
}

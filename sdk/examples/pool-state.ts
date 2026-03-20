/**
 * Pool State Aggregation Example
 *
 * Demonstrates how to efficiently fetch and compute pool metrics using multicall:
 * - Per-asset coverage ratios
 * - Pool-wide weighted average coverage
 * - Total reserves and liabilities in accounting base
 */

import { Contract, Provider } from 'ethers';
import { logger } from '../src/utils/logger.js';

const log = logger.withContext('poolState');

// AIMM ABI fragment (only what we need)
const AIMM_ABI = [
  'function registeredAssets() view returns (address[])',
  'function getOracleData(address token) view returns (uint64 fastTWAP, uint64 slowTWAP, uint32 fastVolatility, uint32 slowVolatility, uint32 lastUpdate)',
  'function getAssetState(address token) view returns (uint64 fastTWAP, uint64 slowTWAP, uint128 reserves, uint128 liabilities, uint256 reservesValue, uint256 liabilitiesValue)',
];

interface AssetState {
  token: string;
  fastTWAP: bigint;
  slowTWAP: bigint;
  reserves: bigint;
  liabilities: bigint;
  reservesValue: bigint;
  liabilitiesValue: bigint;
  coverageRatio: bigint;  // Computed: (reserves / liabilities) * 1e18
}

interface PoolState {
  assets: AssetState[];
  totalReservesValue: bigint;
  totalLiabilitiesValue: bigint;
  overallCoverageRatio: bigint;  // Weighted average
}

/**
 * Fetch pool state using a single multicall
 */
async function getPoolState(
  aimmAddress: string,
  provider: Provider
): Promise<PoolState> {
  const aimm = new Contract(aimmAddress, AIMM_ABI, provider);

  // Step 1: Get list of all pool assets
  const tokens: string[] = await aimm.registeredAssets();

  // Step 2: Batch fetch all asset states (single RPC call with multicall)
  const assetStates = await Promise.all(
    tokens.map(token => aimm.getAssetState(token))
  );

  // Step 3: Compute metrics
  const assets: AssetState[] = [];
  let totalReservesValue = 0n;
  let totalLiabilitiesValue = 0n;

  for (let i = 0; i < tokens.length; i++) {
    const [fastTWAP, slowTWAP, reserves, liabilities, reservesValue, liabilitiesValue] = assetStates[i];

    // Compute coverage ratio: C = (reserves / liabilities) * 1e18
    // NB: 1e18 = 100%, 5e17 = 50%, 15e17 = 150%
    const coverageRatio = liabilities > 0n
      ? (reserves * 10n**18n) / liabilities
      : (reserves > 0n ? 2n**256n - 1n : 10n**18n);  // Infinite if reserves but no liabilities

    assets.push({
      token: tokens[i],
      fastTWAP,
      slowTWAP,
      reserves,
      liabilities,
      reservesValue,
      liabilitiesValue,
      coverageRatio,
    });

    // Accumulate pool-wide totals
    totalReservesValue += reservesValue;
    totalLiabilitiesValue += liabilitiesValue;
  }

  // Compute weighted average coverage ratio
  // Overall C = (total reserves value / total liabilities value) * 1e18
  const overallCoverageRatio = totalLiabilitiesValue > 0n
    ? (totalReservesValue * 10n**18n) / totalLiabilitiesValue
    : (totalReservesValue > 0n ? 2n**256n - 1n : 10n**18n);

  return {
    assets,
    totalReservesValue,
    totalLiabilitiesValue,
    overallCoverageRatio,
  };
}

/**
 * Decode b64 TWAP to human-readable price
 * Formula: price_dollars = (twap_b64 * 1e18) >> 64
 */
function decodeTWAP(twap: bigint): string {
  const price = (twap * 10n**18n) >> 64n;
  return (Number(price) / 1e18).toFixed(6);
}

/**
 * Format coverage ratio as percentage
 */
function formatCoverage(coverage: bigint): string {
  if (coverage === 2n**256n - 1n) return '∞';
  return `${(Number(coverage) / 1e16).toFixed(2)}%`;  // 1e18 = 100%
}

/**
 * Format value in accounting base
 */
function formatValue(value: bigint): string {
  return `$${(Number(value) / 1e18).toFixed(2)}`;
}

/**
 * Example usage
 */
async function main() {
  const provider = new Provider('https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY');
  const aimmAddress = '0x...';  // Your AIMM address

  // Fetch entire pool state in ONE multicall
  const state = await getPoolState(aimmAddress, provider);

  log.info('=== POOL STATE ===\n');
  log.info(`Total Reserves Value:    ${formatValue(state.totalReservesValue)}`);
  log.info(`Total Liabilities Value: ${formatValue(state.totalLiabilitiesValue)}`);
  log.info(`Overall Coverage Ratio:  ${formatCoverage(state.overallCoverageRatio)}\n`);

  log.info('=== PER-ASSET STATE ===\n');
  for (const asset of state.assets) {
    log.info(`Token: ${asset.token}`);
    log.info(`  Fast TWAP:         $${decodeTWAP(asset.fastTWAP)}`);
    log.info(`  Slow TWAP:         $${decodeTWAP(asset.slowTWAP)}`);
    log.info(`  Reserves:          ${asset.reserves.toString()}`);
    log.info(`  Liabilities:       ${asset.liabilities.toString()}`);
    log.info(`  Reserves Value:    ${formatValue(asset.reservesValue)}`);
    log.info(`  Liabilities Value: ${formatValue(asset.liabilitiesValue)}`);
    log.info(`  Coverage Ratio:    ${formatCoverage(asset.coverageRatio)}`);
    log.info('');
  }
}

// Example health check function
function isPoolHealthy(state: PoolState, minCoverage: bigint = 9n * 10n**17n): boolean {
  // Check if overall coverage is above 90% (0.9 * 1e18)
  if (state.overallCoverageRatio < minCoverage) {
    log.warn(`⚠️  Pool coverage ${formatCoverage(state.overallCoverageRatio)} below minimum ${formatCoverage(minCoverage)}`);
    return false;
  }

  // Check individual assets
  for (const asset of state.assets) {
    if (asset.coverageRatio < minCoverage && asset.coverageRatio !== 2n**256n - 1n) {
      log.warn(`⚠️  Asset ${asset.token} coverage ${formatCoverage(asset.coverageRatio)} below minimum`);
      return false;
    }
  }

  return true;
}

/**
 * Example: External contract reading AIMM oracles
 *
 * Any external contract can read real-time oracle data from AIMM pools
 */
async function getOracleDataExample(
  aimmAddress: string,
  tokenAddress: string,
  provider: Provider
): Promise<void> {
  const aimm = new Contract(aimmAddress, AIMM_ABI, provider);

  // Single call to get all oracle data (works for both internal and external oracles)
  const [fastTWAP, slowTWAP, fastVolatility, slowVolatility, lastUpdate] =
    await aimm.getOracleData(tokenAddress);

  log.info('=== ORACLE DATA ===');
  log.info(`Fast TWAP:        $${decodeTWAP(fastTWAP)}`);
  log.info(`Slow TWAP:        $${decodeTWAP(slowTWAP)}`);
  log.info(`Fast Volatility:  ${(Number(fastVolatility) / 1e6).toFixed(2)}%`);
  log.info(`Slow Volatility:  ${(Number(slowVolatility) / 1e6).toFixed(2)}%`);
  log.info(`Last Update:      ${new Date(Number(lastUpdate) * 1000).toISOString()}`);
}

export {
  getPoolState,
  decodeTWAP,
  formatCoverage,
  formatValue,
  isPoolHealthy,
  getOracleDataExample
};

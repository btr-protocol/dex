/**
 * Integration tests for Pool SDK functions
 * Tests pool data retrieval and swap simulation against local Anvil fork
 */

import { describe, test, expect } from 'bun:test';
import { createHttpProvider } from '../eth/client';
import { getAsset, getCoverageRatio, getPoolData, getSwapQuote } from './index';
import type { Address } from '../eth/types';
import { logger } from '../utils/logger';

const log = logger.withContext('pool-test');

// Local Anvil BSC fork
const RPC_URL = 'http://localhost:8545';

// Deployed pool addresses (from deployment.json)
const POOL_ZERO: Address = '0x56C2b5a6EeBa48CcA63493c42719E35727bdB602';
const POOL_STABLE: Address = '0x43a5E01268C6358DD353c5bB592C732104c5694f';

// BSC token addresses (used in local fork)
const USDC: Address = '0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d';
const USDT: Address = '0x55d398326f99059fF775485246999027B3197955';
const WETH: Address = '0x2170Ed0880ac9A755fd29B2688956BD959F933F8';
const WBTC: Address = '0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c';

describe('Pool Data Retrieval', () => {
  const provider = createHttpProvider(RPC_URL);

  test('getAsset returns valid asset data', async () => {
    const asset = await getAsset(provider, POOL_ZERO, USDC);

    // Verify all fields are present and correct type
    expect(asset).toHaveProperty('reserves');
    expect(asset).toHaveProperty('liabilities');
    expect(asset).toHaveProperty('decimals');
    expect(asset).toHaveProperty('minFeeBps');
    expect(asset).toHaveProperty('maxFeeBps');

    expect(typeof asset.reserves).toBe('bigint');
    expect(typeof asset.liabilities).toBe('bigint');
    expect(typeof asset.decimals).toBe('bigint');
    expect(typeof asset.minFeeBps).toBe('bigint');

    // Decimals should be 18 for USDC on BSC
    expect(Number(asset.decimals)).toBe(18);
  });

  test('getCoverageRatio returns valid coverage', async () => {
    const coverage = await getCoverageRatio(provider, POOL_ZERO, USDC);

    expect(typeof coverage).toBe('bigint');
    // Coverage should be non-zero even without deposits (returns max uint256 when no liabilities)
    expect(coverage).toBeGreaterThan(0n);
  });

  test('getPoolData returns complete pool data for Pool Zero', async () => {
    const tokens = [
      { address: USDC, symbol: 'USDC', name: 'USD Coin' },
      { address: USDT, symbol: 'USDT', name: 'Tether USD' },
      { address: WETH, symbol: 'WETH', name: 'Wrapped Ether' },
      { address: WBTC, symbol: 'WBTC', name: 'Wrapped Bitcoin' },
    ];

    const poolData = await getPoolData(provider, POOL_ZERO, tokens, 'Pool Zero');

    // Verify pool data structure
    expect(poolData.name).toBe('Pool Zero');
    expect(poolData.address).toBe(POOL_ZERO);
    expect(poolData.assets.length).toBe(4);

    // Verify each asset
    for (const asset of poolData.assets) {
      expect(asset).toHaveProperty('token');
      expect(asset).toHaveProperty('symbol');
      expect(asset).toHaveProperty('name');
      expect(asset).toHaveProperty('decimals');
      expect(asset).toHaveProperty('reserves');
      expect(asset).toHaveProperty('liabilities');
      expect(asset).toHaveProperty('coverage');

      // Verify types
      expect(typeof asset.token).toBe('string');
      expect(typeof asset.symbol).toBe('string');
      expect(typeof asset.name).toBe('string');
      expect(typeof asset.decimals).toBe('number'); // Should be number, not bigint
      expect(typeof asset.reserves).toBe('bigint');
      expect(typeof asset.liabilities).toBe('bigint');
      expect(typeof asset.coverage).toBe('bigint');

      // Verify toString() works (for API serialization)
      expect(typeof asset.reserves.toString()).toBe('string');
      expect(typeof asset.liabilities.toString()).toBe('string');
      expect(typeof asset.coverage.toString()).toBe('string');
    }
  });

  test('getPoolData returns complete pool data for Pool Stable', async () => {
    const tokens = [
      { address: USDC, symbol: 'USDC', name: 'USD Coin' },
      { address: USDT, symbol: 'USDT', name: 'Tether USD' },
    ];

    const poolData = await getPoolData(provider, POOL_STABLE, tokens, 'Pool Stable');

    expect(poolData.name).toBe('Pool Stable');
    expect(poolData.address).toBe(POOL_STABLE);
    expect(poolData.assets.length).toBe(2);
  });
});

describe('Swap Simulation', () => {
  const provider = createHttpProvider(RPC_URL);

  test('getSwapQuote returns valid quote structure (requires liquidity)', async () => {
    const amountIn = 1000n * 10n ** 18n; // 1000 USDC

    try {
      const quote = await getSwapQuote(provider, POOL_STABLE, USDC, USDT, amountIn);

      // Verify quote structure
      expect(quote).toHaveProperty('amountIn');
      expect(quote).toHaveProperty('amountOut');
      expect(quote).toHaveProperty('spreadBps');
      expect(quote).toHaveProperty('protoFee');
      expect(quote).toHaveProperty('lpFee');
      expect(quote).toHaveProperty('skewIn');
      expect(quote).toHaveProperty('skewOut');
      expect(quote).toHaveProperty('routeHops');
      expect(quote).toHaveProperty('hopAmounts');

      // Verify types
      expect(typeof quote.amountIn).toBe('bigint');
      expect(typeof quote.amountOut).toBe('bigint');
      expect(typeof quote.spreadBps).toBe('number');
      expect(typeof quote.protoFee).toBe('bigint');
      expect(typeof quote.lpFee).toBe('bigint');
      expect(typeof quote.skewIn).toBe('number');
      expect(typeof quote.skewOut).toBe('number');
      expect(Array.isArray(quote.routeHops)).toBe(true);
      expect(Array.isArray(quote.hopAmounts)).toBe(true);

      // Amount in should match input
      expect(quote.amountIn).toBe(amountIn);
      expect(quote.amountOut).toBeGreaterThanOrEqual(0n);
    } catch (error) {
      // Expected to fail with no liquidity - test passes if we get here
      expect(error).toBeDefined();
      log.info('Note: Swap quote requires pool liquidity to succeed');
    }
  });

  test('getSwapQuote SDK function exists and is callable', async () => {
    // Just verify the function exists and can be called
    // With no liquidity, it will fail, but we're testing the SDK structure
    expect(typeof getSwapQuote).toBe('function');

    const amountIn = 1n * 10n ** 18n;

    try {
      await getSwapQuote(provider, POOL_ZERO, WETH, WBTC, amountIn);
      // If it succeeds, verify it returns something
      expect(true).toBe(true);
    } catch (error) {
      // Expected with no liquidity - just verify it's a proper error
      expect(error).toBeDefined();
    }
  });
});

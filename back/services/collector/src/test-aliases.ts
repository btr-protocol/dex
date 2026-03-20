#!/usr/bin/env bun

/**
 * Test token alias resolution
 */

import { resolveAlias, TOKEN_ALIASES } from './config';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('testAliases');

log.info('Token Alias Resolution Tests\n');
log.info('Configured aliases:', TOKEN_ALIASES);
log.info('\n--- Test Cases ---\n');

const testCases = [
  // Wrapped ETH
  { input: 'WETHUSDC', expected: 'ETHUSDT' },
  { input: 'WETHUSDT', expected: 'ETHUSDT' },
  { input: 'UETHUSDT', expected: 'ETHUSDT' },
  { input: 'agg:spot:WETHUSDC', expected: 'agg:spot:ETHUSDT' },

  // Wrapped BTC
  { input: 'WBTCUSDT', expected: 'BTCUSDT' },
  { input: 'WBTCUSDC', expected: 'BTCUSDT' },
  { input: 'CBBTCUSDT', expected: 'BTCUSDT' },
  { input: 'TBTCUSDT', expected: 'BTCUSDT' },
  { input: 'UBTCUSDT', expected: 'BTCUSDT' },
  { input: 'BTCBUSDT', expected: 'BTCUSDT' },
  { input: 'agg:spot:WBTCUSDC', expected: 'agg:spot:BTCUSDT' },

  // Non-aliased tokens (should pass through)
  { input: 'ETHUSDT', expected: 'ETHUSDT' },
  { input: 'BTCUSDT', expected: 'BTCUSDT' },
  { input: 'SOLUSDT', expected: 'SOLUSDT' },
  { input: 'agg:spot:ETHUSDT', expected: 'agg:spot:ETHUSDT' },

  // USDC -> USDT normalization
  { input: 'ETHUSDC', expected: 'ETHUSDT' },
  { input: 'BTCUSDC', expected: 'BTCUSDT' },

  // Slash format
  { input: 'WETH/USDC', expected: 'ETHUSDC' },
  { input: 'WBTC/USDT', expected: 'BTCUSDT' },
];

let passed = 0;
let failed = 0;

for (const { input, expected } of testCases) {
  const result = resolveAlias(input);
  const success = result === expected;

  if (success) {
    log.info(`✓ ${input.padEnd(25)} → ${result}`);
    passed++;
  } else {
    log.info(`✗ ${input.padEnd(25)} → ${result} (expected: ${expected})`);
    failed++;
  }
}

log.info(`\n--- Results ---`);
log.info(`Passed: ${passed}/${testCases.length}`);
log.info(`Failed: ${failed}/${testCases.length}`);

if (failed > 0) {
  process.exit(1);
}

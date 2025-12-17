#!/usr/bin/env bun

/**
 * Test token alias resolution
 */

import { resolveAlias, TOKEN_ALIASES } from './config';

console.log('Token Alias Resolution Tests\n');
console.log('Configured aliases:', TOKEN_ALIASES);
console.log('\n--- Test Cases ---\n');

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
    console.log(`✓ ${input.padEnd(25)} → ${result}`);
    passed++;
  } else {
    console.log(`✗ ${input.padEnd(25)} → ${result} (expected: ${expected})`);
    failed++;
  }
}

console.log(`\n--- Results ---`);
console.log(`Passed: ${passed}/${testCases.length}`);
console.log(`Failed: ${failed}/${testCases.length}`);

if (failed > 0) {
  process.exit(1);
}

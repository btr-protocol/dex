#!/usr/bin/env bun

/**
 * Test token alias search functionality
 */

import { tokenMatchesSearch, resolveTokenAlias, TOKENS } from './tokens';
import { logger } from '../utils/logger.js';

const log = logger.withContext('testAliases');

log.info('Token Alias Search Tests');

// Show configured wrappers
const wrappers = Object.entries(TOKENS)
  .filter(([_, token]) => token.wrapperOf)
  .map(([symbol, token]) => `${symbol} → ${token.wrapperOf}`)
  .join(', ');
log.info('Configured wrappers:', wrappers);
log.info('\n--- Resolve Tests ---\n');

const resolveTests = [
  { input: 'WETH', expected: 'ETH' },
  { input: 'weth', expected: 'ETH' },
  { input: 'ETH', expected: 'ETH' },
  { input: 'WBTC', expected: 'BTC' },
  { input: 'CBBTC', expected: 'BTC' },
  { input: 'BTC', expected: 'BTC' },
  { input: 'USDC', expected: 'USDC' },
];

let passed = 0;
let failed = 0;

for (const { input, expected } of resolveTests) {
  const result = resolveTokenAlias(input);
  const success = result === expected;

  if (success) {
    log.info(`✓ resolveTokenAlias('${input}') → ${result}`);
    passed++;
  } else {
    log.info(`✗ resolveTokenAlias('${input}') → ${result} (expected: ${expected})`);
    failed++;
  }
}

log.info('\n--- Search Match Tests ---\n');

const searchTests = [
  { symbol: 'ETH', search: 'eth', expected: true },
  { symbol: 'ETH', search: 'weth', expected: true },  // Should find ETH when searching WETH
  { symbol: 'ETH', search: 'steth', expected: true }, // Should find ETH when searching stETH
  { symbol: 'BTC', search: 'btc', expected: true },
  { symbol: 'BTC', search: 'wbtc', expected: true },  // Should find BTC when searching WBTC
  { symbol: 'BTC', search: 'cbbtc', expected: true }, // Should find BTC when searching CBBTC
  { symbol: 'BTC', search: 'tbtc', expected: true },  // Should find BTC when searching TBTC
  { symbol: 'USDC', search: 'usdc', expected: true },
  { symbol: 'USDC', search: 'weth', expected: false }, // Should NOT find USDC when searching WETH
  { symbol: 'ETH', search: 'btc', expected: false },   // Should NOT find ETH when searching BTC
];

for (const { symbol, search, expected } of searchTests) {
  const result = tokenMatchesSearch(symbol, search);
  const success = result === expected;

  if (success) {
    log.info(`✓ tokenMatchesSearch('${symbol}', '${search}') → ${result}`);
    passed++;
  } else {
    log.info(`✗ tokenMatchesSearch('${symbol}', '${search}') → ${result} (expected: ${expected})`);
    failed++;
  }
}

log.info(`\n--- Results ---`);
log.info(`Passed: ${passed}/${resolveTests.length + searchTests.length}`);
log.info(`Failed: ${failed}/${resolveTests.length + searchTests.length}`);

if (failed > 0) {
  process.exit(1);
}

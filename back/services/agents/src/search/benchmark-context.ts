#!/usr/bin/env bun
/**
 * Context Size Benchmark
 *
 * Tests different source counts and context sizes to measure impact on LLM response time.
 *
 * Usage: bun run back/agents/search/benchmark-context.ts
 *
 * NOTE: This script temporarily modifies config.ts. The server's watch mode will reload.
 */

import { readFileSync, writeFileSync } from 'fs';
import { resolve } from 'path';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('benchmark');

const CONFIG_PATH = resolve(import.meta.dir, 'config.ts');
const API_URL = 'http://localhost:4001/agents/archivist/chat';

interface BenchmarkConfig {
  maxResults: number;
  maxCharsPerResult: number;
  maxTotalChars: number;
  estimatedTokens: number;
}

interface BenchmarkResult {
  maxResults: number;
  estimatedTokens: number;
  query: string;
  duration: number;
  success: boolean;
  sourcesFound: number;
  answerLength: number;
}

// Test configurations: 4, 8, 12, 16 sources with proportional context
const testConfigs: BenchmarkConfig[] = [
  { maxResults: 4, maxCharsPerResult: 600, maxTotalChars: 4 * 3200, estimatedTokens: 4 * 800 },
  { maxResults: 8, maxCharsPerResult: 600, maxTotalChars: 8 * 3200, estimatedTokens: 8 * 800 },
  { maxResults: 12, maxCharsPerResult: 600, maxTotalChars: 12 * 3200, estimatedTokens: 12 * 800 },
  { maxResults: 16, maxCharsPerResult: 600, maxTotalChars: 16 * 3200, estimatedTokens: 16 * 800 },
];

const testQueries = [
  'What is the coverage ratio in ALM?',
  'How does anchor path pricing work?',
  'Explain the fee system',
];

// Update the contextConfig in config.ts
function updateContextConfig(config: BenchmarkConfig): void {
  let content = readFileSync(CONFIG_PATH, 'utf-8');

  // Replace the contextConfig values
  content = content.replace(
    /maxResults:\s*\d+,/,
    `maxResults: ${config.maxResults},`
  );
  content = content.replace(
    /maxCharsPerResult:\s*\d+,/,
    `maxCharsPerResult: ${config.maxCharsPerResult},`
  );
  content = content.replace(
    /maxTotalChars:\s*\d+,/,
    `maxTotalChars: ${config.maxTotalChars},`
  );

  writeFileSync(CONFIG_PATH, content);
  log.info(`Updated config: ${config.maxResults} sources, ${config.maxTotalChars} chars`);
}

async function wait(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function testChat(query: string): Promise<{ duration: number; success: boolean; sourcesFound: number; answerLength: number }> {
  const start = performance.now();

  try {
    const res = await fetch(API_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        type: 'chat',
        message: query,
        sessionId: 'benchmark-context',
      })
    });

    const duration = performance.now() - start;
    const data = await res.json() as { sources?: unknown[]; answer?: string; content?: string };

    return {
      duration,
      success: res.ok,
      sourcesFound: data.sources?.length || 0,
      answerLength: data.answer?.length || data.content?.length || 0,
    };
  } catch (error: any) {
    const duration = performance.now() - start;
    return {
      duration,
      success: false,
      sourcesFound: 0,
      answerLength: 0,
    };
  }
}

function formatDuration(ms: number): string {
  if (ms < 1000) return `${ms.toFixed(0)}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

async function main() {
  log.info('╔═══════════════════════════════════════════════════════════════════════════╗');
  log.info('║                    CONTEXT SIZE BENCHMARK                                  ║');
  log.info('╚═══════════════════════════════════════════════════════════════════════════╝\n');

  const results: BenchmarkResult[] = [];

  for (const config of testConfigs) {
    log.info(`═══════════════════════════════════════════════════════════════`);
    log.info(`  CONFIG: ${config.maxResults} sources (~${config.estimatedTokens} tokens)`);
    log.info(`═══════════════════════════════════════════════════════════════\n`);

    // Update config file (server watch mode will reload)
    updateContextConfig(config);

    // Wait for server to reload
    log.info('Waiting for server reload...');
    await wait(3000);

    // Test each query
    for (const query of testQueries) {
      process.stdout.write(`Testing: "${query}"... `);

      const result = await testChat(query);
      results.push({
        maxResults: config.maxResults,
        estimatedTokens: config.estimatedTokens,
        query,
        ...result,
      });

      if (result.success) {
        log.info(`✅ ${formatDuration(result.duration)} | Sources: ${result.sourcesFound}`);
      } else {
        log.info(`❌ Failed`);
      }
    }

    log.info('');
  }

  // Restore original config (8 sources)
  log.info('Restoring default config...');
  updateContextConfig({
    maxResults: 8,
    maxCharsPerResult: 600,
    maxTotalChars: 8 * 3200,
    estimatedTokens: 8 * 800,
  });

  // Summary
  log.info('\n╔═══════════════════════════════════════════════════════════════════════════╗');
  log.info('║                           SUMMARY                                           ║');
  log.info('╚═══════════════════════════════════════════════════════════════════════════╝\n');

  log.info('┌──────────┬──────────┬──────────┬──────────┬────────────┬───────────┐');
  log.info('│ Sources  │ Avg Time │ Min Time │ Max Time │ Est Tokens │ Success   │');
  log.info('├──────────┼──────────┼──────────┼──────────┼────────────┼───────────┤');

  const byConfig: Record<number, BenchmarkResult[]> = {};
  for (const r of results) {
    if (!byConfig[r.maxResults]) byConfig[r.maxResults] = [];
    byConfig[r.maxResults].push(r);
  }

  for (const [sources, configResults] of Object.entries(byConfig).sort((a, b) => parseInt(a[0]) - parseInt(b[0]))) {
    const successful = configResults.filter(r => r.success);
    const avgTime = successful.length > 0
      ? successful.reduce((sum, r) => sum + r.duration, 0) / successful.length
      : 0;
    const minTime = successful.length > 0 ? Math.min(...successful.map(r => r.duration)) : 0;
    const maxTime = successful.length > 0 ? Math.max(...successful.map(r => r.duration)) : 0;

    log.info(
      `│ ${sources.padStart(8)} │ ` +
      `${formatDuration(avgTime).padStart(8)} │ ` +
      `${formatDuration(minTime).padStart(8)} │ ` +
      `${formatDuration(maxTime).padStart(8)} │ ` +
      `${(parseInt(sources) * 800).toString().padStart(10)} │ ` +
      `${successful.length}/${configResults.length} │`
    );
  }

  log.info('└──────────┴──────────┴──────────┴──────────┴────────────┴───────────┘\n');

  // Analysis
  log.info('═══════════════════════════════════════════════════════════════');
  log.info('  ANALYSIS');
  log.info('═══════════════════════════════════════════════════════════════\n');

  const timesBySources: Record<number, number[]> = {};
  for (const r of results.filter(r => r.success)) {
    if (!timesBySources[r.maxResults]) timesBySources[r.maxResults] = [];
    timesBySources[r.maxResults].push(r.duration);
  }

  const sources = Object.keys(timesBySources).map(Number).sort((a, b) => a - b);
  log.info('Response time vs context size:');
  for (const src of sources) {
    const avg = timesBySources[src].reduce((a, b) => a + b, 0) / timesBySources[src].length;
    log.info(`  ${src} sources (~${src * 800} tokens): ${formatDuration(avg)}`);
  }

  if (sources.length >= 2) {
    const firstAvg = timesBySources[sources[0]!].reduce((a, b) => a + b, 0) / timesBySources[sources[0]!].length;
    const lastAvg = timesBySources[sources[sources.length - 1]!].reduce((a, b) => a + b, 0) / timesBySources[sources[sources.length - 1]!].length;
    const sourcesGrowth = sources[sources.length - 1]! / sources[0]!;
    const timeGrowth = lastAvg / firstAvg;

    log.info(`\n  Sources increased by: ${sourcesGrowth}x`);
    log.info(`  Time increased by: ${timeGrowth.toFixed(2)}x`);

    if (timeGrowth < sourcesGrowth * 0.5) {
      log.info(`  → Time grows slower than context (good scaling)`);
    } else if (timeGrowth < sourcesGrowth * 0.8) {
      log.info(`  → Time grows proportionally to context (acceptable)`);
    } else {
      log.info(`  → Time grows faster than context (consider reducing context)`);
    }
  }

  log.info('\n═══════════════════════════════════════════════════════════════\n');
}

main().catch((e) => log.error('Fatal error', e));

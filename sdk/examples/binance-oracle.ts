/**
 * Example: Running a Binance oracle bot
 * This monitors Binance prices and updates an ExternalOracle contract when divergence thresholds are met
 */

import { BinanceOracle } from '../src/oracles/binance-oracle.js';
import type { Eip1193Provider } from '../src/eth/types.js';
import { logger } from '../src/utils/logger.js';

const log = logger.withContext('binanceOracle');

// ExternalOracle ABI (simplified - only what we need)
const EXTERNAL_ORACLE_ABI = [
  {
    inputs: [
      { name: 'asset', type: 'address' },
      { name: 'newFastTWAP', type: 'uint64' },
      { name: 'newSlowTWAP', type: 'uint64' },
      { name: 'newFastVol', type: 'uint32' },
      { name: 'newSlowVol', type: 'uint32' },
    ],
    name: 'updateAsset',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
  {
    inputs: [
      { name: 'assetAddresses', type: 'address[]' },
      { name: 'fastTWAPs', type: 'uint64[]' },
      { name: 'slowTWAPs', type: 'uint64[]' },
      { name: 'fastVols', type: 'uint32[]' },
      { name: 'slowVols', type: 'uint32[]' },
    ],
    name: 'batchUpdateAssets',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
] as const;

async function main() {
  log.info('Starting Binance Oracle Bot...\n');

  // Setup EIP-1193 provider
  const rpcUrl = process.env.RPC_URL || 'https://eth.llamarpc.com';
  const provider: Eip1193Provider = {
    request: async (args: { method: string; params: any[] }) => {
      const response = await fetch(rpcUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          jsonrpc: '2.0',
          method: args.method,
          params: args.params,
          id: 1,
        }),
      });
      const data = await response.json();
      if (data.error) throw new Error(data.error.message);
      return data.result;
    },
  };

  // External Oracle contract address
  const externalOracleAddress = process.env.EXTERNAL_ORACLE_ADDRESS as `0x${string}`;

  if (!externalOracleAddress) {
    throw new Error('EXTERNAL_ORACLE_ADDRESS environment variable is required');
  }

  // Configure oracle bot
  const oracle = new BinanceOracle(
    provider,
    {
      oracleAddress: externalOracleAddress,
      assets: [
        {
          address: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2', // WETH
          symbol: 'ETH',
          decimals: 18,
        },
        {
          address: '0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599', // WBTC
          symbol: 'BTC',
          decimals: 8,
        },
        {
          address: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', // USDC
          symbol: 'USDC',
          decimals: 6,
        },
        {
          address: '0x6B175474E89094C44Da98b954EedeAC495271d0F', // DAI
          symbol: 'DAI',
          decimals: 18,
        },
      ],
      updateInterval: 60000, // Check every 1 minute
      divergenceThreshold: 50, // Update on-chain if price diverges by 0.5%
    },
    EXTERNAL_ORACLE_ABI
  );

  log.info('Oracle Bot Configuration:');
  log.info(`- External Oracle: ${externalOracleAddress}`);
  log.info(`- Update Interval: ${oracle.config.updateInterval}ms`);
  log.info(`- Divergence Threshold: ${oracle.config.divergenceThreshold / 100}%`);
  log.info(`- Assets Monitored: ${oracle.config.assets.length}`);
  log.info('');

  // Start monitoring (runs indefinitely)
  // The oracle will:
  // 1. Connect to Binance WebSocket for real-time prices
  // 2. Check prices every minute
  // 3. Calculate TWAPs and volatility from recent price history
  // 4. Update on-chain via ExternalOracle.batchUpdateAssets() when divergence threshold is exceeded
  // 5. Use batch updates for efficiency when multiple assets need updating
  await oracle.start();

  // Graceful shutdown on SIGINT
  process.on('SIGINT', () => {
    log.info('\nShutting down oracle...');
    oracle.stop();
    process.exit(0);
  });
}

main().catch((error) => {
  log.error('Fatal error:', error);
  process.exit(1);
});

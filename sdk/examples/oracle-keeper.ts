/**
 * Example: Running a Binance oracle keeper
 * This monitors Binance prices and updates the BAMM pool when divergence thresholds are met
 */

import { BinanceOracle } from '../src/oracles/binance-oracle.js';
import { BAMM_ABI } from '../src/abis/BAMM.js';
import { createPublicClient, createWalletClient, http } from 'viem';
import { mainnet } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';

async function main() {
  console.log('Starting Binance Oracle Keeper...\n');

  // Setup viem clients
  const publicClient = createPublicClient({
    chain: mainnet,
    transport: http(process.env.RPC_URL || 'https://eth.llamarpc.com'),
  });

  const account = privateKeyToAccount(process.env.KEEPER_PRIVATE_KEY as `0x${string}`);
  const walletClient = createWalletClient({
    account,
    chain: mainnet,
    transport: http(process.env.RPC_URL || 'https://eth.llamarpc.com'),
  });

  // Configure oracle
  const oracle = new BinanceOracle(
    publicClient,
    walletClient,
    {
      poolAddress: process.env.POOL_ADDRESS as `0x${string}`,
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
    BAMM_ABI
  );

  // Start monitoring (runs indefinitely)
  // The oracle will:
  // 1. Connect to Binance WebSocket for real-time prices
  // 2. Check prices every minute
  // 3. Update on-chain when divergence threshold is exceeded
  await oracle.start();

  // Graceful shutdown on SIGINT
  process.on('SIGINT', () => {
    console.log('\nShutting down oracle...');
    oracle.stop();
    process.exit(0);
  });
}

main().catch((error) => {
  console.error('Fatal error:', error);
  process.exit(1);
});

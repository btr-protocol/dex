import { createWalletClient, http, type Address } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { localhost } from 'viem/chains';

/**
 * Test wallet configuration for Anvil
 * Allows programmatic transaction signing for testing
 */

// Default Anvil private key (account #0)
const DEFAULT_PRIVATE_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';

/**
 * Create a wallet client from a private key for programmatic signing
 * @param privateKey - Optional private key (defaults to Anvil account #0)
 */
export function createTestWallet(privateKey: `0x${string}` = DEFAULT_PRIVATE_KEY) {
  const account = privateKeyToAccount(privateKey);

  const walletClient = createWalletClient({
    account,
    chain: localhost,
    transport: http('http://127.0.0.1:8545'),
  });

  return {
    walletClient,
    account,
    address: account.address as Address,
  };
}

// Anvil default accounts with their private keys
export const ANVIL_TEST_ACCOUNTS = [
  {
    address: '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266' as Address,
    privateKey: '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80' as `0x${string}`,
    label: 'Anvil #0 (Deployer)',
  },
  {
    address: '0x70997970C51812dc3A010C7d01b50e0d17dc79C8' as Address,
    privateKey: '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d' as `0x${string}`,
    label: 'Anvil #1',
  },
  {
    address: '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC' as Address,
    privateKey: '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a' as `0x${string}`,
    label: 'Anvil #2',
  },
] as const;

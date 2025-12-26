// Contract address types and configuration
// Re-export ContractAddresses type from SDK to ensure consistency
import type { ContractAddresses } from '@sdk/common';

export type { ContractAddresses };

export interface PoolConfig {
  addresses: ContractAddresses;
  chainId: number;
  rpcUrl: string;
}

// Default Anvil configuration
export const ANVIL_CHAIN_ID = 31337;
export const ANVIL_RPC_URL = 'http://127.0.0.1:8545';

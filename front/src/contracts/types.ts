// Contract address types and configuration

export interface ContractAddresses {
  factory: `0x${string}`;
  pool: `0x${string}`;
  usdc: `0x${string}`;
  wbtc: `0x${string}`;
  eth: `0x${string}`;
  deployer: `0x${string}`;
}

export interface PoolConfig {
  addresses: ContractAddresses;
  chainId: number;
  rpcUrl: string;
}

// Default Anvil configuration
export const ANVIL_CHAIN_ID = 31337;
export const ANVIL_RPC_URL = 'http://127.0.0.1:8545';

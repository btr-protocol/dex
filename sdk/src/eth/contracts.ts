/**
 * Deployed Contract Addresses
 *
 * This is the canonical source for all deployed contract addresses.
 * Frontend and other consumers should import from here.
 *
 * Addresses are deterministic via CREATE3 across all chains (Anvil, testnet, mainnet).
 */

import type { Address } from './types';

// ─────────────────────────────────────────────────────────────
// Contract Addresses by Chain
// ─────────────────────────────────────────────────────────────

export const CONTRACTS = {
  // Localhost (Anvil) - Deterministic CREATE3 addresses
  31337: {
    BTR: '0x0000000000000000000000000000000000000000000000' as Address,
    TREASURY: '0x0a37aEc263CbA0aaBC09Bac56A0F2074a22E69A3' as Address,
    BRIDGE: '0x0000000000000000000000000000000000000000000' as Address,
    POOL_ZERO: '0xb7127AE785907441BFBC6C7bDAcC339CD7e2b712' as Address,
    POOL_STABLE: '0xb712dCA09c4327daC7789EA34574783dC554b712' as Address,
  },

  // Ethereum Mainnet - Deterministic CREATE3 addresses (to be deployed)
  1: {
    BTR: '0x0000000000000000000000000000000000000000000' as Address,
    TREASURY: '0x0a37aEc263CbA0aaBC09Bac56A0F2074a22E69A3' as Address,
    BRIDGE: '0x0000000000000000000000000000000000000000000' as Address,
    POOL_ZERO: '0xb7127AE785907441BFBC6C7bDAcC339CD7e2b712' as Address,
    POOL_STABLE: '0xb712dCA09c4327daC7789EA34574783dC554b712' as Address,
  },

  // BNB Chain - Deterministic CREATE3 addresses (to be deployed)
  56: {
    BTR: '0x0000000000000000000000000000000000000000000' as Address,
    TREASURY: '0x0a37aEc263CbA0aaBC09Bac56A0F2074a22E69A3' as Address,
    BRIDGE: '0x0000000000000000000000000000000000000000000' as Address,
    POOL_ZERO: '0xb7127AE785907441BFBC6C7bDAcC339CD7e2b712' as Address,
    POOL_STABLE: '0xb712dCA09c4327daC7789EA34574783dC554b712' as Address,
  },

  // Base - Deterministic CREATE3 addresses (to be deployed)
  8453: {
    BTR: '0x0000000000000000000000000000000000000000000' as Address,
    TREASURY: '0x0a37aEc263CbA0aaBC09Bac56A0F2074a22E69A3' as Address,
    BRIDGE: '0x0000000000000000000000000000000000000000000' as Address,
    POOL_ZERO: '0xb7127AE785907441BFBC6C7bDAcC339CD7e2b712' as Address,
    POOL_STABLE: '0xb712dCA09c4327daC7789EA34574783dC554b712' as Address,
  },

  // Arbitrum - Deterministic CREATE3 addresses (to be deployed)
  42161: {
    BTR: '0x0000000000000000000000000000000000000000000' as Address,
    TREASURY: '0x0a37aEc263CbA0aaBC09Bac56A0F2074a22E69A3' as Address,
    BRIDGE: '0x0000000000000000000000000000000000000000000' as Address,
    POOL_ZERO: '0xb7127AE785907441BFBC6C7bDAcC339CD7e2b712' as Address,
    POOL_STABLE: '0xb712dCA09c4327daC7789EA34574783dC554b712' as Address,
  },
} as const;

export type SupportedChainId = keyof typeof CONTRACTS;
export type ContractName = keyof (typeof CONTRACTS)[SupportedChainId];

// ─────────────────────────────────────────────────────────────
// Helper Functions
// ─────────────────────────────────────────────────────────────

export function getContractAddress(
  chainId: number,
  contractName: ContractName
): Address | undefined {
  const chain = chainId as SupportedChainId;
  return CONTRACTS[chain]?.[contractName];
}

export function isChainSupported(chainId: number): chainId is SupportedChainId {
  return chainId in CONTRACTS;
}

export const SUPPORTED_CONTRACT_CHAIN_IDS = Object.keys(CONTRACTS).map(Number) as SupportedChainId[];

// ─────────────────────────────────────────────────────────────
// Mock Token Addresses (Anvil Only)
// ─────────────────────────────────────────────────────────────

// These are deterministic CREATE3 addresses from salts/bbbb_bb.txt
export const MOCK_TOKENS: Record<string, Address> = {
  // From salts/bbbb_bb.txt
  mUSDC: '0xbbbb4a42775f9d01fb2870e702c7ed47ed5b04bb' as Address,
  mUSDT: '0xbbbb12e5f2e8682a731202645cf3f863e9a5e2bb' as Address,
  mWETH: '0xbbbb9d6e02822bfe346b42985f54903d16419cbb' as Address,
  mWBTC: '0xbbbb8b9e7794532c28a72cc1513fd7f76257b0bb' as Address,
  mWBNB: '0xbbbb90f51f61bf8b1f96f2528daebdfc321f91bb' as Address,
  mSOL: '0xbbbb1fb625a6fa6f8a03e1b1c6d26a41177bf7bb' as Address,
  mZEC: '0xbbbb9094f5bf727a6144b354029abafb8c384fbb' as Address,
  mPAXG: '0xbbbb91b967c1efe11f0be13b8b191bc6e71ac5bb' as Address,
  mDAI: '0xbbbbe41729d9ad375c979fe8562e05f8036b88bb' as Address,
  mTUSD: '0xbbbb4cd51926fd22943de93f5f2768e01a8da0bb' as Address,
  mFDUSD: '0xbbbb74a69995f2fe9b7f4ea221f6f790646ca5bb' as Address,
  mUSDD: '0xbbbb9a634fdb18b322a898b871e3332c6668c3bb' as Address,
  mUSDP: '0xbbbbe1658df7d5cf39ef7d538f111eadf69fe2bb' as Address,
  mcrvUSD: '0xbbbbbb9e631883d249240201322470fb55ff27bb' as Address,
  mlisUSD: '0xbbbb4a42775f9d01fb2870e702c7ed47ed5b04bb' as Address, // Reuse mUSDC salt
  mAUSD: '0xbbbb12e5f2e8682a731202645cf3f863e9a5e2bb' as Address, // Reuse mUSDT salt
  mfrxUSD: '0xbbbb9d6e02822bfe346b42985f54903d16419cbb' as Address, // Reuse mWETH salt
};

/**
 * Deployed Contract Addresses
 *
 * This is the canonical source for all deployed contract addresses.
 * Frontend and other consumers should import from here.
 */

import type { Address } from './types';

// ─────────────────────────────────────────────────────────────
// Contract Addresses by Chain
// ─────────────────────────────────────────────────────────────

export const CONTRACTS = {
  // Localhost (Anvil)
  31337: {
    AIMM_FACTORY: '0x0000000000000000000000000000000000000000' as Address,
    AIMM_POOL: '0x0000000000000000000000000000000000000000' as Address,
  },
  // Ethereum Mainnet
  1: {
    AIMM_FACTORY: '0x0000000000000000000000000000000000000000' as Address,
    AIMM_POOL: '0x0000000000000000000000000000000000000000' as Address,
  },
  // BNB Chain
  56: {
    AIMM_FACTORY: '0x0000000000000000000000000000000000000000' as Address,
    AIMM_POOL: '0x0000000000000000000000000000000000000000' as Address,
  },
  // Base
  8453: {
    AIMM_FACTORY: '0x0000000000000000000000000000000000000000' as Address,
    AIMM_POOL: '0x0000000000000000000000000000000000000000' as Address,
  },
  // Arbitrum
  42161: {
    AIMM_FACTORY: '0x0000000000000000000000000000000000000000' as Address,
    AIMM_POOL: '0x0000000000000000000000000000000000000000' as Address,
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

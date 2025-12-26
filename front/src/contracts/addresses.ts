import type { ContractAddresses } from './types';
import { CONTRACT_ADDRESSES } from '@/config/contracts';

/**
 * Get contract addresses - these are build-time constants
 * No runtime loading required, enabling proper type safety and tree-shaking
 */
export function getAddresses(): ContractAddresses {
  return CONTRACT_ADDRESSES;
}

/**
 * @deprecated Use getAddresses() instead - addresses are now loaded at build time
 */
export async function loadAddresses(): Promise<ContractAddresses> {
  return CONTRACT_ADDRESSES;
}

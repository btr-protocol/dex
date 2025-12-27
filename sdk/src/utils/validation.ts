/**
 * Input validation utilities
 */

import type { Address, Eip1193Provider } from '../eth/index.js';

/**
 * Validate address format
 */
export function isValidAddress(address: string): boolean {
  return /^0x[a-fA-F0-9]{40}$/.test(address);
}

/**
 * Check if address has code (is contract)
 */
export async function isContract(
  provider: Eip1193Provider,
  address: Address,
): Promise<boolean> {
  const code = await provider.request({
    method: 'eth_getCode',
    params: [address, 'latest'],
  }) as string;
  return code !== undefined && code !== '0x';
}

/**
 * Contract Configuration - Build-time constants for deployed contracts
 *
 * Contract addresses come from the SDK and are injected at build time.
 * This ensures frontend and backend share the same address definitions.
 *
 * Environment variables (VITE_*_ADDRESS) override SDK defaults for local development.
 */
import type { ContractAddresses } from '@sdk/common';

// Build-time contract addresses
// Get from environment variables first, then fallback to defaults
const FACTORY = (import.meta.env.VITE_FACTORY_ADDRESS || import.meta.env.VITE_FACTORY) as `0x${string}` | undefined;
const POOL = (import.meta.env.VITE_POOL_ADDRESS || import.meta.env.VITE_POOL) as `0x${string}` | undefined;
const USDC = (import.meta.env.VITE_USDC_ADDRESS || import.meta.env.VITE_USDC) as `0x${string}` | undefined;
const WBTC = (import.meta.env.VITE_WBTC_ADDRESS || import.meta.env.VITE_WBTC) as `0x${string}` | undefined;
const ETH = (import.meta.env.VITE_ETH_ADDRESS || import.meta.env.VITE_ETH) as `0x${string}` | undefined;
const DEPLOYER = (import.meta.env.VITE_DEPLOYER_ADDRESS || import.meta.env.VITE_DEPLOYER || '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266') as `0x${string}`;

const zeroAddress = '0x0000000000000000000000000000000000000000' as const;

/**
 * Contract addresses for the current environment
 * These are injected at build time via environment variables and remain constant at runtime
 */
export const CONTRACT_ADDRESSES: ContractAddresses = {
  factory: FACTORY || (zeroAddress as `0x${string}`),
  pool: POOL || (zeroAddress as `0x${string}`),
  usdc: USDC || (zeroAddress as `0x${string}`),
  wbtc: WBTC || (zeroAddress as `0x${string}`),
  eth: ETH || (zeroAddress as `0x${string}`),
  deployer: DEPLOYER,
};

/**
 * Validate that required contract addresses are configured
 * Call this during app initialization to catch configuration errors early
 */
export function validateContractAddresses(): boolean {
  const required = ['factory', 'pool', 'usdc'] as const;
  const missing = required.filter(
    (key) => CONTRACT_ADDRESSES[key] === zeroAddress
  );

  if (missing.length > 0) {
    console.warn(
      `⚠️ Missing contract addresses for: ${missing.join(', ')}. ` +
      `Set environment variables: ${missing.map((k) => `VITE_${k.toUpperCase()}_ADDRESS`).join(', ')}`
    );
    return false;
  }

  console.log('✓ Contract addresses configured:', {
    pool: CONTRACT_ADDRESSES.pool,
    factory: CONTRACT_ADDRESSES.factory,
  });

  return true;
}

/**
 * Minimal Ethereum utilities
 * Zero dependencies
 */

// Types
export type {
  Address,
  Hex,
  Eip1193Provider,
  TransactionRequest,
  TransactionReceipt,
  Log,
  TypedDataDomain,
  TypedDataField,
  TypedData,
} from './types';

export {
  isAddress,
  isHex,
  checksumAddress,
  zeroAddress,
  isZeroAddress,
} from './types';

// Chains
export type { ChainConfig, ChainId, ChainInfo } from './chains';
export {
  CHAINS,
  getChain,
  getChainInfo,
  getAllChainInfo,
  getChainIcon,
  getRpcUrl,
  getAllRpcs,
  getExplorerUrl,
  getWrappedNative,
  getMulticall3,
  testRpc,
  getHealthyRpc,
  getSupportedChainIds,
  getMainnetChainIds,
  isTestOrLocalChain,
  detectAnvilFork,
  getAnvilChainConfig,
} from './chains';

// Tokens
export type { TokenMetadata } from './tokens';
export {
  TOKENS,
  CANONICAL_TOKENS,
  ALL_TOKENS,
  BASE_TOKENS,
  QUOTE_TOKENS,
  getTokenIcon,
  getTokenAddress,
  getAllTokensForChain,
  resolveTokenAlias,
  tokenMatchesSearch,
} from './tokens';

// Contracts (deployed addresses)
export type { SupportedChainId, ContractName } from './contracts';
export {
  CONTRACTS,
  getContractAddress,
  isChainSupported,
  SUPPORTED_CONTRACT_CHAIN_IDS,
} from './contracts';

// ABI
export type { Abi, AbiFunction } from './abi';
export {
  getSelector,
  encode,
  decode,
  encodeFn,
  decodeFn,
} from './abi';

// Token Standards
export { ERC20_ABI } from './erc20';
export { ERC721_ABI } from './erc721';
export { ERC1155_ABI } from './erc1155';
export { ERC777_ABI } from './erc777';
export { ERC4626_ABI } from './erc4626';
export { ERC7540_ABI } from './erc7540';
export { LAYERZERO_OFT_ABI } from './layerzero-oft';

// RPC
export {
  requestAccounts,
  getAccounts,
  getChainId,
  getGasPrice,
  getBlockNumber,
  getNativeBalance,
  getTransactionCount,
  ethCall,
  estimateGas,
  sendTransaction,
  signMessage,
  signTypedData,
  switchChain,
  addChain,
  waitForTransaction,
  onAccountsChanged,
  onChainChanged,
  onDisconnect,
} from './rpc';

// Contract
export type { ContractConfig, ReadOptions, WriteOptions } from './contract';
export { Contract, getContract, readContract, writeContract } from './contract';

// Multicall
export type { Call } from './multicall';
export { MC3_ADDR, multicall, multicallStrict } from './multicall';

// Wallets
export type { WalletInfo, Eip6963Detail } from './wallets';
export {
  WALLETS,
  WC_ICONS,
  DISCOVER_MOBILE,
  DISCOVER_DESKTOP,
  isMobile,
  getIcon,
  getDownloadUrl,
  getName,
  getTooltip,
  detectLegacy,
  eip6963Store,
  toWalletInfo,
  mergeWallets,
  getMetaMask,
  getBaseWallet,
  getCoinbaseWallet,
  getRabby,
  getPhantom,
  getInjected,
} from './wallets';

// ─────────────────────────────────────────────────────────────
// Formatting Utilities
// ─────────────────────────────────────────────────────────────

export function formatUnits(value: bigint, decimals: number): string {
  const str = value.toString().padStart(decimals + 1, '0');
  const intPart = str.slice(0, -decimals) || '0';
  const decPart = str.slice(-decimals);
  const trimmed = decPart.replace(/0+$/, '');
  return trimmed ? `${intPart}.${trimmed}` : intPart;
}

export function parseUnits(value: string, decimals: number): bigint {
  const [intPart, decPart = ''] = value.split('.');
  const padded = decPart.padEnd(decimals, '0').slice(0, decimals);
  return BigInt(intPart + padded);
}

export function formatEther(value: bigint): string {
  return formatUnits(value, 18);
}

export function parseEther(value: string): bigint {
  return parseUnits(value, 18);
}

// ─────────────────────────────────────────────────────────────
// Hex Utilities
// ─────────────────────────────────────────────────────────────

export function hexToNumber(hex: string): number {
  return parseInt(hex, 16);
}

export function numberToHex(num: number | bigint): `0x${string}` {
  return `0x${num.toString(16)}`;
}

export function hexToBigInt(hex: string): bigint {
  return BigInt(hex);
}

export function bigIntToHex(num: bigint): `0x${string}` {
  return `0x${num.toString(16)}`;
}

/**
 * Convert various types to hex string
 */
export function toHex(
  value: string | number | bigint | boolean | Uint8Array,
): `0x${string}` {
  if (typeof value === 'string') {
    // Already hex
    if (value.startsWith('0x')) return value as `0x${string}`;
    // UTF-8 string to hex
    return `0x${Array.from(new TextEncoder().encode(value))
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('')}`;
  }
  if (typeof value === 'number' || typeof value === 'bigint') {
    return numberToHex(value);
  }
  if (typeof value === 'boolean') {
    return value ? '0x1' : '0x0';
  }
  if (value instanceof Uint8Array) {
    return `0x${Array.from(value)
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('')}`;
  }
  throw new Error(`Cannot convert ${typeof value} to hex`);
}

/**
 * Concatenate hex strings or byte arrays
 */
export function concat(values: (`0x${string}` | Uint8Array)[]): `0x${string}` {
  let result = '';
  for (const val of values) {
    if (typeof val === 'string') {
      result += val.slice(2); // Remove 0x prefix
    } else {
      result += Array.from(val)
        .map((b) => b.toString(16).padStart(2, '0'))
        .join('');
    }
  }
  return `0x${result}`;
}

/**
 * Pad hex string to specified byte length
 * @param hex - Hex string to pad
 * @param size - Target byte length (default: 32)
 * @param dir - Padding direction: 'left' (default) or 'right'
 */
export function pad(
  hex: `0x${string}`,
  size = 32,
  dir: 'left' | 'right' = 'left',
): `0x${string}` {
  const stripped = hex.slice(2);
  const targetLength = size * 2; // 2 hex chars per byte

  if (stripped.length >= targetLength) {
    return hex;
  }

  const padding = '0'.repeat(targetLength - stripped.length);
  return dir === 'left'
    ? `0x${padding}${stripped}`
    : `0x${stripped}${padding}`;
}

/**
 * Keccak-256 hash function (Ethereum's hash)
 * Uses native crypto.subtle when available, falls back to noble-hashes
 */
export async function keccak256(data: `0x${string}` | Uint8Array): Promise<`0x${string}`> {
  const bytes = typeof data === 'string'
    ? new Uint8Array(data.slice(2).match(/.{1,2}/g)!.map((byte) => parseInt(byte, 16)))
    : data;

  // Try native crypto first (fastest)
  if (typeof globalThis.crypto !== 'undefined' && globalThis.crypto.subtle) {
    try {
      // Use SHA3-256 if available (not all browsers support it)
      const hash = await globalThis.crypto.subtle.digest('SHA3-256', bytes);
      return `0x${Array.from(new Uint8Array(hash))
        .map((b) => b.toString(16).padStart(2, '0'))
        .join('')}`;
    } catch {
      // SHA3 not supported, fall through to noble-hashes
    }
  }

  // Fallback: use noble-hashes (lightweight, well-tested)
  const hashes = await import('@noble/hashes');
  const { keccak_256 } = hashes.sha3 || hashes;
  const hash = keccak_256(bytes);
  return `0x${Array.from(hash)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')}`;
}

/**
 * Synchronous keccak256 (requires noble-hashes)
 */
export function keccak256Sync(data: `0x${string}` | Uint8Array): `0x${string}` {
  const bytes = typeof data === 'string'
    ? new Uint8Array(data.slice(2).match(/.{1,2}/g)!.map((byte) => parseInt(byte, 16)))
    : data;

  // Requires @noble/hashes to be installed
  // @ts-ignore - dynamic import
  const hashes = require('@noble/hashes');
  const { keccak_256 } = hashes.sha3 || hashes;
  const hash = keccak_256(bytes);
  return `0x${Array.from(hash)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')}`;
}

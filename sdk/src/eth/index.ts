/**
 * Minimal Ethereum utilities
 * Depends on @noble/hashes for keccak256
 */

import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex, hexToBytes } from '@noble/hashes/utils.js';

// Re-export @noble/hashes utilities for convenience
export { bytesToHex, hexToBytes };

// Input type for @noble/hashes functions (string is UTF-8, not hex)
export type Input = string | Uint8Array;

// Types
export type {
  Address,
  Hex,
  PublicClient,
  WalletClient,
  Hash,
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

// Custom Contract ABIs (POOL_ABI exported from pool module)
export { AIMM_ABI } from '../abis/AIMM.js';
export { DARKPOOL_ABI } from '../abis/DarkPool.js';

// Mock Data
export { MOCK_PRICES, getMockPrice } from './mock';

// RPC
export {
  requestAccounts,
  getAccounts,
  getChainId,
  getGasPrice,
  getBlockNumber,
  getNativeBalance,
  getTransactionCount,
  getTransactionReceipt,
  getNonce,
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

// Signature Verification
export { recoverAddress, verifySignature } from './signature';

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
  eip6963Providers,
  toWalletInfo,
  mergeWallets,
  getMetaMask,
  getBaseWallet,
  getRabby,
  getPhantom,
  getInjected,
} from './wallets';

// ─────────────────────────────────────────────────────────────
// Re-export formatting and encoding utilities from utils
// ─────────────────────────────────────────────────────────────

export {
  formatUnits,
  parseUnits,
  formatEther,
  parseEther,
} from '../utils/format.js';

export {
  toHex,
  concat,
  pad,
  hexToNumber,
  numberToHex,
  hexToBigInt,
  bigIntToHex,
} from '../utils/encoding.js';

// ─────────────────────────────────────────────────────────────
// Keccak256 (using @noble/hashes)
// ─────────────────────────────────────────────────────────────

/**
 * Keccak-256 hash function (Ethereum's hash)
 * Accepts hex string or Uint8Array and returns hex string
 */
export function keccak256(data: `0x${string}` | Uint8Array): `0x${string}` {
  const bytes = typeof data === 'string' ? hexToBytes(data.slice(2)) : data;
  const hash = keccak_256(bytes);
  return `0x${bytesToHex(hash)}`;
}

/**
 * Keccak-256 for Input type (string or Uint8Array)
 * String input is treated as UTF-8, not hex
 */
export function keccak256Input(data: Input): `0x${string}` {
  const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : data;
  const hash = keccak_256(bytes);
  return `0x${bytesToHex(hash)}`;
}

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

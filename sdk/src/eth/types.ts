/**
 * Core Ethereum types
 * Zero dependencies
 */

// ─────────────────────────────────────────────────────────────
// Primitives
// ─────────────────────────────────────────────────────────────

export type Address = `0x${string}`;
export type Hex = `0x${string}`;

// ─────────────────────────────────────────────────────────────
// EIP-1193 Provider
// ─────────────────────────────────────────────────────────────

export interface Eip1193Provider {
  request(args: { method: string; params?: unknown[] }): Promise<unknown>;
  on?(event: string, listener: (...args: unknown[]) => void): void;
  removeListener?(event: string, listener: (...args: unknown[]) => void): void;
}

// ─────────────────────────────────────────────────────────────
// Transactions
// ─────────────────────────────────────────────────────────────

export interface TransactionRequest {
  from: Address;
  to?: Address;
  data?: Hex;
  value?: Hex;
  gas?: Hex;
  gasPrice?: Hex;
  maxFeePerGas?: Hex;
  maxPriorityFeePerGas?: Hex;
  nonce?: Hex;
  chainId?: Hex;
}

export interface TransactionReceipt {
  transactionHash: Hex;
  blockNumber: Hex;
  blockHash: Hex;
  from: Address;
  to: Address | null;
  contractAddress: Address | null;
  status: '0x0' | '0x1';
  gasUsed: Hex;
  cumulativeGasUsed: Hex;
  logs: Log[];
}

export interface Log {
  address: Address;
  topics: Hex[];
  data: Hex;
  blockNumber: Hex;
  transactionHash: Hex;
  logIndex: Hex;
  removed: boolean;
}

// ─────────────────────────────────────────────────────────────
// EIP-712 Typed Data
// ─────────────────────────────────────────────────────────────

export interface TypedDataDomain {
  name?: string;
  version?: string;
  chainId?: number | bigint;
  verifyingContract?: Address;
  salt?: Hex;
}

export interface TypedDataField {
  name: string;
  type: string;
}

export interface TypedData {
  domain: TypedDataDomain;
  types: Record<string, TypedDataField[]>;
  primaryType: string;
  message: Record<string, unknown>;
}

// ─────────────────────────────────────────────────────────────
// Viem-compatible Types (for guardian/oracle compatibility)
// ─────────────────────────────────────────────────────────────

export type PublicClient = Eip1193Provider;
export type WalletClient = Eip1193Provider;
export type Hash = Hex;

// ─────────────────────────────────────────────────────────────
// Validation Helpers
// ─────────────────────────────────────────────────────────────

export function isAddress(value: string): value is Address {
  return /^0x[a-fA-F0-9]{40}$/.test(value);
}

export function isHex(value: string): value is Hex {
  return /^0x[a-fA-F0-9]*$/.test(value);
}

export function checksumAddress(address: string): Address {
  const lower = address.toLowerCase();
  if (!isAddress(lower)) throw new Error('Invalid address');
  return lower as Address;
}

// ─────────────────────────────────────────────────────────────
// Zero Address
// ─────────────────────────────────────────────────────────────

export const zeroAddress: Address = '0x0000000000000000000000000000000000000000';

export function isZeroAddress(address: string): boolean {
  return address.toLowerCase() === zeroAddress;
}

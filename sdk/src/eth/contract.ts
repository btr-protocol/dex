/**
 * Minimal Contract class
 * Zero dependencies
 */

import type { Address, Hex, Eip1193Provider, TransactionRequest } from './types';
import type { Abi, AbiFunction } from './abi';
import { encodeFn, decodeFn } from './abi';
import { ethCall, sendTransaction, estimateGas } from './rpc';

// ─────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────

export interface ContractConfig {
  address: Address;
  abi: Abi;
  provider: Eip1193Provider;
  account?: Address;
}

export interface ReadOptions {
  blockTag?: 'latest' | 'pending' | 'earliest' | Hex;
}

export interface WriteOptions {
  value?: bigint;
  gas?: bigint;
  gasPrice?: bigint;
  maxFeePerGas?: bigint;
  maxPriorityFeePerGas?: bigint;
}

// ─────────────────────────────────────────────────────────────
// Contract Class
// ─────────────────────────────────────────────────────────────

export class Contract {
  readonly address: Address;
  readonly abi: Abi;
  readonly provider: Eip1193Provider;
  account?: Address;

  constructor(config: ContractConfig) {
    this.address = config.address;
    this.abi = config.abi;
    this.provider = config.provider;
    this.account = config.account;
  }

  connect(account: Address): Contract {
    return new Contract({
      address: this.address,
      abi: this.abi,
      provider: this.provider,
      account,
    });
  }

  async read<T = unknown>(
    functionName: string,
    args: readonly unknown[] = [],
    options: ReadOptions = {}
  ): Promise<T> {
    const data = encodeFn({ abi: this.abi, functionName, args });
    const result = await ethCall(this.provider, this.address, data, options.blockTag || 'latest');
    return decodeFn({ abi: this.abi, functionName, data: result }) as T;
  }

  async write(
    functionName: string,
    args: readonly unknown[] = [],
    options: WriteOptions = {}
  ): Promise<Hex> {
    if (!this.account) throw new Error('No account connected');

    const data = encodeFn({ abi: this.abi, functionName, args });
    const tx: TransactionRequest = { from: this.account, to: this.address, data };

    if (options.value !== undefined) tx.value = `0x${options.value.toString(16)}`;
    if (options.gas !== undefined) tx.gas = `0x${options.gas.toString(16)}`;
    if (options.gasPrice !== undefined) tx.gasPrice = `0x${options.gasPrice.toString(16)}`;
    if (options.maxFeePerGas !== undefined) tx.maxFeePerGas = `0x${options.maxFeePerGas.toString(16)}`;
    if (options.maxPriorityFeePerGas !== undefined) tx.maxPriorityFeePerGas = `0x${options.maxPriorityFeePerGas.toString(16)}`;

    return sendTransaction(this.provider, tx);
  }

  async simulate(
    functionName: string,
    args: readonly unknown[] = [],
    options: WriteOptions = {}
  ): Promise<{ gas: bigint }> {
    if (!this.account) throw new Error('No account connected');

    const data = encodeFn({ abi: this.abi, functionName, args });
    const tx: Partial<TransactionRequest> = { from: this.account, to: this.address, data };
    if (options.value !== undefined) tx.value = `0x${options.value.toString(16)}`;

    const gas = await estimateGas(this.provider, tx);
    return { gas };
  }

  encodeData(functionName: string, args: readonly unknown[] = []): Hex {
    return encodeFn({ abi: this.abi, functionName, args });
  }

  decodeResult<T = unknown>(functionName: string, data: Hex): T {
    return decodeFn({ abi: this.abi, functionName, data }) as T;
  }

  getFunction(name: string): AbiFunction | undefined {
    return this.abi.find(
      (item): item is AbiFunction => item.type === 'function' && (item as AbiFunction).name === name
    );
  }

  isReadOnly(functionName: string): boolean {
    const fn = this.getFunction(functionName);
    return fn?.stateMutability === 'view' || fn?.stateMutability === 'pure';
  }
}

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────

export function getContract(config: ContractConfig): Contract {
  return new Contract(config);
}

export async function readContract<T = unknown>(
  provider: Eip1193Provider,
  address: Address,
  abi: Abi,
  functionName: string,
  args: readonly unknown[] = []
): Promise<T> {
  return new Contract({ address, abi, provider }).read<T>(functionName, args);
}

export async function writeContract(
  provider: Eip1193Provider,
  address: Address,
  abi: Abi,
  functionName: string,
  args: readonly unknown[] = [],
  account: Address,
  options: WriteOptions = {}
): Promise<Hex> {
  return new Contract({ address, abi, provider, account }).write(functionName, args, options);
}

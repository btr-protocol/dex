/**
 * Unified Client for Ethereum interactions
 * Supports both injected wallets (browser) and private key wallets (backend)
 */

import type { Address, Hex, Eip1193Provider, TransactionRequest, TransactionReceipt } from './types';
import { ethCall, sendTransaction as rpcSendTransaction, getNonce, getChainId, estimateGas, getGasPrice } from './rpc';
import { keccak256 } from './index';
import { hexToBytes, bytesToHex } from '@noble/hashes/utils.js';
import { secp256k1 } from '@noble/curves/secp256k1';
import { rlpEncode } from './rlp';

// ─────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────

export interface Client {
  provider: Eip1193Provider;
  account?: Address;
  call: (to: Address, data: Hex) => Promise<Hex>;
  sendTransaction: (tx: Omit<TransactionRequest, 'from'>) => Promise<Hex>;
  estimateGas: (tx: Omit<TransactionRequest, 'from'>) => Promise<bigint>;
}

// ─────────────────────────────────────────────────────────────
// Injected Wallet Client (Browser)
// ─────────────────────────────────────────────────────────────

/**
 * Create a client from an injected wallet provider
 * Requires user approval for transactions
 */
export function createWalletClient(provider: Eip1193Provider, account: Address): Client {
  return {
    provider,
    account,
    call: async (to: Address, data: Hex) => {
      return ethCall(provider, to, data);
    },
    sendTransaction: async (tx: Omit<TransactionRequest, 'from'>) => {
      return rpcSendTransaction(provider, { ...tx, from: account } as TransactionRequest);
    },
    estimateGas: async (tx: Omit<TransactionRequest, 'from'>) => {
      return estimateGas(provider, { ...tx, from: account } as TransactionRequest);
    },
  };
}

// ─────────────────────────────────────────────────────────────
// Private Key Client (Backend)
// ─────────────────────────────────────────────────────────────

/**
 * Create an HTTP provider for backend use
 */
export function createHttpProvider(rpcUrl: string): Eip1193Provider {
  let id = 0;

  return {
    request: async ({ method, params }: { method: string; params?: unknown[] }) => {
      const response = await fetch(rpcUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          jsonrpc: '2.0',
          id: ++id,
          method,
          params: params || [],
        }),
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
      }

      const json = await response.json() as { error?: { message?: string }; result?: unknown };

      if (json.error) {
        throw new Error(json.error.message || 'RPC error');
      }

      return json.result;
    },
  };
}

/**
 * Derive address from private key
 */
export function privateKeyToAddress(privateKey: Hex): Address {
  const privKeyBytes = hexToBytes(privateKey.slice(2));
  const publicKey = secp256k1.getPublicKey(privKeyBytes, false); // Uncompressed

  // Take keccak256 of uncompressed public key (without 0x04 prefix)
  const pubKeyHash = keccak256(`0x${bytesToHex(publicKey.slice(1))}`);

  // Take last 20 bytes as address
  return `0x${pubKeyHash.slice(-40)}` as Address;
}

/**
 * Sign a transaction with private key
 */
async function signTransaction(
  provider: Eip1193Provider,
  tx: TransactionRequest,
  privateKey: Hex
): Promise<Hex> {
  const chainId = await getChainId(provider);
  const nonce = tx.nonce ?? (await getNonce(provider, tx.from!));
  const gasLimit = tx.gas ?? (await estimateGas(provider, tx));

  // EIP-1559 (Type 2)
  if (tx.maxFeePerGas && tx.maxPriorityFeePerGas) {
    const txData = [
      chainId,
      nonce,
      tx.maxPriorityFeePerGas,
      tx.maxFeePerGas,
      gasLimit,
      tx.to || '0x',
      tx.value || 0n,
      tx.data || '0x',
      [], // accessList (empty)
    ];

    // Hash the transaction
    const txHash = keccak256(new Uint8Array([0x02, ...rlpEncode(txData)]));

    // Sign
    const signature = secp256k1.sign(hexToBytes(txHash.slice(2)), hexToBytes(privateKey.slice(2)));
    const r = signature.r;
    const s = signature.s;
    const v = BigInt(signature.recovery!) + BigInt(chainId) * 2n + 35n;

    // Encode signed transaction
    const signedTx = [
      chainId,
      nonce,
      tx.maxPriorityFeePerGas,
      tx.maxFeePerGas,
      gasLimit,
      tx.to || '0x',
      tx.value || 0n,
      tx.data || '0x',
      [],
      v,
      r,
      s,
    ];

    return `0x02${bytesToHex(rlpEncode(signedTx))}` as Hex;
  }

  // Legacy (Type 0)
  const gasPrice = tx.gasPrice ?? (await getGasPrice(provider));

  const txData = [
    nonce,
    gasPrice,
    gasLimit,
    tx.to || '0x',
    tx.value || 0n,
    tx.data || '0x',
    chainId,
    0n,
    0n,
  ];

  // Hash the transaction
  const txHash = keccak256(rlpEncode(txData));

  // Sign
  const signature = secp256k1.sign(hexToBytes(txHash.slice(2)), hexToBytes(privateKey.slice(2)));
  const r = signature.r;
  const s = signature.s;
  const v = BigInt(signature.recovery!) + BigInt(chainId) * 2n + 35n;

  // Encode signed transaction
  const signedTx = [
    nonce,
    gasPrice,
    gasLimit,
    tx.to || '0x',
    tx.value || 0n,
    tx.data || '0x',
    v,
    r,
    s,
  ];

  return `0x${bytesToHex(rlpEncode(signedTx))}` as Hex;
}

/**
 * Create a client from a private key (for backend use)
 * Can sign transactions without user approval
 */
export function createPrivateKeyClient(rpcUrl: string, privateKey: Hex): Client {
  const provider = createHttpProvider(rpcUrl);
  const account = privateKeyToAddress(privateKey);

  return {
    provider,
    account,
    call: async (to: Address, data: Hex) => {
      return ethCall(provider, to, data);
    },
    sendTransaction: async (tx: Omit<TransactionRequest, 'from'>) => {
      // Sign and send transaction
      const signedTx = await signTransaction(provider, { ...tx, from: account } as TransactionRequest, privateKey);
      return (await provider.request({
        method: 'eth_sendRawTransaction',
        params: [signedTx],
      })) as Hex;
    },
    estimateGas: async (tx: Omit<TransactionRequest, 'from'>) => {
      return estimateGas(provider, { ...tx, from: account } as TransactionRequest);
    },
  };
}

// ─────────────────────────────────────────────────────────────
// Public Client (Read-only)
// ─────────────────────────────────────────────────────────────

/**
 * Create a read-only client (no account required)
 */
export function createPublicClient(provider: Eip1193Provider | string): Client {
  const actualProvider = typeof provider === 'string' ? createHttpProvider(provider) : provider;

  return {
    provider: actualProvider,
    call: async (to: Address, data: Hex) => {
      return ethCall(actualProvider, to, data);
    },
    sendTransaction: async () => {
      throw new Error('Cannot send transactions with read-only client');
    },
    estimateGas: async (tx: Omit<TransactionRequest, 'from'>) => {
      return estimateGas(actualProvider, tx as TransactionRequest);
    },
  };
}

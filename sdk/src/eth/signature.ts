/**
 * Ethereum signature verification for personal_sign format
 */

import type { Address, Hex } from './types';
import { keccak256 } from './index';
import { hexToBytes, bytesToHex } from '@noble/hashes/utils.js';
import { secp256k1 } from '@noble/curves/secp256k1';

/**
 * Recover signer address from personal_sign signature
 * @param signature - Hex string of signature (0x...), 65 bytes (r + s + v)
 * @param message - Original message string that was signed
 * @returns Recovered Ethereum address
 */
export function recoverAddress(signature: Hex, message: string): Address {
  // Decode signature
  const sigBytes = hexToBytes(signature.slice(2)); // remove 0x

  if (sigBytes.length !== 65) {
    throw new Error('Invalid signature length: expected 65 bytes (r + s + v)');
  }

  const r = sigBytes.slice(0, 32);
  const s = sigBytes.slice(32, 64);
  const v = sigBytes[64]; // Recovery id (27 or 28 for personal_sign)

  // Normalize v to recovery id (0 or 1)
  const recoveryId = v - 27;

  if (recoveryId < 0 || recoveryId > 1) {
    throw new Error(`Invalid recovery id v=${v}, expected 27 or 28`);
  }

  // Hash message with Ethereum prefix for personal_sign
  const msgBytes = new TextEncoder().encode(message);
  const prefix = new TextEncoder().encode(`\x19Ethereum Signed Message:\n${msgBytes.length}`);
  const msgHash = keccak256(new Uint8Array([...prefix, ...msgBytes]));

  // Recover public key using compact signature (r + s) and recovery id
  // Note: recoverPublicKey is on the secp256k1 instance
  const compactSig = new Uint8Array([...r, ...s]);
  // @ts-ignore - Noble curves types may be outdated, but this function exists at runtime
  const publicKey = (secp256k1 as any).secp256k1.recoverPublicKey(compactSig, hexToBytes(msgHash.slice(2)), recoveryId);

  // Derive address from public key (skip 0x04 prefix, hash, take last 20 bytes)
  const pubKeyHash = keccak256(`0x${bytesToHex(publicKey.slice(1))}`);
  return `0x${pubKeyHash.slice(-40)}` as Address;
}

/**
 * Verify that signature matches address
 * @param signature - Hex string of signature (0x...), 65 bytes (r + s + v)
 * @param message - Original message string that was signed
 * @param address - Expected signer address
 * @returns True if signature is valid for address
 */
export function verifySignature(signature: Hex, message: string, address: Address): boolean {
  const recovered = recoverAddress(signature, message);
  return recovered.toLowerCase() === address.toLowerCase();
}

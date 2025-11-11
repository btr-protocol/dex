/**
 * BTR DEX SDK
 * Modular SDK for interacting with BTR DEX - supports AMM flows, oracles, guardians, and privacy features
 *
 * @example Basic usage (frontend - light bundle)
 * ```ts
 * import { deposit, swap, withdraw } from '@btr/dex-sdk/flows';
 * import { BAMM_ABI } from '@btr/dex-sdk/abis';
 * import { createPublicClient, createWalletClient } from 'viem';
 *
 * const publicClient = createPublicClient({...});
 * const walletClient = createWalletClient({...});
 *
 * // Execute a swap
 * await swap(publicClient, walletClient, BAMM_ABI, {
 *   poolAddress: '0x...',
 *   tokenIn: '0x...',
 *   tokenOut: '0x...',
 *   amountIn: 1000000n,
 *   slippageBps: 50, // 0.5%
 * });
 * ```
 *
 * @example Oracle keeper
 * ```ts
 * import { BinanceOracle } from '@btr/dex-sdk/oracles';
 * import { BAMM_ABI } from '@btr/dex-sdk/abis';
 *
 * const oracle = new BinanceOracle(publicClient, walletClient, {
 *   poolAddress: '0x...',
 *   assets: [
 *     { address: '0x...', symbol: 'ETH', decimals: 18 },
 *     { address: '0x...', symbol: 'USDC', decimals: 6 },
 *   ],
 *   updateInterval: 60000, // 1 minute
 *   divergenceThreshold: 50, // 0.5%
 * }, BAMM_ABI);
 *
 * await oracle.start();
 * ```
 *
 * @example Circuit breaker guardian
 * ```ts
 * import { CircuitBreakerGuardian } from '@btr/dex-sdk/guardians';
 * import { BAMM_ABI } from '@btr/dex-sdk/abis';
 *
 * const guardian = new CircuitBreakerGuardian(publicClient, walletClient, {
 *   poolAddress: '0x...',
 *   assets: [
 *     {
 *       address: '0x...USDC',
 *       name: 'USDC',
 *       referenceAsset: '0x...DAI',
 *       maxDivergence: 100, // 1%
 *     },
 *   ],
 *   checkInterval: 300000, // 5 minutes
 * }, BAMM_ABI, oracleProvider);
 *
 * await guardian.start();
 * ```
 *
 * @example DarkPool private transfer
 * ```ts
 * import { Note, MerkleTree, ProofBuilder } from '@btr/dex-sdk/darkpool';
 *
 * // Create a note
 * const note = Note.createRandom(amount);
 *
 * // Deposit
 * const commitment = note.getCommitment();
 * await darkpool.deposit(commitment, note.encrypt());
 *
 * // Later: withdraw privately
 * const proof = await ProofBuilder.buildWithdrawProof(note, merkleTree);
 * await darkpool.withdraw(proof, ...);
 * ```
 *
 * @module @btr/dex-sdk
 */

// Re-export everything from submodules for convenience
export * from './common/index.js';
export * from './abis/index.js';
export * from './flows/index.js';
export * from './darkpool/index.js';
export * from './circuits/index.js';
export * from './oracles/index.js';
export * from './guardians/index.js';

/**
 * BTR DEX SDK
 * Modular SDK for interacting with BTR DEX - supports AMM flows, oracles, and guardians
 *
 * @example Basic usage with EIP-1193 provider
 * ```ts
 * import { deposit, swap, withdraw } from '@btr/dex-sdk/flows';
 * import { AIMM_ABI } from '@btr/dex-sdk/abis';
 * import { encodeFunctionData } from '@btr/dex-sdk';
 *
 * const provider = window.ethereum; // EIP-1193 provider
 *
 * // Execute a swap
 * await swap(provider, AIMM_ABI, {
 *   poolAddress: '0x...',
 *   tokenIn: '0x...',
 *   tokenOut: '0x...',
 *   amountIn: 1000000n,
 *   slippageBps: 50, // 0.5%
 * });
 * ```
 *
 * @example Oracle keeper (backend)
 * ```ts
 * import { BinanceOracle } from '@btr/dex-sdk/oracles';
 * import { AIMM_ABI } from '@btr/dex-sdk/abis';
 *
 * const provider = createJsonRpcProvider('https://...');
 *
 * const oracle = new BinanceOracle(provider, {
 *   poolAddress: '0x...',
 *   assets: [
 *     { address: '0x...', symbol: 'ETH', decimals: 18 },
 *     { address: '0x...', symbol: 'USDC', decimals: 6 },
 *   ],
 *   divergenceThreshold: 50, // 0.5%
 * }, AIMM_ABI);
 *
 * await oracle.start();
 * ```
 *
 * @example Circuit breaker guardian (backend)
 * ```ts
 * import { CircuitBreakerGuardian } from '@btr/dex-sdk/guardians';
 * import { AIMM_ABI } from '@btr/dex-sdk/abis';
 *
 * const guardian = new CircuitBreakerGuardian(provider, {
 *   poolAddress: '0x...',
 *   assets: [...],
 *   maxDivergence: 100, // 1%
 * }, AIMM_ABI);
 *
 * await guardian.start();
 * ```
 *
 * @module @btr/dex-sdk
 */

// Re-export everything from submodules for convenience
export * from './utils/index.js';
export * from './abis/index.js';
export * from './flows/index.js';
export * from './oracles/index.js';
export * from './guardians/index.js';

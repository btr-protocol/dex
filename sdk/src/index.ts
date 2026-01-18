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

// Re-export from utils (excluding types that conflict with pool module)
export {
  BPS_PRECISION,
  PRECISION_1E18,
  PRECISION_1E8,
  DEFAULT_GAS_LIMIT,
  SWAP_GAS_LIMIT,
  DEPOSIT_GAS_LIMIT,
  WITHDRAW_GAS_LIMIT,
  ONE_MINUTE,
  FIVE_MINUTES,
  ONE_HOUR,
  ONE_DAY,
  DEFAULT_ORACLE_STALENESS,
  DEFAULT_PRICE_DIVERGENCE_BPS,
  DEFAULT_CB_CHECK_INTERVAL,
  DEFAULT_CB_COOLDOWN,
  SUPPORTED_CHAINS,
  type TokenAddress,
  type PoolAddress,
  type TokenInfo,
  type OraclePrice,
  type CircuitBreakerConfig,
  type GuardianConfig,
} from './utils/constants.js';
export * from './utils/typing.js';
export * from './utils/safe.js';
export * from './utils/validation.js';
export * from './utils/business.js';
export * from './utils/maths.js';
export * from './utils/format.js';
export * from './utils/encoding.js';

// ABIs (excluding POOL_ABI which is superseded by pool module)
export { AIMM_ABI } from './abis/AIMM.js';
export { DARKPOOL_ABI } from './abis/DarkPool.js';

// Oracles and Guardians
export * from './oracles/index.js';
export * from './guardians/index.js';

// Pool data and transactions (canonical source for POOL_ABI, SwapQuote, PoolAsset)
export * from './pool/index.js';

// Eth utilities and clients
export * from './eth/index.js';
export type { Client } from './eth/client.js';
export {
  createWalletClient,
  createPublicClient,
  createHttpProvider,
  createPrivateKeyClient,
  privateKeyToAddress,
} from './eth/client.js';

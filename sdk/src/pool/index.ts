/**
 * Pool Module - On-chain data fetching and transaction execution
 * Works in both frontend (with injected wallet) and backend (with private key)
 */

import { encodeFn, decodeFn } from '../eth/abi';
import type { Address, Hex, Eip1193Provider } from '../eth/types';

// ─────────────────────────────────────────────────────────────
// Pool ABI (View Functions Only)
// ─────────────────────────────────────────────────────────────

export const POOL_ABI = [
  {
    type: 'function',
    name: 'getAsset',
    stateMutability: 'view',
    inputs: [{ name: 'token', type: 'address' }],
    outputs: [
      {
        name: '',
        type: 'tuple',
        components: [
          { name: 'reserves', type: 'uint128' },
          { name: 'liabilities', type: 'uint128' },
          { name: 'minLiquidity', type: 'uint128' },
          { name: 'liquidityIndex', type: 'uint64' },
          { name: 'lastUpdate', type: 'uint32' },
          { name: 'minDispersion', type: 'uint32' },
          { name: 'anchor', type: 'address' },
          { name: 'minFeeBps', type: 'uint16' },
          { name: 'maxFeeBps', type: 'uint16' },
          { name: 'maxDispersion', type: 'uint32' },
          { name: 'anchorDepth', type: 'uint8' },
          { name: 'decimals', type: 'uint8' },
          { name: '_pad1', type: 'uint8[2]' },
          { name: 'gamma', type: 'uint16' },
          { name: 'vega', type: 'uint16' },
          { name: 'lambda', type: 'uint16' },
          { name: 'haircutSuppressor', type: 'uint16' },
          { name: 'reservationPrice', type: 'uint64' },
          { name: '_pad2', type: 'uint8[16]' },
        ],
      },
    ],
  },
  {
    type: 'function',
    name: 'getCoverageRatio',
    stateMutability: 'view',
    inputs: [{ name: 'token', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'getLPBalance',
    stateMutability: 'view',
    inputs: [
      { name: 'user', type: 'address' },
      { name: 'token', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'getProtocolFees',
    stateMutability: 'view',
    inputs: [{ name: 'token', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'baseToken',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'address' }],
  },
  {
    type: 'function',
    name: 'getMidPrice',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'token', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'getSwapQuote',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'tokenIn', type: 'address' },
      { name: 'tokenOut', type: 'address' },
      { name: 'amountIn', type: 'uint256' },
    ],
    outputs: [
      {
        name: 'quote',
        type: 'tuple',
        components: [
          { name: 'amountOut', type: 'uint256' },
          { name: 'amountIn', type: 'uint256' },
          { name: 'spreadBps', type: 'uint16' },
          { name: 'protoFee', type: 'uint256' },
          { name: 'lpFee', type: 'uint256' },
          { name: 'skewIn', type: 'int8' },
          { name: 'skewOut', type: 'int8' },
          { name: 'routeHops', type: 'address[]' },
          { name: 'hopAmounts', type: 'uint256[]' },
        ],
      },
    ],
  },
] as const;

// ─────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────

export interface Asset {
  reserves: bigint;
  liabilities: bigint;
  minLiquidity: bigint;
  liquidityIndex: bigint;
  lastUpdate: number;
  minDispersion: number;
  anchor: Address;
  minFeeBps: number;
  maxFeeBps: number;
  maxDispersion: number;
  anchorDepth: number;
  decimals: number;
  gamma: number;
  vega: number;
  lambda: number;
  haircutSuppressor: number;
  reservationPrice: bigint;
}

export interface SwapQuote {
  amountOut: bigint;
  amountIn: bigint;
  spreadBps: number;
  protoFee: bigint;
  lpFee: bigint;
  skewIn: number;
  skewOut: number;
  routeHops: Address[];
  hopAmounts: bigint[];
}

export interface PoolAsset {
  token: Address;
  symbol: string;
  name: string;
  decimals: number;
  reserves: bigint;
  liabilities: bigint;
  coverage: bigint;
}

export interface PoolData {
  address: Address;
  name: string;
  assets: PoolAsset[];
}

// ─────────────────────────────────────────────────────────────
// Pool Data Fetching
// ─────────────────────────────────────────────────────────────

/**
 * Fetch asset data from pool contract
 */
export async function getAsset(
  provider: Eip1193Provider,
  poolAddress: Address,
  tokenAddress: Address
): Promise<Asset> {
  const calldata = encodeFn({ abi: POOL_ABI, functionName: 'getAsset', args: [tokenAddress] });

  const result = (await provider.request({
    method: 'eth_call',
    params: [{ to: poolAddress, data: calldata }, 'latest'],
  })) as Hex;

  return decodeFn({ abi: POOL_ABI, functionName: 'getAsset', data: result });
}

/**
 * Fetch coverage ratio for an asset
 */
export async function getCoverageRatio(
  provider: Eip1193Provider,
  poolAddress: Address,
  tokenAddress: Address
): Promise<bigint> {
  const calldata = encodeFn({ abi: POOL_ABI, functionName: 'getCoverageRatio', args: [tokenAddress] });

  const result = (await provider.request({
    method: 'eth_call',
    params: [{ to: poolAddress, data: calldata }, 'latest'],
  })) as Hex;

  return decodeFn({ abi: POOL_ABI, functionName: 'getCoverageRatio', data: result });
}

/**
 * Fetch LP balance for a user
 */
export async function getLPBalance(
  provider: Eip1193Provider,
  poolAddress: Address,
  userAddress: Address,
  tokenAddress: Address
): Promise<bigint> {
  const calldata = encodeFn({ abi: POOL_ABI, functionName: 'getLPBalance', args: [userAddress, tokenAddress] });

  const result = (await provider.request({
    method: 'eth_call',
    params: [{ to: poolAddress, data: calldata }, 'latest'],
  })) as Hex;

  return decodeFn({ abi: POOL_ABI, functionName: 'getLPBalance', data: result });
}

/**
 * Fetch swap quote
 */
export async function getSwapQuote(
  provider: Eip1193Provider,
  poolAddress: Address,
  tokenIn: Address,
  tokenOut: Address,
  amountIn: bigint
): Promise<SwapQuote> {
  const calldata = encodeFn({ abi: POOL_ABI, functionName: 'getSwapQuote', args: [tokenIn, tokenOut, amountIn] });

  const result = (await provider.request({
    method: 'eth_call',
    params: [{ to: poolAddress, data: calldata }, 'latest'],
  })) as Hex;

  return decodeFn({ abi: POOL_ABI, functionName: 'getSwapQuote', data: result });
}

/**
 * Fetch complete pool data for multiple assets
 */
export async function getPoolData(
  provider: Eip1193Provider,
  poolAddress: Address,
  tokens: Array<{ address: Address; symbol: string; name: string }>,
  poolName: string
): Promise<PoolData> {
  const assets: PoolAsset[] = [];

  for (const token of tokens) {
    const [asset, coverage] = await Promise.all([
      getAsset(provider, poolAddress, token.address),
      getCoverageRatio(provider, poolAddress, token.address),
    ]);

    assets.push({
      token: token.address,
      symbol: token.symbol,
      name: token.name,
      decimals: Number(asset.decimals),
      reserves: asset.reserves,
      liabilities: asset.liabilities,
      coverage,
    });
  }

  return {
    address: poolAddress,
    name: poolName,
    assets,
  };
}

// ─────────────────────────────────────────────────────────────
// Transaction Functions
// ─────────────────────────────────────────────────────────────

// Transaction ABIs
const SWAP_ABI = [
  {
    type: 'function',
    name: 'swap',
    stateMutability: 'payable',
    inputs: [
      { name: 'tokenIn', type: 'address' },
      { name: 'tokenOut', type: 'address' },
      { name: 'amountIn', type: 'uint256' },
      { name: 'minAmountOut', type: 'uint256' },
      { name: 'recipient', type: 'address' },
    ],
    outputs: [{ name: 'amountOut', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'deposit',
    stateMutability: 'payable',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [
      {
        name: 'result',
        type: 'tuple',
        components: [
          { name: 'lpAmount', type: 'uint256' },
          { name: 'actualDeposit', type: 'uint256' },
        ],
      },
    ],
  },
  {
    type: 'function',
    name: 'withdraw',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'lpAmount', type: 'uint256' },
      { name: 'minAmountOut', type: 'uint256' },
    ],
    outputs: [
      {
        name: 'result',
        type: 'tuple',
        components: [
          { name: 'amountOut', type: 'uint256' },
          { name: 'lpBurned', type: 'uint256' },
        ],
      },
    ],
  },
] as const;

export interface SwapParams {
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;
  minAmountOut: bigint;
  recipient: Address;
}

export interface DepositParams {
  token: Address;
  amount: bigint;
}

export interface WithdrawParams {
  token: Address;
  lpAmount: bigint;
  minAmountOut: bigint;
}

/**
 * Execute a swap transaction
 * NB: Caller must approve tokenIn to poolAddress before calling
 */
export async function swap(
  provider: Eip1193Provider,
  poolAddress: Address,
  params: SwapParams
): Promise<Hex> {
  const calldata = encodeFn({
    abi: SWAP_ABI,
    functionName: 'swap',
    args: [params.tokenIn, params.tokenOut, params.amountIn, params.minAmountOut, params.recipient],
  });

  // Send transaction (provider must support eth_sendTransaction)
  return (await provider.request({
    method: 'eth_sendTransaction',
    params: [
      {
        to: poolAddress,
        data: calldata,
        value: '0x0', // TODO: Handle native token swaps
      },
    ],
  })) as Hex;
}

/**
 * Execute a deposit transaction
 * NB: Caller must approve token to poolAddress before calling
 */
export async function deposit(
  provider: Eip1193Provider,
  poolAddress: Address,
  params: DepositParams
): Promise<Hex> {
  const calldata = encodeFn({
    abi: SWAP_ABI,
    functionName: 'deposit',
    args: [params.token, params.amount],
  });

  return (await provider.request({
    method: 'eth_sendTransaction',
    params: [
      {
        to: poolAddress,
        data: calldata,
        value: '0x0',
      },
    ],
  })) as Hex;
}

/**
 * Execute a withdraw transaction
 */
export async function withdraw(
  provider: Eip1193Provider,
  poolAddress: Address,
  params: WithdrawParams
): Promise<Hex> {
  const calldata = encodeFn({
    abi: SWAP_ABI,
    functionName: 'withdraw',
    args: [params.token, params.lpAmount, params.minAmountOut],
  });

  return (await provider.request({
    method: 'eth_sendTransaction',
    params: [
      {
        to: poolAddress,
        data: calldata,
        value: '0x0',
      },
    ],
  })) as Hex;
}

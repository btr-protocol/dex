/**
 * Pool Contract ABI
 * @module @btr/dex-sdk/abis
 *
 * Minimal ABI for swap operations - only includes required functions
 */

export const POOL_ABI = [
  {
    type: 'function',
    name: 'getSwapQuote',
    stateMutability: 'view',
    inputs: [
      { name: 'tokenIn', type: 'address' },
      { name: 'tokenOut', type: 'address' },
      { name: 'amountIn', type: 'uint256' },
    ],
    outputs: [
      {
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
  {
    type: 'function',
    name: 'swap',
    stateMutability: 'nonpayable',
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
    name: 'getMidPrice',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'token', type: 'address' }],
    outputs: [{ name: 'midPrice', type: 'uint256' }],
  },
] as const;

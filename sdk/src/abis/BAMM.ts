/**
 * AIMM Contract ABI
 * @module @btr/dex-sdk/abis
 *
 * To regenerate: run `forge build` in contracts/ then `bun run generate-abis`
 */

export const AIMM_ABI = [
  // Core functions
  {
    type: 'function',
    name: 'deposit',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'amount', type: 'uint256' },
      { name: 'minLpTokens', type: 'uint256' },
    ],
    outputs: [{ name: 'lpTokens', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'withdraw',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'lpTokens', type: 'uint256' },
      { name: 'minAmount', type: 'uint256' },
    ],
    outputs: [{ name: 'amount', type: 'uint256' }],
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
      { name: 'data', type: 'bytes' },
    ],
    outputs: [{ name: 'amountOut', type: 'uint256' }],
  },
  // View functions
  {
    type: 'function',
    name: 'assets',
    stateMutability: 'view',
    inputs: [{ name: 'token', type: 'address' }],
    outputs: [
      {
        type: 'tuple',
        components: [
          { name: 'reserves', type: 'uint128' },
          { name: 'fastTWAP', type: 'uint64' },
          { name: 'slowTWAP', type: 'uint64' },
          { name: 'fastVolatility', type: 'uint32' },
          { name: 'slowVolatility', type: 'uint32' },
          { name: 'targetAllocation', type: 'uint16' },
          { name: 'segments', type: 'uint8' },
          { name: 'isActive', type: 'bool' },
          { name: 'isPaused', type: 'bool' },
          { name: 'isFrozen', type: 'bool' },
          { name: 'hooks', type: 'address' },
          { name: 'lastOracleUpdate', type: 'uint32' },
        ],
      },
    ],
  },
  {
    type: 'function',
    name: 'totalSupply',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'balanceOf',
    stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  // Guardian functions
  {
    type: 'function',
    name: 'checkCircuitBreaker',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'token', type: 'address' }],
    outputs: [],
  },
  {
    type: 'function',
    name: 'push',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'newPrice', type: 'uint64' },
      { name: 'newVolatility', type: 'uint32' },
    ],
    outputs: [],
  },
  // Events
  {
    type: 'event',
    name: 'Deposit',
    inputs: [
      { name: 'token', type: 'address', indexed: true },
      { name: 'depositor', type: 'address', indexed: true },
      { name: 'amount', type: 'uint256', indexed: false },
      { name: 'lpTokens', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'Withdraw',
    inputs: [
      { name: 'token', type: 'address', indexed: true },
      { name: 'withdrawer', type: 'address', indexed: true },
      { name: 'lpTokens', type: 'uint256', indexed: false },
      { name: 'amount', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'Swap',
    inputs: [
      { name: 'tokenIn', type: 'address', indexed: true },
      { name: 'tokenOut', type: 'address', indexed: true },
      { name: 'trader', type: 'address', indexed: true },
      { name: 'amountIn', type: 'uint256', indexed: false },
      { name: 'amountOut', type: 'uint256', indexed: false },
    ],
  },
] as const;

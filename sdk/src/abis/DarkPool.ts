/**
 * DarkPool Contract ABI
 * @module @btr/dex-sdk/abis
 *
 * To regenerate: run `forge build` in contracts/ then `bun run generate-abis`
 */

export const DARKPOOL_ABI = [
  {
    type: 'function',
    name: 'deposit',
    stateMutability: 'payable',
    inputs: [
      { name: 'commitment', type: 'bytes32' },
      { name: 'encryptedNote', type: 'bytes' },
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'withdraw',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'proof', type: 'bytes' },
      { name: 'root', type: 'bytes32' },
      { name: 'nullifierHash', type: 'bytes32' },
      { name: 'recipient', type: 'address' },
      { name: 'relayer', type: 'address' },
      { name: 'fee', type: 'uint256' },
      { name: 'refund', type: 'uint256' },
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'isSpent',
    stateMutability: 'view',
    inputs: [{ name: 'nullifierHash', type: 'bytes32' }],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    type: 'function',
    name: 'isKnownRoot',
    stateMutability: 'view',
    inputs: [{ name: 'root', type: 'bytes32' }],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    type: 'function',
    name: 'getLastRoot',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'bytes32' }],
  },
  {
    type: 'event',
    name: 'Deposit',
    inputs: [
      { name: 'commitment', type: 'bytes32', indexed: true },
      { name: 'leafIndex', type: 'uint32', indexed: false },
      { name: 'timestamp', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'Withdrawal',
    inputs: [
      { name: 'to', type: 'address', indexed: false },
      { name: 'nullifierHash', type: 'bytes32', indexed: true },
      { name: 'relayer', type: 'address', indexed: true },
      { name: 'fee', type: 'uint256', indexed: false },
    ],
  },
] as const;

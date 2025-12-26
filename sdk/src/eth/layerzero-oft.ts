/**
 * LayerZero Omnichain Fungible Token (OFT) Standard
 * Inherits from ERC-20 with cross-chain capabilities
 * https://docs.layerzero.network/v2/home/token-standards/oft-standard
 */

import type { Abi } from './abi.js';
import { ERC20_ABI } from './erc20.js';

export const LAYERZERO_OFT_ABI: Abi = [
  // Inherits all ERC-20 functions
  ...ERC20_ABI,

  // ========== LayerZero OFT Core Functions ==========
  {
    name: 'send',
    type: 'function',
    stateMutability: 'payable',
    inputs: [
      {
        name: '_sendParam',
        type: 'tuple',
        components: [
          { name: 'dstEid', type: 'uint32' },
          { name: 'to', type: 'bytes32' },
          { name: 'amountLD', type: 'uint256' },
          { name: 'minAmountLD', type: 'uint256' },
          { name: 'extraOptions', type: 'bytes' },
          { name: 'composeMsg', type: 'bytes' },
          { name: 'oftCmd', type: 'bytes' },
        ],
      },
      {
        name: '_fee',
        type: 'tuple',
        components: [
          { name: 'nativeFee', type: 'uint256' },
          { name: 'lzTokenFee', type: 'uint256' },
        ],
      },
      { name: '_refundAddress', type: 'address' },
    ],
    outputs: [
      {
        name: 'msgReceipt',
        type: 'tuple',
        components: [
          { name: 'guid', type: 'bytes32' },
          { name: 'nonce', type: 'uint64' },
          {
            name: 'fee',
            type: 'tuple',
            components: [
              { name: 'nativeFee', type: 'uint256' },
              { name: 'lzTokenFee', type: 'uint256' },
            ],
          },
        ],
      },
      {
        name: 'oftReceipt',
        type: 'tuple',
        components: [
          { name: 'amountSentLD', type: 'uint256' },
          { name: 'amountReceivedLD', type: 'uint256' },
        ],
      },
    ],
  },
  {
    name: 'quoteSend',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      {
        name: '_sendParam',
        type: 'tuple',
        components: [
          { name: 'dstEid', type: 'uint32' },
          { name: 'to', type: 'bytes32' },
          { name: 'amountLD', type: 'uint256' },
          { name: 'minAmountLD', type: 'uint256' },
          { name: 'extraOptions', type: 'bytes' },
          { name: 'composeMsg', type: 'bytes' },
          { name: 'oftCmd', type: 'bytes' },
        ],
      },
      { name: '_payInLzToken', type: 'bool' },
    ],
    outputs: [
      {
        name: 'fee',
        type: 'tuple',
        components: [
          { name: 'nativeFee', type: 'uint256' },
          { name: 'lzTokenFee', type: 'uint256' },
        ],
      },
    ],
  },

  // ========== OFT Configuration ==========
  {
    name: 'token',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'address' }],
  },
  {
    name: 'approvalRequired',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    name: 'sharedDecimals',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint8' }],
  },

  // ========== OFT Events ==========
  {
    name: 'OFTSent',
    type: 'event',
    inputs: [
      { name: 'guid', type: 'bytes32', indexed: true },
      { name: 'dstEid', type: 'uint32', indexed: false },
      { name: 'from', type: 'address', indexed: true },
      { name: 'amountSentLD', type: 'uint256', indexed: false },
      { name: 'amountReceivedLD', type: 'uint256', indexed: false },
    ],
  },
  {
    name: 'OFTReceived',
    type: 'event',
    inputs: [
      { name: 'guid', type: 'bytes32', indexed: true },
      { name: 'srcEid', type: 'uint32', indexed: false },
      { name: 'to', type: 'address', indexed: true },
      { name: 'amountReceivedLD', type: 'uint256', indexed: false },
    ],
  },
];

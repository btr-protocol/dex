/**
 * ERC-7540 Asynchronous Tokenized Vault Standard
 * Extends ERC-4626 for async deposit/redeem operations
 * https://eips.ethereum.org/EIPS/eip-7540
 */

import type { Abi } from './abi.js';
import { ERC4626_ABI } from './erc4626.js';

export const ERC7540_ABI: Abi = [
  // Inherits all ERC-4626 functions (which includes ERC-20)
  ...ERC4626_ABI,

  // ========== ERC-7540 Request Functions ==========
  {
    name: 'requestDeposit',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'assets', type: 'uint256' },
      { name: 'controller', type: 'address' },
      { name: 'owner', type: 'address' },
    ],
    outputs: [{ name: 'requestId', type: 'uint256' }],
  },
  {
    name: 'requestRedeem',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'shares', type: 'uint256' },
      { name: 'controller', type: 'address' },
      { name: 'owner', type: 'address' },
    ],
    outputs: [{ name: 'requestId', type: 'uint256' }],
  },

  // ========== ERC-7540 Pending Request Info ==========
  {
    name: 'pendingDepositRequest',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'requestId', type: 'uint256' },
      { name: 'controller', type: 'address' },
    ],
    outputs: [
      { name: 'pendingAssets', type: 'uint256' },
      { name: 'claimableShares', type: 'uint256' },
    ],
  },
  {
    name: 'pendingRedeemRequest',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'requestId', type: 'uint256' },
      { name: 'controller', type: 'address' },
    ],
    outputs: [
      { name: 'pendingShares', type: 'uint256' },
      { name: 'claimableAssets', type: 'uint256' },
    ],
  },

  // ========== ERC-7540 Claimable Amounts ==========
  {
    name: 'claimableDepositRequest',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'requestId', type: 'uint256' },
      { name: 'controller', type: 'address' },
    ],
    outputs: [{ name: 'claimableShares', type: 'uint256' }],
  },
  {
    name: 'claimableRedeemRequest',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'requestId', type: 'uint256' },
      { name: 'controller', type: 'address' },
    ],
    outputs: [{ name: 'claimableAssets', type: 'uint256' }],
  },

  // ========== ERC-7540 Events ==========
  {
    name: 'DepositRequest',
    type: 'event',
    inputs: [
      { name: 'requestId', type: 'uint256', indexed: true },
      { name: 'controller', type: 'address', indexed: true },
      { name: 'owner', type: 'address', indexed: true },
      { name: 'assets', type: 'uint256', indexed: false },
    ],
  },
  {
    name: 'RedeemRequest',
    type: 'event',
    inputs: [
      { name: 'requestId', type: 'uint256', indexed: true },
      { name: 'controller', type: 'address', indexed: true },
      { name: 'owner', type: 'address', indexed: true },
      { name: 'shares', type: 'uint256', indexed: false },
    ],
  },
];

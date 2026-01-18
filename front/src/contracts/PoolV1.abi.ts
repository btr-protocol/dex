/**
 * Pool V1 Contract ABI
 * Minimal ABI for view functions needed by the frontend
 */

export const POOL_V1_ABI = [
  // View functions
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
    name: 'getMidPrice',
    stateMutability: 'nonpayable',
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
] as const;

// TypeScript types for contract data
export interface AssetData {
  reserves: bigint;
  liabilities: bigint;
  minLiquidity: bigint;
  liquidityIndex: bigint;
  lastUpdate: number;
  minDispersion: number;
  anchor: string;
  minFeeBps: number;
  maxFeeBps: number;
  maxDispersion: number;
  anchorDepth: number;
  decimals: number;
  _pad1: [number, number];
  gamma: number;
  vega: number;
  lambda: number;
  haircutSuppressor: number;
  reservationPrice: bigint;
  _pad2: number[];
}

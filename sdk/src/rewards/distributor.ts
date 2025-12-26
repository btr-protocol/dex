/**
 * Reward distribution generator
 * Combines earning power calculation with Merkle tree generation
 */

import type { Address, Hex } from '../eth/index.js';
import { buildDistribution, type MerkleLeaf, type DistributionData } from './merkle.js';
import { computeDistribution, type UserStake, type PoolWeight } from './earning-power.js';

/**
 * Epoch configuration
 */
export type EpochConfig = {
  epochId: number;
  rewardToken: Address;
  totalRewards: bigint;     // Total tokens to distribute
  startTime: number;        // Unix timestamp
  endTime: number;          // Unix timestamp
};

/**
 * Complete distribution for an epoch
 */
export type EpochDistribution = {
  config: EpochConfig;
  merkleRoot: Hex;
  totalAmount: bigint;
  claims: {
    user: Address;
    index: number;
    amount: bigint;
    proof: Hex[];
  }[];
};

/**
 * Generate reward distribution for an epoch
 * Allocates rewards proportionally to earning power
 */
export function generateEpochDistribution(
  config: EpochConfig,
  users: UserStake[],
  poolWeights: Map<Address, number>
): EpochDistribution {
  // Compute earning power for each user
  const earningPowers = computeDistribution(users, poolWeights);

  // Calculate total earning power
  const totalEarningPower = Array.from(earningPowers.values()).reduce(
    (sum, power) => sum + power,
    0n
  );

  if (totalEarningPower === 0n) {
    // No one has earning power - return empty distribution
    return {
      config,
      merkleRoot: '0x' as Hex,
      totalAmount: 0n,
      claims: [],
    };
  }

  // Allocate rewards proportionally
  const entries: MerkleLeaf[] = [];
  let index = 0;

  for (const [user, power] of earningPowers.entries()) {
    if (power === 0n) continue;

    // User's share: (power / totalPower) * totalRewards
    const amount = (power * config.totalRewards) / totalEarningPower;

    if (amount > 0n) {
      entries.push({ index, account: user, amount });
      index++;
    }
  }

  // Build Merkle tree
  const distribution = buildDistribution(entries);

  // Format claims
  const claims = distribution.entries.map(entry => ({
    user: entry.account as Address,
    index: entry.index,
    amount: entry.amount,
    proof: entry.proof,
  }));

  return {
    config,
    merkleRoot: distribution.root,
    totalAmount: distribution.totalAmount,
    claims,
  };
}

/**
 * Generate distributions for multiple epochs/tokens
 */
export function generateMultiEpochDistribution(
  epochs: EpochConfig[],
  users: UserStake[],
  poolWeights: Map<Address, number>
): EpochDistribution[] {
  return epochs.map(config => generateEpochDistribution(config, users, poolWeights));
}

/**
 * Export distribution in JSON format for indexer/frontend
 */
export type ExportedDistribution = {
  epochId: number;
  rewardToken: string;
  merkleRoot: string;
  totalAmount: string;
  totalRewards: string;
  startTime: number;
  endTime: number;
  claims: {
    user: string;
    index: number;
    amount: string;
    proof: string[];
  }[];
};

export function exportDistribution(dist: EpochDistribution): ExportedDistribution {
  return {
    epochId: dist.config.epochId,
    rewardToken: dist.config.rewardToken,
    merkleRoot: dist.merkleRoot,
    totalAmount: dist.totalAmount.toString(),
    totalRewards: dist.config.totalRewards.toString(),
    startTime: dist.config.startTime,
    endTime: dist.config.endTime,
    claims: dist.claims.map(c => ({
      user: c.user,
      index: c.index,
      amount: c.amount.toString(),
      proof: c.proof,
    })),
  };
}

/**
 * Find user's claim in a distribution
 */
export function findUserClaim(
  dist: EpochDistribution,
  user: Address
): typeof dist.claims[0] | undefined {
  return dist.claims.find(c => c.user.toLowerCase() === user.toLowerCase());
}

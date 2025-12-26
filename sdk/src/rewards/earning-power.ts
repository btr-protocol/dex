/**
 * Off-chain earning power calculator
 * Aggregates stake from all chains and computes boosted LP allocation
 */

import type { Address } from '../eth/index.js';

/**
 * Earning power suppression constants (quadratic damping)
 * Suppression formula: y(S) = 1 - scale * S^exponent
 * Higher earning power → greater suppression (concave curve)
 */
const earningsFactor = 0.00548;     // Scale factor ≈ 5.48×10^-3
const earningSuppressor = 0.265;    // Power exponent (concave: 0 < b < 1)

/**
 * Apply earning power suppression to linear power
 * Formula: S_eff = S · (1 - scale * S^exponent)
 * Creates concave curve that reduces allocation to large positions
 * @param linearPower Linear earning power (dollar-equivalent)
 * @returns Suppressed effective earning power
 */
export function applyDamping(linearPower: bigint): bigint {
  if (linearPower === 0n) return 0n;

  // Convert to float for calculation (S is in dollars, no decimals)
  const S = Number(linearPower);

  // Calculate suppression factor: y(S) = 1 - scale*S^exponent
  const suppressionFactor = 1 - earningsFactor * Math.pow(S, earningSuppressor);

  // Ensure suppression factor is non-negative
  const clampedFactor = Math.max(0, suppressionFactor);

  // S_eff = S * y(S)
  const effectivePower = S * clampedFactor;

  return BigInt(Math.floor(effectivePower));
}

/**
 * Pool-level config for earning weights
 */
export type PoolWeight = {
  pool: Address;
  weight: number; // Computed from utilization + coverage ratio
};

/**
 * User's staking position (aggregated across all chains)
 */
export type UserStake = {
  user: Address;
  govValue: bigint;  // $ value of staked BTR (18 decimals)
  lpPositions: {
    pool: Address;
    value: bigint;   // $ value of LP in this pool (18 decimals)
  }[];
};

/**
 * Result of earning power calculation
 */
export type EarningPower = {
  user: Address;
  totalEarningPower: bigint; // Total earning weight (18 decimals)
  boostedPositions: {
    pool: Address;
    baseLP: bigint;      // Original LP value
    boostedLP: bigint;   // After boost allocation
    poolWeight: number;
    contribution: bigint; // w_p * boostedLP
  }[];
};

/**
 * Compute earning power for a single user
 * Formula: E_u = Σ_p (w_p · boostedLP_u,p)
 * where boostedLP = min(L_u, 5*G_u) distributed pro-rata by pool weight
 */
export function computeEarningPower(
  user: UserStake,
  poolWeights: Map<Address, number>
): EarningPower {
  const G = user.govValue; // BTR value
  const totalLP = user.lpPositions.reduce((sum, pos) => sum + pos.value, 0n);

  // Boost capacity: 5G
  const boostCap = G * 5n;

  // Total boost to distribute: min(totalLP, 5G)
  const totalBoost = totalLP < boostCap ? totalLP : boostCap;

  // Sort pools by weight (descending) to allocate boost to highest-weight pools first
  const sortedPositions = user.lpPositions
    .map(pos => ({
      ...pos,
      weight: poolWeights.get(pos.pool.toLowerCase() as Address) || 0,
    }))
    .sort((a, b) => b.weight - a.weight);

  // Allocate boost pro-rata by pool weight
  let remainingBoost = totalBoost;
  const boostedPositions = sortedPositions.map(pos => {
    const baseLP = pos.value;

    // This pool gets boost proportional to its weight
    // Simple pro-rata: boost allocated = (pos.weight / sum_weights) * totalBoost
    const totalWeight = sortedPositions.reduce((sum, p) => sum + p.weight, 0);
    const poolBoostShare = totalWeight > 0
      ? (totalBoost * BigInt(Math.floor(pos.weight * 1e18)) / BigInt(Math.floor(totalWeight * 1e18)))
      : 0n;

    // Capped at base LP value (can't boost more than you have)
    const boost = poolBoostShare < baseLP ? poolBoostShare : baseLP;
    const boostedLP = baseLP + boost;

    // Contribution to earning power: w_p * boostedLP
    const contribution = (boostedLP * BigInt(Math.floor(pos.weight * 1e18))) / 1_000_000_000_000_000_000n;

    return {
      pool: pos.pool,
      baseLP,
      boostedLP,
      poolWeight: pos.weight,
      contribution,
    };
  });

  const totalEarningPower = boostedPositions.reduce((sum, pos) => sum + pos.contribution, 0n);

  return {
    user: user.user,
    totalEarningPower,
    boostedPositions,
  };
}

/**
 * Compute pool weights from utilization and coverage ratios
 * Higher weight = more incentives needed (high utilization + low coverage)
 *
 * Simple heuristic:
 * w_p = utilization_p * (1 / coverage_p)
 *
 * Normalize so sum(w_p) = 1
 */
export function computePoolWeights(pools: {
  pool: Address;
  utilization: number;  // 0-1 (e.g., 0.8 = 80% utilization)
  coverage: number;     // 0-inf (e.g., 1.2 = 120% coverage)
}[]): Map<Address, number> {
  // Calculate raw weights
  const rawWeights = pools.map(p => ({
    pool: p.pool,
    weight: p.utilization / p.coverage, // High util + low coverage = high weight
  }));

  // Normalize
  const totalWeight = rawWeights.reduce((sum, p) => sum + p.weight, 0);
  const normalized = rawWeights.map(p => ({
    pool: p.pool,
    weight: totalWeight > 0 ? p.weight / totalWeight : 0,
  }));

  return new Map(normalized.map(p => [p.pool.toLowerCase() as Address, p.weight]));
}

/**
 * Aggregate user stakes across multiple chains
 */
export function aggregateUserStakes(
  perChainStakes: Map<number, UserStake[]> // chainId => stakes
): UserStake[] {
  const userMap = new Map<Address, UserStake>();

  for (const stakes of perChainStakes.values()) {
    for (const stake of stakes) {
      const key = stake.user.toLowerCase() as Address;
      const existing = userMap.get(key);

      if (existing) {
        // Aggregate BTR value
        existing.govValue += stake.govValue;

        // Aggregate LP positions by pool
        for (const pos of stake.lpPositions) {
          const existingPos = existing.lpPositions.find(
            p => p.pool.toLowerCase() === pos.pool.toLowerCase()
          );
          if (existingPos) {
            existingPos.value += pos.value;
          } else {
            existing.lpPositions.push({ ...pos });
          }
        }
      } else {
        userMap.set(key, {
          user: key,
          govValue: stake.govValue,
          lpPositions: stake.lpPositions.map(p => ({ ...p })),
        });
      }
    }
  }

  return Array.from(userMap.values());
}

/**
 * Compute earning power for all users and generate distribution map
 * @param users Aggregated user stakes (after delegation)
 * @param poolWeights Pool weighting factors
 * @param withDamping Apply quadratic damping to results (default: true)
 */
export function computeDistribution(
  users: UserStake[],
  poolWeights: Map<Address, number>,
  withDamping: boolean = true
): Map<Address, bigint> {
  const distribution = new Map<Address, bigint>();

  for (const user of users) {
    const power = computeEarningPower(user, poolWeights);
    let effectivePower = power.totalEarningPower;

    // Apply damping after computing linear earning power
    if (withDamping && effectivePower > 0n) {
      effectivePower = applyDamping(effectivePower);
    }

    if (effectivePower > 0n) {
      distribution.set(user.user, effectivePower);
    }
  }

  return distribution;
}

/**
 * Off-chain voting power calculator
 * Matches on-chain getScalarVotingPower formula
 */

import type { Address } from '../eth/index.js';

/**
 * User's voting position (aggregated across all chains)
 */
export type VotingStake = {
  user: Address;
  govUnits: bigint;  // Staked BTR units
  govPrice: bigint;  // BTR price (18 decimals)
  lpPositions: {
    pool: Address;
    units: bigint;   // LP units staked
    price: bigint;   // LP token price (18 decimals)
  }[];
};

/**
 * Voting power formula parameters (from StakingConfig)
 */
export type VotingMultipliers = {
  lpBaseMultiplier: number;     // Basis points (e.g., 5000 = 0.5x)
  lpBoostedMultiplier: number;  // Basis points (e.g., 5000 = 0.5x)
  govMultiplier: number;        // Basis points (e.g., 10000 = 1x)
  boostCap: number;             // Basis points (e.g., 50000 = 5x)
};

/**
 * Default voting multipliers (matching contract defaults)
 */
export const DEFAULT_MULTIPLIERS: VotingMultipliers = {
  lpBaseMultiplier: 5000,      // L/2
  lpBoostedMultiplier: 5000,   // boosted/2
  govMultiplier: 10000,        // 1G
  boostCap: 50000,             // 5x
};

/**
 * Voting power suppression constants (quadratic damping)
 * Suppression formula: y(S) = 1 - scale * S^exponent
 * Higher voting power → greater suppression (concave curve)
 */
const votingFactor = 0.00548;     // Scale factor ≈ 5.48×10^-3
const votingSuppressor = 0.265;    // Power exponent (concave: 0 < b < 1)

/**
 * Apply voting power suppression to linear power
 * Formula: S_eff = S · (1 - scale * S^exponent)
 * Creates concave curve that reduces influence of large holders
 * @param linearPower Linear voting power (dollar-equivalent)
 * @returns Suppressed effective voting power
 */
export function applyDamping(linearPower: bigint): bigint {
  if (linearPower === 0n) return 0n;

  // Convert to float for calculation (S is in dollars, no decimals)
  const S = Number(linearPower);

  // Calculate suppression factor: y(S) = 1 - scale*S^exponent
  const suppressionFactor = 1 - votingFactor * Math.pow(S, votingSuppressor);

  // Ensure suppression factor is non-negative
  const clampedFactor = Math.max(0, suppressionFactor);

  // S_eff = S * y(S)
  const effectivePower = S * clampedFactor;

  return BigInt(Math.floor(effectivePower));
}

/**
 * Compute scalar voting power for a user
 * Formula: V = (L * lpBase/10000) + (min(boosted, boostCap*G) * lpBoosted/10000) + (G * govMultiplier/10000)
 */
export function computeVotingPower(
  stake: VotingStake,
  multipliers: VotingMultipliers = DEFAULT_MULTIPLIERS
): bigint {
  // Compute G (BTR value in $)
  const G = (stake.govUnits * stake.govPrice) / 1_000_000_000_000_000_000n;

  // Compute L (total LP value in $)
  let L = 0n;
  for (const pos of stake.lpPositions) {
    const value = (pos.units * pos.price) / 1_000_000_000_000_000_000n;
    L += value;
  }

  if (L === 0n && G === 0n) return 0n;

  // Boost cap: boostCap * G / 10000
  const boostCapValue = (BigInt(multipliers.boostCap) * G) / 10000n;

  // Boosted amount: min(L, boostCapValue)
  const boosted = L < boostCapValue ? L : boostCapValue;

  // Compute components
  const lpBaseVotes = (L * BigInt(multipliers.lpBaseMultiplier)) / 10000n;
  const lpBoostedVotes = (boosted * BigInt(multipliers.lpBoostedMultiplier)) / 10000n;
  const govVotes = (G * BigInt(multipliers.govMultiplier)) / 10000n;

  return lpBaseVotes + lpBoostedVotes + govVotes;
}

/**
 * Aggregate voting stakes across chains
 */
export function aggregateVotingStakes(
  perChainStakes: Map<number, VotingStake[]>, // chainId => stakes
  prices: { govPrice: bigint; lpPrices: Map<Address, bigint> }
): VotingStake[] {
  const userMap = new Map<Address, VotingStake>();

  for (const stakes of perChainStakes.values()) {
    for (const stake of stakes) {
      const key = stake.user.toLowerCase() as Address;
      const existing = userMap.get(key);

      if (existing) {
        // Aggregate BTR units
        existing.govUnits += stake.govUnits;

        // Aggregate LP positions
        for (const pos of stake.lpPositions) {
          const existingPos = existing.lpPositions.find(
            p => p.pool.toLowerCase() === pos.pool.toLowerCase()
          );
          if (existingPos) {
            existingPos.units += pos.units;
          } else {
            existing.lpPositions.push({
              pool: pos.pool,
              units: pos.units,
              price: prices.lpPrices.get(pos.pool.toLowerCase() as Address) || 0n,
            });
          }
        }
      } else {
        userMap.set(key, {
          user: key,
          govUnits: stake.govUnits,
          govPrice: prices.govPrice,
          lpPositions: stake.lpPositions.map(p => ({
            pool: p.pool,
            units: p.units,
            price: prices.lpPrices.get(p.pool.toLowerCase() as Address) || 0n,
          })),
        });
      }
    }
  }

  return Array.from(userMap.values());
}

/**
 * Compute voting power for all users (with optional damping)
 * @param users Aggregated voting stakes (after delegation)
 * @param multipliers Voting formula parameters
 * @param withDamping Apply quadratic damping to results (default: true)
 */
export function computeVotingDistribution(
  users: VotingStake[],
  multipliers: VotingMultipliers = DEFAULT_MULTIPLIERS,
  withDamping: boolean = true
): Map<Address, bigint> {
  const distribution = new Map<Address, bigint>();

  for (const user of users) {
    let power = computeVotingPower(user, multipliers);

    // Apply damping after computing linear power
    if (withDamping && power > 0n) {
      power = applyDamping(power);
    }

    if (power > 0n) {
      distribution.set(user.user, power);
    }
  }

  return distribution;
}

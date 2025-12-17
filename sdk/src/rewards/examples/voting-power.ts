/**
 * Example: Voting power calculation for Snapshot
 */

import {
  computeVotingPower,
  aggregateVotingStakes,
  computeVotingDistribution,
  applyDamping,
  DEFAULT_MULTIPLIERS,
  type VotingStake,
} from '../index.js';

/**
 * Example: Calculate voting power for users
 */
async function example() {
  // 1. Fetch prices (from oracle/DEX)
  const prices = {
    govPrice: 1n * 10n ** 18n, // $1 per BTR
    lpPrices: new Map([
      ['0x1111111111111111111111111111111111111111' as const, 1n * 10n ** 18n], // $1 per LP1
      ['0x2222222222222222222222222222222222222222' as const, 2n * 10n ** 18n], // $2 per LP2
    ]),
  };

  // 2. Aggregate stakes from all chains
  const chain1Stakes: VotingStake[] = [
    {
      user: '0xAlice...' as const,
      govUnits: 10_000n * 10n ** 18n, // 10k BTR
      govPrice: prices.govPrice,
      lpPositions: [
        {
          pool: '0x1111111111111111111111111111111111111111' as const,
          units: 5_000n * 10n ** 18n, // 5k LP1
          price: prices.lpPrices.get('0x1111111111111111111111111111111111111111')!,
        },
      ],
    },
  ];

  const chain2Stakes: VotingStake[] = [
    {
      user: '0xAlice...' as const,
      govUnits: 5_000n * 10n ** 18n, // Additional 5k BTR on chain2
      govPrice: prices.govPrice,
      lpPositions: [
        {
          pool: '0x2222222222222222222222222222222222222222' as const,
          units: 2_000n * 10n ** 18n, // 2k LP2 on chain2
          price: prices.lpPrices.get('0x2222222222222222222222222222222222222222')!,
        },
      ],
    },
  ];

  const aggregated = aggregateVotingStakes(
    new Map([
      [1, chain1Stakes],
      [2, chain2Stakes],
    ]),
    prices
  );

  // 3. Compute voting power for each user
  console.log('=== VOTING POWER ===\n');
  for (const stake of aggregated) {
    const linearPower = computeVotingPower(stake, DEFAULT_MULTIPLIERS);
    const dampedPower = applyDamping(linearPower);
    const G = (stake.govUnits * stake.govPrice) / 10n ** 18n;
    const L = stake.lpPositions.reduce(
      (sum, pos) => sum + (pos.units * pos.price) / 10n ** 18n,
      0n
    );

    console.log(`User: ${stake.user}`);
    console.log(`  BTR Value (G): $${G.toString()}`);
    console.log(`  LP Value (L): $${L.toString()}`);
    console.log(`  Linear Power: ${linearPower.toString()}`);
    console.log(`  Damped Power: ${dampedPower.toString()}`);
    console.log('');
  }

  // 4. Export for Snapshot strategy
  const distribution = computeVotingDistribution(aggregated);
  const snapshot = Object.fromEntries(
    Array.from(distribution.entries()).map(([user, power]) => [user, power.toString()])
  );

  console.log('=== SNAPSHOT EXPORT ===');
  console.log(JSON.stringify(snapshot, null, 2));

  // Formula breakdown for Alice:
  // G = $15k BTR
  // L = 5k * $1 + 2k * $2 = $9k LP
  // boostCap = 5 * $15k = $75k
  // boosted = min($9k, $75k) = $9k
  // V = (L * 0.5) + (boosted * 0.5) + (G * 1)
  //   = ($9k * 0.5) + ($9k * 0.5) + ($15k * 1)
  //   = $4.5k + $4.5k + $15k = $24k
}

// Run example
if (import.meta.main) {
  example().catch(console.error);
}

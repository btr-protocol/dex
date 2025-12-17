/**
 * Example: Basic reward distribution workflow
 */

import {
  generateEpochDistribution,
  computePoolWeights,
  aggregateUserStakes,
  exportDistribution,
  type UserStake,
  type EpochConfig,
} from '../index.js';

/**
 * Example: Generate distribution for epoch 1
 */
async function example() {
  // 1. Define pool states (from on-chain data)
  const pools = [
    {
      pool: '0x1111111111111111111111111111111111111111' as const,
      utilization: 0.85, // 85% utilization
      coverage: 0.92,    // 92% coverage (under-collateralized)
    },
    {
      pool: '0x2222222222222222222222222222222222222222' as const,
      utilization: 0.60, // 60% utilization
      coverage: 1.20,    // 120% coverage (over-collateralized)
    },
    {
      pool: '0x3333333333333333333333333333333333333333' as const,
      utilization: 0.90, // 90% utilization (hot)
      coverage: 0.88,    // 88% coverage (needs incentives)
    },
  ];

  // 2. Compute pool weights (higher weight = more incentives needed)
  const poolWeights = computePoolWeights(pools);
  console.log('Pool weights:', Object.fromEntries(poolWeights));

  // 3. Aggregate user stakes from all chains
  const chain1Stakes: UserStake[] = [
    {
      user: '0xAlice...' as const,
      govValue: 10_000n * 10n ** 18n, // $10k BTR
      lpPositions: [
        {
          pool: '0x1111111111111111111111111111111111111111' as const,
          value: 5_000n * 10n ** 18n, // $5k LP in pool1
        },
        {
          pool: '0x3333333333333333333333333333333333333333' as const,
          value: 3_000n * 10n ** 18n, // $3k LP in pool3
        },
      ],
    },
    {
      user: '0xBob...' as const,
      govValue: 50_000n * 10n ** 18n, // $50k BTR
      lpPositions: [
        {
          pool: '0x2222222222222222222222222222222222222222' as const,
          value: 100_000n * 10n ** 18n, // $100k LP in pool2 (will hit boost cap)
        },
      ],
    },
  ];

  const chain2Stakes: UserStake[] = [
    {
      user: '0xAlice...' as const, // Same user on another chain
      govValue: 5_000n * 10n ** 18n, // Additional $5k BTR
      lpPositions: [
        {
          pool: '0x2222222222222222222222222222222222222222' as const,
          value: 2_000n * 10n ** 18n, // $2k LP on chain2
        },
      ],
    },
  ];

  const aggregatedStakes = aggregateUserStakes(
    new Map([
      [1, chain1Stakes],
      [2, chain2Stakes],
    ])
  );

  console.log('Aggregated stakes:', aggregatedStakes);

  // 4. Define epoch configuration
  const epochConfig: EpochConfig = {
    epochId: 1,
    rewardToken: '0x...BTR...' as const,
    totalRewards: 100_000n * 10n ** 18n, // 100k BTR to distribute
    startTime: Math.floor(Date.now() / 1000),
    endTime: Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60, // 1 week
  };

  // 5. Generate distribution
  const distribution = generateEpochDistribution(epochConfig, aggregatedStakes, poolWeights);

  console.log('\n=== EPOCH DISTRIBUTION ===');
  console.log('Merkle Root:', distribution.merkleRoot);
  console.log('Total Amount:', distribution.totalAmount.toString());
  console.log('\nClaims:');
  for (const claim of distribution.claims) {
    console.log(`  ${claim.user}:`);
    console.log(`    Index: ${claim.index}`);
    console.log(`    Amount: ${claim.amount.toString()}`);
    console.log(`    Proof: [${claim.proof.length} hashes]`);
  }

  // 6. Export for indexer/frontend
  const exported = exportDistribution(distribution);
  console.log('\n=== EXPORTED JSON ===');
  console.log(JSON.stringify(exported, null, 2));

  // 7. Submit to contract (pseudo-code)
  // await pool.setMerkleRoot(
  //   exported.rewardToken,
  //   exported.epochId,
  //   exported.merkleRoot,
  //   BigInt(exported.totalAmount),
  //   exported.startTime,
  //   exported.endTime
  // );
}

// Run example
if (import.meta.main) {
  example().catch(console.error);
}

import { onchainTable, index } from "ponder";

// One row per Swap — the fee + active-liquidity record. Real fee of a swap =
// |amountIn|·feeTier; a candidate range earns swapFee·L_pos/(L_active+L_pos)
// while price∈[pl,ph]. `liquidity` IS the active L (fee-split denominator).
export const swap = onchainTable("swap", (t) => ({
  id: t.text().primaryKey(),            // `${chainId}-${block}-${logIndex}`
  pool: t.hex().notNull(),
  chainId: t.integer().notNull(),
  blockNumber: t.bigint().notNull(),
  timestamp: t.bigint().notNull(),
  tick: t.integer().notNull(),
  sqrtPriceX96: t.text().notNull(),     // uint160 decimal string
  amount0: t.text().notNull(),          // int256 (signed) decimal string
  amount1: t.text().notNull(),
  liquidity: t.text().notNull(),        // uint128 active liquidity
}), (table) => ({
  poolTsIdx: index().on(table.pool, table.timestamp),
}));

// Mint/Burn → reconstruct the tick liquidity distribution over time (refines
// multi-tick swap fee attribution; validates active-L). `amount` is the L delta.
export const liquidityEvent = onchainTable("liquidity_event", (t) => ({
  id: t.text().primaryKey(),
  pool: t.hex().notNull(),
  chainId: t.integer().notNull(),
  blockNumber: t.bigint().notNull(),
  timestamp: t.bigint().notNull(),
  kind: t.text().notNull(),             // 'mint' | 'burn'
  tickLower: t.integer().notNull(),
  tickUpper: t.integer().notNull(),
  amount: t.text().notNull(),           // uint128 liquidity delta
  amount0: t.text().notNull(),
  amount1: t.text().notNull(),
}), (table) => ({
  poolTickIdx: index().on(table.pool, table.tickLower, table.tickUpper),
}));

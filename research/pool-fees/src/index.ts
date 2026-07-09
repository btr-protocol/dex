import { ponder } from "ponder:registry";
import { swap, liquidityEvent } from "ponder:schema";

// Swap → fee + active-liquidity record. All three pools share these field names
// (PancakeV3's extra protocolFees fields are ignored — not needed for fees).
const onSwap = async ({ event, context }: any) => {
  await context.db
    .insert(swap)
    .values({
      id: `${context.chain.id}-${event.block.number}-${event.log.logIndex}`,
      pool: event.log.address,
      chainId: context.chain.id,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      tick: Number(event.args.tick),
      sqrtPriceX96: event.args.sqrtPriceX96.toString(),
      amount0: event.args.amount0.toString(),
      amount1: event.args.amount1.toString(),
      liquidity: event.args.liquidity.toString(),
    })
    .onConflictDoNothing();
};

const onLiquidity = (kind: "mint" | "burn") => async ({ event, context }: any) => {
  await context.db
    .insert(liquidityEvent)
    .values({
      id: `${context.chain.id}-${event.block.number}-${event.log.logIndex}`,
      pool: event.log.address,
      chainId: context.chain.id,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      kind,
      tickLower: Number(event.args.tickLower),
      tickUpper: Number(event.args.tickUpper),
      amount: event.args.amount.toString(),
      amount0: event.args.amount0.toString(),
      amount1: event.args.amount1.toString(),
    })
    .onConflictDoNothing();
};

for (const c of ["PcsBtcbWbnb", "PcsBtcbUsdt", "PcsWbnbUsdt", "UniWbnbUsdt"]) {
  ponder.on(`${c}:Swap`, onSwap);
  ponder.on(`${c}:Mint`, onLiquidity("mint"));
  ponder.on(`${c}:Burn`, onLiquidity("burn"));
}

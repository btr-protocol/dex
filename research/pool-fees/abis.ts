// Concentrated-liquidity pool event ABIs. Only Swap differs across forks:
// Uniswap-v3 / Aerodrome-Slipstream = 7 fields; PancakeSwap-v3 adds 2
// protocolFees fields. Mint/Burn are identical across all three.
export const univ3Abi = [
  { type: "event", name: "Swap", inputs: [
    { indexed: true, name: "sender", type: "address" },
    { indexed: true, name: "recipient", type: "address" },
    { name: "amount0", type: "int256" },
    { name: "amount1", type: "int256" },
    { name: "sqrtPriceX96", type: "uint160" },
    { name: "liquidity", type: "uint128" },
    { name: "tick", type: "int24" },
  ] },
  { type: "event", name: "Mint", inputs: [
    { name: "sender", type: "address" },
    { indexed: true, name: "owner", type: "address" },
    { indexed: true, name: "tickLower", type: "int24" },
    { indexed: true, name: "tickUpper", type: "int24" },
    { name: "amount", type: "uint128" },
    { name: "amount0", type: "uint256" },
    { name: "amount1", type: "uint256" },
  ] },
  { type: "event", name: "Burn", inputs: [
    { indexed: true, name: "owner", type: "address" },
    { indexed: true, name: "tickLower", type: "int24" },
    { indexed: true, name: "tickUpper", type: "int24" },
    { name: "amount", type: "uint128" },
    { name: "amount0", type: "uint256" },
    { name: "amount1", type: "uint256" },
  ] },
] as const;

export const pancakeV3Abi = [
  { type: "event", name: "Swap", inputs: [
    { indexed: true, name: "sender", type: "address" },
    { indexed: true, name: "recipient", type: "address" },
    { name: "amount0", type: "int256" },
    { name: "amount1", type: "int256" },
    { name: "sqrtPriceX96", type: "uint160" },
    { name: "liquidity", type: "uint128" },
    { name: "tick", type: "int24" },
    { name: "protocolFeesToken0", type: "uint128" },
    { name: "protocolFeesToken1", type: "uint128" },
  ] },
  ...univ3Abi.filter((e) => e.name !== "Swap"),
] as const;

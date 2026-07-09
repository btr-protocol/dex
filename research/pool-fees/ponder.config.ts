import { createConfig } from "ponder";
import { univ3Abi, pancakeV3Abi } from "./abis";

// Operator-specified pools. Chains = BSC (first deploy) + Base. Keyless RPC mode
// (public RPC; override via env with a private/archive node for a faster backfill).
// PancakeSwap-v3 pools use the 9-field Swap ABI; Uniswap-v3 uses 7-field.
// startBlock ≈ 2yr-ago on BSC (~40M); refine per-pool creation if needed.
const BSC_2YR = 40_000_000;

export default createConfig({
  chains: {
    // dRPC free tier: getLogs OK at ~2000-block ranges (10k times out on dense pools).
    // Cap RPS to stay within free limits; Ponder auto-tunes the block range down on errors.
    bsc: { id: 56, rpc: process.env.PONDER_RPC_URL_56 ?? "https://bsc-dataseed.bnbchain.org", maxRequestsPerSecond: 20 },
    base: { id: 8453, rpc: process.env.PONDER_RPC_URL_8453 ?? "https://mainnet.base.org", maxRequestsPerSecond: 20 },
  },
  contracts: {
    // ── BSC (first deploy chain) ──
    PcsBtcbWbnb: { chain: "bsc", abi: pancakeV3Abi,
      address: "0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c", startBlock: BSC_2YR },
    PcsBtcbUsdt: { chain: "bsc", abi: pancakeV3Abi,
      address: "0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4", startBlock: BSC_2YR },
    PcsWbnbUsdt: { chain: "bsc", abi: pancakeV3Abi,
      address: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", startBlock: BSC_2YR },
    UniWbnbUsdt: { chain: "bsc", abi: univ3Abi,
      address: "0x6fe9E9de56356F7eDBfcBB29FAB7cd69471a4869", startBlock: BSC_2YR },
    // ── Base — pools TBD (operator providing; will add ETH/SOL/BTC pools here) ──
  },
});

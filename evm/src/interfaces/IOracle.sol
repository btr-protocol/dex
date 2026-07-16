// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @title IOracle
/// @notice Shared oracle interface. Quote = `lastPriceB64` (fresh NXR-signed mark). σ is the signed
///         sample floored at |Δmark|/mark; swap path reads mark + `sigmaEma`.
/// @dev Prices in B64 (52-bit mantissa, 5-bit decimals, 7-bit exp+bias). σ in PBPS (1e6 = 100%).
///      `confidence` = mark uncertainty (bps), decoupled from σ. One 256-bit slot per feed.
interface IOracle {
  struct FeedData {
    uint64 lastPriceB64; // fresh mark, B64. QUOTE SOURCE (kills LVR).
    uint32 sigmaEma; // stored σ (PBPS): signed sample floored at |Δmark|/mark. PRICING INPUT.
    uint32 updatedAt; // push timestamp.
    uint16 ttl; // freshness window (s).
    uint16 confidence; // mark 1σ CI (bps). Spread surcharge + halt gate.
    uint16 flags; // feed flags. bit0 = paused (guardian fast-freeze; fail-closed in gate/isFeedFresh).
    // Repurposed from vestigial `tau` (dead since updateSigmaEma removed). Slot bits [160:176).
    uint16 tauSigma; // reserved time-constant (s). Set at addFeed; unused on-chain (direct-σ path).
    uint16 maxDeviation; // per-push max mark move (bps) at zero staleness. Mandatory non-zero.
    uint48 sourceTs; // GAS-20: NXR-signed source time (ms since epoch); signed-path monotonic
    // replay guard + true data-age. 0 on legacy-only feeds. Slot bits [208:256).
  }

  function getFeed(bytes32 feedId) external view returns (FeedData memory data);
  function isFeedFresh(bytes32 feedId, uint32 maxAge) external view returns (bool);
  function isFeedFresh(bytes32 feedId) external view returns (bool);
}

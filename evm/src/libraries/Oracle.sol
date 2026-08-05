// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IOracle} from "../interfaces/IOracle.sol";
import {Err} from "@btr-shared/Errors.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {Constants as C} from "./Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";

/// @title Oracle - pure feed math (mark decode, direct σ).
/// @dev Keeper attests mark + Parkinson σ + confidence; the signed path stores σ directly (no
///      on-chain EMA — smoothing moves to source), floored on-chain at realized |Δmark|/mark.
library Oracle {
  /// @notice Quote source: the fresh keeper mark in 1e18. Quoting off this (not a smoothed avg) kills LVR.
  function mark(IOracle.FeedData memory feed) internal pure returns (uint256) {
    return M.b64To1e18(feed.lastPriceB64);
  }

  /// @notice Observation clock for freshness. Prefer authenticated `sourceTs` (ms→s, capped at the
  ///         relay landing timestamp)
  ///         when set by the signed path; else landing `updatedAt`. Closes withheld-blob relabeling
  ///         where relay stamps `updatedAt=now` on an old signed quote (H-INT-01 / B-02).
  function observedAt(IOracle.FeedData memory feed) internal pure returns (uint32) {
    return obsAt(feed.sourceTs, feed.updatedAt);
  }

  /// @dev The observed-at clock as pure field math: `min(sourceTs ms→s, updatedAt)`, or `updatedAt`
  ///      when unsigned. Shared by the memory reader (observedAt) and the storage reader
  ///      (ExternalOracle._obsAt) so this withheld-blob-relabeling defense can never drift between them.
  ///      Signed-path clock skew is NOT capped to block.timestamp — that would push the observation
  ///      forward every block until source time catches up, extending TTL.
  function obsAt(uint48 sourceTs, uint32 updatedAt) internal pure returns (uint32) {
    if (sourceTs == 0) return updatedAt;
    uint256 srcSec = uint256(sourceTs) / 1000;
    return srcSec > updatedAt ? updatedAt : uint32(srcSec);
  }

  /// @notice ORC-10: fail-closed safety gate for ANY feed consumed for pricing OR as a depeg breaker.
  ///         Reverts on STALE (age > ttl), DEAD (mark == 0) or UNCERTAIN (confidence > MAX_CONFIDENCE_
  ///         HALT_BPS). Centralizes the triad so every safety path (external primary, base mark, INTERNAL
  ///         gate feed, refFeed) halts on the same conditions: an uncertain safety feed must never
  ///         silently permit execution. Returns the decoded 1e18 mark. `view` (reads block.timestamp).
  function gate(IOracle.FeedData memory feed) internal view returns (uint256 mark1e18) {
    // Guardian fast-freeze (fail-closed): a paused feed must revert even if it still reads fresh.
    // Parenthesize: `flags & BIT != 0` is fine today (& binds tighter than !=) but the form is
    // fragile under future edits — keep the explicit `(flags & BIT) != 0` shape.
    if ((feed.flags & C.FEED_PAUSED_BIT) != 0) revert Err.FeedPaused();
    // ORA-MEV-01: a signed mark landed THIS block is not yet executable. Same-block
    // old-mark → relay push → new-mark extraction needs the fresh mark in the exit tx; deferring
    // applicability by one block closes that window. Unsigned/synthetic feeds (sourceTs==0:
    // INTERNAL peg, addFeed seed, MockOracle) are exempt — they are not permissionlessly relayed.
    // Next block the mark applies with the realized-move σ floor as defense-in-depth.
    if (feed.sourceTs != 0 && feed.updatedAt == block.timestamp) revert Err.CooldownActive(1);
    uint32 obs = observedAt(feed);
    uint256 age = block.timestamp >= obs ? block.timestamp - obs : type(uint32).max;
    if (age > feed.ttl) {
      revert Err.StaleData(age > type(uint32).max ? type(uint32).max : uint32(age), feed.ttl);
    }
    mark1e18 = M.b64To1e18(feed.lastPriceB64);
    if (mark1e18 == 0) revert Err.ZeroValue();
    if (feed.confidence > C.MAX_CONFIDENCE_HALT_BPS) {
      revert Err.ThresholdViolation(feed.confidence, C.MAX_CONFIDENCE_HALT_BPS);
    }
  }

  /// @notice Realized mark move |Δmark|/mark in PBPS, capped at MAX_SIGMA_PBPS. `internal` so the signed
  ///         oracle path can floor its attested σ at this same magnitude (economic circuit-breaker).
  function markMovePbps(uint256 prev1e18, uint256 mark1e18) internal pure returns (uint32) {
    if (prev1e18 == 0) return 0;
    uint256 diff = mark1e18 > prev1e18 ? mark1e18 - prev1e18 : prev1e18 - mark1e18;
    uint256 pbps = (diff * SC.PBPS) / prev1e18;
    return pbps > C.MAX_SIGMA_PBPS ? C.MAX_SIGMA_PBPS : uint32(pbps);
  }

  function getPegFeed(uint64 pegB64, uint32 sigma)
    internal
    view
    returns (IOracle.FeedData memory feed)
  {
    feed = IOracle.FeedData({
      lastPriceB64: pegB64,
      sigma: sigma,
      updatedAt: uint32(block.timestamp),
      ttl: type(uint16).max,
      confidence: 0,
      flags: 0,
      maxDeviation: 0,
      sourceTs: 0
    });
  }
}

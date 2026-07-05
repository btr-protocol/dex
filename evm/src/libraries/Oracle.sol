// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IOracle} from "../interfaces/IOracle.sol";
import {Maths as M} from "./Maths.sol";
import {Constants as C} from "./Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";

/// @title Oracle -pure feed math (mark decode, σ, on-chain EMA recurrence).
/// @dev No external calls, no storage. Feed = external keeper mark + on-chain rate-clamped EMA.
library Oracle {
    /// @notice Quote source: the fresh keeper mark in 1e18. Quoting off this (not the EMA) kills LVR.
    function mark(IOracle.FeedData memory feed) internal pure returns (uint256) {
        return M.b64To1e18(feed.lastPriceB64);
    }

    /// @notice Realized vol σ (1e6 base). Single (dual fast/slow average deleted).
    function getSigma(IOracle.FeedData memory feed) internal pure returns (uint32) {
        return feed.sigma;
    }

    /// @notice One-step on-chain EMA update: single time-decayed (α), RATE-clamped toward the mark.
    /// @dev band = min(ema·K_BAND·confidence/BPS, ema·MAX_BAND_BPS/BPS). The clamp is on the RATE of
    ///      change (a band around the CURRENT ema), NOT an absolute min/max — so the ema faithfully
    ///      tracks a real crash over successive pushes yet can never brick like a LUNA/Venus minAnswer
    ///      floor. α = min(Δt/τ, 1): Δt==0 (same block) ⇒ α=0 (frozen); τ==0 ⇒ α=1 (jump to clamped
    ///      mark). Guarantee: a single push (even a manipulated one) displaces the ema by ≤ α·band.
    ///      TRUST SPLIT: this guarantees only faithful clamp+decay; mark honesty = oracle-key gov +
    ///      off-chain monitor + revokeOracle. The clamp bounds a compromised key's per-push damage.
    function updateEma(uint64 emaB64, uint64 markB64, uint256 dt, uint32 tau, uint16 confidence)
        internal pure returns (uint64)
    {
        return updateEmaMark1e18(emaB64, M.b64To1e18(markB64), dt, tau, confidence);
    }

    /// @notice `updateEma` core taking the mark already decoded to 1e18 — lets the push hot path
    ///         reuse the decode `_validate` already paid for instead of decoding the mark twice.
    function updateEmaMark1e18(uint64 emaB64, uint256 mark1e18, uint256 dt, uint32 tau, uint16 confidence)
        internal pure returns (uint64)
    {
        // α=0 ⇒ ema mathematically unchanged: return the stored word verbatim. Skips the full
        // decode/clamp/encode round-trip (~2.1k gas) on same-block re-pushes (HA redundant pushers)
        // and is exact by construction (no codec re-normalization of the frozen value).
        if (dt == 0 && tau != 0) return emaB64;

        uint256 ema = M.b64To1e18(emaB64);
        uint256 p = mark1e18;

        // Confidence floor 1: conf==0 must NOT zero the band, or every mark clamps back to the
        // current ema forever while isFeedFresh() stays true — a permanent servable-EMA freeze that
        // violates the no-brick guarantee above. Floored, the ema still converges at K_BAND bps/push.
        // min(K_BAND·conf, MAX_BAND_BPS) applied pre-multiply: exact (same divisor, mul monotone),
        // one mul+div instead of two.
        uint256 kc = C.K_BAND * (confidence == 0 ? 1 : uint256(confidence));
        if (kc > C.MAX_BAND_BPS) kc = C.MAX_BAND_BPS;
        uint256 band = (ema * kc) / SC.BPS;
        if (p > ema + band) p = ema + band;
        else if (p + band < ema) p = ema - band;

        uint256 alpha;
        if (tau == 0) {
            alpha = SC.WAD;
        } else {
            alpha = (dt * SC.WAD) / uint256(tau);
            if (alpha > SC.WAD) alpha = SC.WAD;
        }

        uint256 newEma = p >= ema
            ? ema + (alpha * (p - ema)) / SC.WAD
            : ema - (alpha * (ema - p)) / SC.WAD;
        return M.encodeB64(newEma, 18);
    }

    /// @notice Synthetic never-stale peg feed: lastPrice ≡ ema ≡ `pegB64`, confidence 0, ttl max. Backs
    ///         both the base numeraire (peg=1.0) and INTERNAL-mode stable assets (peg=pegB64 constant).
    ///         A constant mark cannot be poisoned ⇒ the write-on-swap LVR leak is structurally void.
    function getPegFeed(uint64 pegB64, uint32 sigma) internal view returns (IOracle.FeedData memory feed) {
        feed = IOracle.FeedData({
            lastPriceB64: pegB64,
            emaPriceB64: pegB64,
            sigma: sigma,
            updatedAt: uint32(block.timestamp),
            ttl: type(uint16).max,
            confidence: 0,
            tau: 0
        });
    }

    /// @notice Synthetic feed for the base token (numeraire): price ≡ ema ≡ 1.0, never expires.
    function getBaseFeed() internal view returns (IOracle.FeedData memory feed) {
        return getPegFeed(M.encodeB64(SC.WAD, 18), uint32(SC.ONE_PCT_PBPS));
    }
}

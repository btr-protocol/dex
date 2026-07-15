// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IOracle} from "../interfaces/IOracle.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Maths as M} from "./Maths.sol";
import {Constants as C} from "./Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";

/// @title Oracle -pure feed math (mark decode, σ-EMA).
/// @dev Keeper attests mark + Parkinson σ sample + confidence; chain attests the σ-EMA step.
library Oracle {
    /// @notice Quote source: the fresh keeper mark in 1e18. Quoting off this (not the EMA) kills LVR.
    function mark(IOracle.FeedData memory feed) internal pure returns (uint256) {
        return M.b64To1e18(feed.lastPriceB64);
    }

    /// @notice ORC-10: fail-closed safety gate for ANY feed consumed for pricing OR as a depeg breaker.
    ///         Reverts on STALE (age > ttl), DEAD (mark == 0) or UNCERTAIN (confidence > MAX_CONFIDENCE_
    ///         HALT_BPS). Centralizes the triad so every safety path (external primary, base mark, INTERNAL
    ///         gate feed, refFeed) halts on the same conditions — an uncertain safety feed must never
    ///         silently permit execution. Returns the decoded 1e18 mark. `view` (reads block.timestamp).
    function gate(IOracle.FeedData memory feed) internal view returns (uint256 mark1e18) {
        uint256 age = block.timestamp >= feed.updatedAt ? block.timestamp - feed.updatedAt : type(uint32).max;
        if (age > feed.ttl) revert Err.StaleData(age > type(uint32).max ? type(uint32).max : uint32(age), feed.ttl);
        mark1e18 = M.b64To1e18(feed.lastPriceB64);
        if (mark1e18 == 0) revert Err.ZeroValue();
        if (feed.confidence > C.MAX_CONFIDENCE_HALT_BPS) {
            revert Err.ThresholdViolation(feed.confidence, C.MAX_CONFIDENCE_HALT_BPS);
        }
    }

    /// @notice Pricing σ (PBPS). On-chain σ-EMA — never the raw keeper sample.
    function getSigma(IOracle.FeedData memory feed) internal pure returns (uint32) {
        return feed.sigmaEma;
    }

    /// @notice Fold keeper Parkinson σ sample into on-chain σ-EMA (asymmetric bands + mark-move floor).
    /// @dev sample' = max(sample, |Δmark|/mark in PBPS). Suppression capped per push; ratchet-up generous.
    function updateSigmaEma(
        uint32 sigmaEma,
        uint32 sigmaSample,
        uint256 prevMark1e18,
        uint256 mark1e18,
        uint256 dt,
        uint16 tauSigma
    ) internal pure returns (uint32) {
        if (dt == 0 && tauSigma != 0) return sigmaEma;

        uint32 movePbps = _markMovePbps(prevMark1e18, mark1e18);
        uint32 sample = sigmaSample > movePbps ? sigmaSample : movePbps;
        if (sample > C.MAX_SIGMA_PBPS) sample = C.MAX_SIGMA_PBPS;

        uint256 alpha;
        if (tauSigma == 0) {
            alpha = SC.WAD;
        } else {
            alpha = (dt * SC.WAD) / uint256(tauSigma);
            if (alpha > SC.WAD) alpha = SC.WAD;
        }

        uint256 bandUp = (uint256(sigmaEma) * C.SIGMA_UP_BPS) / SC.BPS;
        if (bandUp < C.SIGMA_BAND_FLOOR_PBPS) bandUp = C.SIGMA_BAND_FLOOR_PBPS;
        uint256 bandDown = (uint256(sigmaEma) * C.SIGMA_DOWN_BPS) / SC.BPS;

        uint256 target = sample;
        uint256 hi = uint256(sigmaEma) + bandUp;
        uint256 lo = sigmaEma > bandDown ? uint256(sigmaEma) - bandDown : 0;
        if (target > hi) target = hi;
        if (target < lo) target = lo;

        uint256 next = target >= sigmaEma
            ? uint256(sigmaEma) + (alpha * (target - sigmaEma)) / SC.WAD
            : uint256(sigmaEma) - (alpha * (uint256(sigmaEma) - target)) / SC.WAD;
        if (next > C.MAX_SIGMA_PBPS) next = C.MAX_SIGMA_PBPS;
        return uint32(next);
    }

    function _markMovePbps(uint256 prev1e18, uint256 mark1e18) private pure returns (uint32) {
        if (prev1e18 == 0) return 0;
        uint256 diff = mark1e18 > prev1e18 ? mark1e18 - prev1e18 : prev1e18 - mark1e18;
        uint256 pbps = (diff * SC.PBPS) / prev1e18;
        return pbps > C.MAX_SIGMA_PBPS ? C.MAX_SIGMA_PBPS : uint32(pbps);
    }

    function getPegFeed(uint64 pegB64, uint32 sigmaEma) internal view returns (IOracle.FeedData memory feed) {
        feed = IOracle.FeedData({
            lastPriceB64: pegB64,
            sigmaEma: sigmaEma,
            updatedAt: uint32(block.timestamp),
            ttl: type(uint16).max,
            confidence: 0,
            tau: 0,
            tauSigma: 0,
            maxDeviation: 0,
            sourceTs: 0
        });
    }
}

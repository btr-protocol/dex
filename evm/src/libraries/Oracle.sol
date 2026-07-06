// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IOracle} from "../interfaces/IOracle.sol";
import {Maths as M} from "./Maths.sol";
import {Constants as C} from "./Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";

/// @title Oracle -pure feed math (mark decode, σ-EMA, on-chain price EMA).
/// @dev Keeper attests mark + Parkinson σ sample + confidence; chain attests price EMA + σ-EMA steps.
library Oracle {
    /// @notice Quote source: the fresh keeper mark in 1e18. Quoting off this (not the EMA) kills LVR.
    function mark(IOracle.FeedData memory feed) internal pure returns (uint256) {
        return M.b64To1e18(feed.lastPriceB64);
    }

    /// @notice Pricing σ (PBPS). On-chain σ-EMA — never the raw keeper sample.
    function getSigma(IOracle.FeedData memory feed) internal pure returns (uint32) {
        return feed.sigmaEma;
    }

    /// @notice One-step on-chain price EMA: time-decayed (α), RATE-clamped toward the mark.
    function updateEma(uint64 emaB64, uint64 markB64, uint256 dt, uint16 tau, uint16 confidence)
        internal pure returns (uint64)
    {
        return updateEmaMark1e18(emaB64, M.b64To1e18(markB64), dt, tau, confidence);
    }

    function updateEmaMark1e18(uint64 emaB64, uint256 mark1e18, uint256 dt, uint16 tau, uint16 confidence)
        internal pure returns (uint64)
    {
        if (dt == 0 && tau != 0) return emaB64;

        uint256 ema = M.b64To1e18(emaB64);
        uint256 p = mark1e18;

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
            emaPriceB64: pegB64,
            sigmaEma: sigmaEma,
            updatedAt: uint32(block.timestamp),
            ttl: type(uint16).max,
            confidence: 0,
            tau: 0,
            tauSigma: 0
        });
    }

    function getBaseFeed() internal view returns (IOracle.FeedData memory feed) {
        return getPegFeed(M.encodeB64(SC.WAD, 18), uint32(SC.ONE_PCT_PBPS));
    }
}

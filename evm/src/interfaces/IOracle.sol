// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @title IOracle
/// @notice Shared oracle interface. Quote = `lastPriceB64` (fresh keeper mark). σ-EMA is on-chain
///         derived state (rate-clamped); swap path reads mark + `sigmaEma`.
/// @dev Prices in B64 (52-bit mantissa, 5-bit decimals, 7-bit exp+bias). σ in PBPS (1e6 = 100%).
///      `confidence` = mark uncertainty (bps), decoupled from σ. One 256-bit slot per feed.
interface IOracle {
    struct FeedData {
        uint64 lastPriceB64; // fresh mark, B64. QUOTE SOURCE (kills LVR).
        uint32 sigmaEma;       // on-chain rate-clamped σ EMA (PBPS). PRICING INPUT — not the raw sample.
        uint32 updatedAt;      // push timestamp.
        uint16 ttl;            // freshness window (s).
        uint16 confidence;     // mark 1σ CI (bps). Spread surcharge + halt gate.
        uint16 tau;            // reserved EMA time-constant (s). Set at addFeed.
        uint16 tauSigma;       // σ-EMA time-constant (s). Set at addFeed.
        uint16 maxDeviation;   // per-push max mark move (bps) at zero staleness. Mandatory non-zero.
        uint48 sourceTs;       // GAS-20: NXR-signed source time (ms since epoch); signed-path monotonic
                               // replay guard + true data-age. 0 on legacy-only feeds. Slot bits [208:256).
    }

    function getFeed(bytes32 feedId) external view returns (FeedData memory data);
    function isFeedFresh(bytes32 feedId, uint32 maxAge) external view returns (bool);
    function isFeedFresh(bytes32 feedId) external view returns (bool);
}

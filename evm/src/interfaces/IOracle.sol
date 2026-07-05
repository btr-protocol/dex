// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @title IOracle
/// @notice Shared oracle interface. Quote source = lastPriceB64 (fresh keeper mark); emaPriceB64 is
///         an on-chain rate-clamped, time-decayed reference (Pyth/Chainlink-parity servable object).
/// @dev Prices in B64 (56-bit mantissa, 8-bit signed exp). Volatility (sigma) 1e6 base (SC.PBPS).
///      confidence = 1σ CI in bps. One 256-bit storage slot per feed.
interface IOracle {
    struct FeedData {
        uint64 lastPriceB64; // fresh mark, B64. QUOTE SOURCE (kills LVR).
        uint64 emaPriceB64;  // on-chain rate-clamped, time-decayed EMA. SERVABLE reference (getEma).
        uint32 sigma;        // realized vol, 1e6 base (SC.PBPS units).
        uint32 updatedAt;    // push timestamp.
        uint16 ttl;          // freshness window (s).
        uint16 confidence;   // 1σ CI in bps. Spread surcharge + halt input.
        uint32 tau;          // EMA decay time-constant (s), per-feed. Set at addFeed.
    }

    function getFeed(bytes32 feedId) external view returns (FeedData memory data);
    function isFeedFresh(bytes32 feedId, uint32 maxAge) external view returns (bool);
    function isFeedFresh(bytes32 feedId) external view returns (bool);
    function getEma(bytes32 feedId) external view returns (uint64 ema);
}

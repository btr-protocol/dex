// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @title IOracle
/// @notice Shared oracle interface for internal + external oracles.
/// @dev Prices in B64 (56-bit mantissa, 8-bit signed exp). Volatility 1e6 base. Offsets 0.0001%.
interface IOracle {
    /// @notice Single-slot feed data. fastEMA = lastPrice*(OFFSET_PRECISION+fastOffset)/OFFSET_PRECISION.
    struct FeedData {
        uint64 lastPriceB64;
        int32 fastOffset;
        int32 slowOffset;
        uint32 fastVolEMA;
        uint32 slowVolEMA;
        uint32 updatedAt;
        uint16 ttl;
        uint16 confidence;
    }

    event OracleUpdated(address indexed token, uint64 price, uint32 fastVolEMA, uint32 slowVolEMA);

    function getFeed(bytes32 feedId) external view returns (FeedData memory data);
    function isFeedFresh(bytes32 feedId, uint32 maxAge) external view returns (bool);
    function isFeedFresh(bytes32 feedId) external view returns (bool);
    function getFastEMA(bytes32 feedId) external view returns (uint64 fastEMA);
}

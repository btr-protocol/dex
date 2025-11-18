// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {IInternalOracle} from "../interfaces/IInternalOracle.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {LibStorage as S} from "../libraries/LibStorage.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";
import {LibDiamondStorage} from "../libraries/LibDiamondStorage.sol";
import {BAMMErrors as E} from "./BAMMErrors.sol";

/// @title BAMMInternalOracle
/// @notice Oracle facet - manages internal accumulator-based oracles and decoding
/// @dev Delegatecalled from BAMMCore, requires owner access
contract BAMMInternalOracle {

    // ========== MODIFIERS ==========

    modifier onlyOwner() {
        LibDiamondStorage.DiamondStorage storage d = LibDiamondStorage.ds();
        if (msg.sender != d.owner) revert E.Unauthorized();
        _;
    }

    // ========== ORACLE DECODING (Internal & External) ==========

    /// @notice Decode oracle entry to compute TWAPs and prices
    /// @dev Consolidates logic for both internal (accumulator-based) oracles
    /// @dev Shared interface: works with IInternalOracle.InternalFeedData
    /// @param oracle Oracle entry storage (internal oracle with accumulators)
    /// @return data Decoded oracle data with TWAPs and volatility
    function _decodeOracle(IInternalOracle.InternalFeedData storage oracle)
        internal
        view
        returns (IOracle.DecodedFeedData memory data)
    {
        // Compute current accumulator with elapsed time
        // Safe: currentPrice (uint64 max ≈ 1.8e19) × elapsed (max 24h = 86400) < uint256.max
        uint256 elapsed = block.timestamp - oracle.base.updatedAt;
        uint256 accum = oracle.priceAccumulator + uint256(oracle.currentPrice) * elapsed;

        // Fast TWAP
        uint256 dtFast = block.timestamp - oracle.fastSnapshotTime;
        data.fastTWAP = dtFast == 0
            ? oracle.currentPrice
            : uint64((accum - oracle.fastAccumSnapshot) / dtFast);

        // Slow TWAP
        uint256 dtSlow = block.timestamp - oracle.slowSnapshotTime;
        data.slowTWAP = dtSlow == 0
            ? oracle.currentPrice
            : uint64((accum - oracle.slowAccumSnapshot) / dtSlow);

        // Convert B64 to 1e18 prices
        data.priceFast = M.b64ToPrice(data.fastTWAP);
        data.priceSlow = M.b64ToPrice(data.slowTWAP);

        // Volatility (no clamping for baseline)
        data.volFast = oracle.base.fastVolEMA;
        data.volSlow = oracle.base.slowVolEMA;
        data.volBaseline = oracle.base.slowVolEMA;
    }

    /// @notice Get fast TWAP price only (optimized for hot path)
    /// @param oracle Oracle entry storage
    /// @return fastPrice Fast TWAP in 1e18 format
    function _getFastPrice(IInternalOracle.InternalFeedData storage oracle)
        internal
        view
        returns (uint256 fastPrice)
    {
        uint256 elapsed = block.timestamp - oracle.base.updatedAt;
        uint256 accum = oracle.priceAccumulator + uint256(oracle.currentPrice) * elapsed;

        uint256 dtFast = block.timestamp - oracle.fastSnapshotTime;
        uint64 fastTWAP = dtFast == 0
            ? oracle.currentPrice
            : uint64((accum - oracle.fastAccumSnapshot) / dtFast);

        fastPrice = M.b64ToPrice(fastTWAP);
    }

    // ========== ORACLE MANAGEMENT ==========

    /// @notice Push price update (owner only)
    function pushPrice(
        address token,
        uint64 fastEMA,
        uint64 slowEMA,
        uint32 fastVolEMA,
        uint32 slowVolEMA
    ) external onlyOwner {
        IBAMM.BAMMStorage storage $ = S.bamm();
        bytes32 feedId = S.computeOracleId(token, $.baseToken);
        IInternalOracle.InternalFeedData storage feed = $.internalFeeds[feedId];

        feed.base.fastEMA = fastEMA;
        feed.base.slowEMA = slowEMA;
        feed.base.fastVolEMA = fastVolEMA;
        feed.base.slowVolEMA = slowVolEMA;
        feed.base.updatedAt = uint32(block.timestamp);

        emit IBAMM.OracleFeedUpdated(
            feedId,
            IOracle.FeedData({
                fastEMA: fastEMA,
                slowEMA: slowEMA,
                fastVolEMA: fastVolEMA,
                slowVolEMA: slowVolEMA,
                updatedAt: uint32(block.timestamp),
                maxDeviation: 0,
                ttl: 0
            }),
            msg.sender
        );
    }

    /// @notice Get oracle data for token
    function getOracleData(address token) external view returns (
        uint64 fastEMA,
        uint64 slowEMA,
        uint32 fastVolEMA,
        uint32 slowVolEMA,
        uint32 updatedAt
    ) {
        IBAMM.BAMMStorage storage $ = S.bamm();
        bytes32 feedId = S.computeOracleId(token, $.baseToken);
        IInternalOracle.InternalFeedData storage feed = $.internalFeeds[feedId];

        return (
            feed.base.fastEMA,
            feed.base.slowEMA,
            feed.base.fastVolEMA,
            feed.base.slowVolEMA,
            feed.base.updatedAt
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IInternalOracle} from "../interfaces/IInternalOracle.sol";
import {LibStorage as S} from "./LibStorage.sol";
import {LibMaths as M} from "./LibMaths.sol";

/// @title LibOracle - Consolidated oracle TWAP computation
/// @notice Single source of truth for oracle decoding to eliminate duplication
library LibOracle {
    /// @notice Oracle data with decoded TWAPs and prices
    struct FeedData {
        uint64 fastTWAP;
        uint64 slowTWAP;
        uint256 priceFast;      // 1e18
        uint256 priceSlow;      // 1e18
        uint32 volFast;
        uint32 volSlow;
        uint32 volBaseline;     // = volSlow (baseline volatility, no clamping)
    }

    /// @notice Decode oracle entry to compute TWAPs and prices
    /// @dev Consolidates logic previously duplicated in LibPricing and LibStorage
    /// @param oracle Oracle entry storage
    /// @return data Decoded oracle data with TWAPs and volatility
    function decodeOracle(IInternalOracle.InternalFeedData storage oracle)
        internal
        view
        returns (FeedData memory data)
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
    function getFastPrice(IInternalOracle.InternalFeedData storage oracle)
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
}

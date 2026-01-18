// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IOracleV1} from "../interfaces/IOracleV1.sol";

/// @title LibTransientOracle
/// @notice Transient storage for oracle data caching within transactions
/// @dev Uses EIP-1153 transient storage to reduce repeated oracle reads
library LibTransientOracle {
    // Transient storage slots for oracle caching
    // We use keccak256 of token address to get unique slots
    bytes32 private constant ORACLE_CACHE_SEED = keccak256("ORACLE_CACHE_V1");

    /// @notice Cache oracle feed data in transient storage
    /// @param token Token address
    /// @param feed Feed data to cache
    function cacheFeed(address token, IOracleV1.FeedData memory feed) internal {
        bytes32 slot = keccak256(abi.encode(ORACLE_CACHE_SEED, token));

        assembly {
            // Store lastPrice
            tstore(slot, mload(feed))
            // Store fastOffset and slowOffset
            tstore(add(slot, 0x20), mload(add(feed, 0x20)))
            // Store fastVolEMA and slowVolEMA
            tstore(add(slot, 0x40), mload(add(feed, 0x40)))
            // Store updatedAt, ttl, confidence
            tstore(add(slot, 0x60), mload(add(feed, 0x60)))
        }
    }

    /// @notice Read cached oracle feed from transient storage
    /// @param token Token address
    /// @return feed Cached feed data (all zeros if not cached)
    /// @return cached True if data was cached
    function getCachedFeed(address token) internal view returns (IOracleV1.FeedData memory feed, bool cached) {
        bytes32 slot = keccak256(abi.encode(ORACLE_CACHE_SEED, token));

        assembly {
            // Load data from transient storage
            let data1 := tload(slot)
            let data2 := tload(add(slot, 0x20))
            let data3 := tload(add(slot, 0x40))
            let data4 := tload(add(slot, 0x60))

            // Check if cached (any non-zero value indicates cache hit)
            cached := or(or(data1, data2), or(data3, data4))

            // Store in memory struct
            mstore(feed, data1)
            mstore(add(feed, 0x20), data2)
            mstore(add(feed, 0x40), data3)
            mstore(add(feed, 0x60), data4)
        }
    }

    /// @notice Clear cached oracle data (optional, transient storage auto-clears)
    /// @param token Token address
    function clearCache(address token) internal {
        bytes32 slot = keccak256(abi.encode(ORACLE_CACHE_SEED, token));

        assembly {
            tstore(slot, 0)
            tstore(add(slot, 0x20), 0)
            tstore(add(slot, 0x40), 0)
            tstore(add(slot, 0x60), 0)
        }
    }
}
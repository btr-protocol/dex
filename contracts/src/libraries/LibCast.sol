// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/**
 * @title LibCast
 * @notice Fast hashing utilities for salt processing
 * @dev Used to process salts for CreateX CREATE3 deployments
 */
library LibCast {
    /**
     * @notice Fast keccak256 hash of two bytes32 values
     * @param a First value
     * @param b Second value
     * @return Hash of concatenated inputs
     */
    function hashFast(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b));
    }
}

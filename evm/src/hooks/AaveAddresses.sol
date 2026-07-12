// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @title AaveAddresses — Aave V3 / Spark-family Pool pins (supply-only hooks).
/// @dev HyperLend / SparkLend share IAaveV3Pool ABI → AaveV3YieldHook. Confirm aToken via getReserveData.
library AaveAddresses {
    /// @notice Aave V3 Pool (Ethereum).
    address internal constant AAVE_V3_POOL_ETH = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    /// @notice Aave V3 Pool (Base).
    address internal constant AAVE_V3_POOL_BASE = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;

    /// @notice SparkLend Pool (Ethereum) — same ABI as Aave V3.
    address internal constant SPARK_POOL_ETH = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;
}

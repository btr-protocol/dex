// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Maths as M} from "../../src/libraries/Maths.sol";
import {Oracle} from "../../src/libraries/Oracle.sol";
import {Constants as C} from "../../src/libraries/Constants.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";

/// @notice Minimal mock AccessControl exposing only `owner()`. Used to satisfy module
///         constructors after Phase 42H.B.1 dropped the per-pool $.owner auth path.
contract MockAC {
    address public owner;
    constructor(address o) { owner = o; }
    function rotate(address newOwner) external { owner = newOwner; }
}

/// @title BaseTestSetup
/// @notice Base contract for all tests, provides common utilities and fixtures
abstract contract BaseTestSetup is Test {

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════

    function setUp() public virtual {
        // Initialize any needed setup here
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // B64 TESTING UTILITIES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Create a B64 value from raw components
    /// @param mantissa Mantissa (52 bits)
    /// @param exponent Exponent (5 bits)
    /// @param decimal Decimal places (7 bits)
    function makeB64(uint64 mantissa, uint8 exponent, uint8 decimal)
        internal
        pure
        returns (uint64)
    {
        return (mantissa << 12) | (uint64(exponent) << 7) | uint64(decimal);
    }

    /// @notice Assert two B64 values are approximately equal (within tolerance)
    function assertB64Approx(
        uint64 actual,
        uint64 expected,
        uint64 tolerance,
        string memory message
    ) internal pure {
        uint64 diff = actual > expected ? actual - expected : expected - actual;
        require(diff <= tolerance, message);
    }

    /// @notice Create a B64 value from decimal number
    function toB64(uint256 value, uint8 decimals) internal pure returns (uint64) {
        return M.encodeB64(value, decimals);
    }

    /// @notice Convert B64 to decimal number
    function fromB64(uint64 b64, uint8 decimals) internal pure returns (uint256) {
        return M.decodeB64(b64, decimals);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ORACLE TESTING UTILITIES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Create a mock oracle feed data structure
    function makeFeedData(
        uint64 lastPriceB64,
        int32 fastOffset,
        int32 slowOffset,
        uint32 fastVolEMA,
        uint32 slowVolEMA
    ) internal view returns (IOracle.FeedData memory) {
        return IOracle.FeedData({
            lastPriceB64: lastPriceB64,
            fastOffset: fastOffset,
            slowOffset: slowOffset,
            fastVolEMA: fastVolEMA,
            slowVolEMA: slowVolEMA,
            updatedAt: uint32(block.timestamp),
            ttl: 3600,      // 1 hour
            confidence: 100 // Perfect confidence for testing
        });
    }

    /// @notice Get sigma (volatility) from feed data
    function getSigma(IOracle.FeedData memory feed) internal pure returns (uint32) {
        return Oracle.getSigma(feed);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ASSERTION HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function assertUint32Approx(
        uint32 actual,
        uint32 expected,
        uint32 tolerance,
        string memory message
    ) internal pure {
        uint32 diff = actual > expected ? actual - expected : expected - actual;
        require(diff <= tolerance, message);
    }

    function assertInt32Approx(
        int32 actual,
        int32 expected,
        int32 tolerance,
        string memory message
    ) internal pure {
        int32 diff = actual > expected ? actual - expected : expected - actual;
        require(diff <= tolerance, message);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS FOR TESTING
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 internal constant WAD = 1e18;
    uint256 internal constant ONE_PERCENT = 1e16;        // 1% in WAD
    uint256 internal constant ONE_BASIS_POINT = 1e14;    // 0.01% in WAD

    // B64 testing constants
    uint256 internal constant B64_MANTISSA_MAX = (1 << 52) - 1;
    uint256 internal constant B64_EXPONENT_MAX = (1 << 5) - 1;
    uint256 internal constant B64_DECIMAL_MAX = (1 << 7) - 1;

    // Volatility testing constants (1e6 units)
    uint32 internal constant VOL_0_1_PCT = 1_000;      // 0.1% in 1e6 units
    uint32 internal constant VOL_1_PCT = 10_000;       // 1% in 1e6 units
    uint32 internal constant VOL_10_PCT = 100_000;     // 10% in 1e6 units
    uint32 internal constant VOL_50_PCT = 500_000;     // 50% in 1e6 units
    uint32 internal constant VOL_MAX = 1_000_000;      // 100% in 1e6 units

    // Offset testing constants (0.0001% units)
    int32 internal constant OFFSET_100_BPS = 100_000;   // 1% in 0.0001% units
    int32 internal constant OFFSET_500_BPS = 500_000;   // 5% in 0.0001% units
    int32 internal constant OFFSET_NEGATIVE_1_PCT = -100_000;  // -1% in 0.0001% units

    // Oracle precision constants
    uint256 internal constant OFFSET_PRECISION = 10_000_000;
}

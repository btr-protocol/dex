// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";

/// @notice Minimal mock AccessControl exposing owner / keeper / guardian / riskSteward.
contract MockAC {
  address public owner;
  address public treasuryOwner;
  mapping(address => bool) public isKeeper;
  mapping(address => bool) public isGuardian;
  mapping(address => bool) public isRiskSteward;

  constructor(address o) {
    owner = o;
    treasuryOwner = o;
  }

  function rotate(address newOwner) external {
    owner = newOwner;
  }

  function rotateTreasuryOwner(address t) external {
    treasuryOwner = t;
  }

  function setKeeper(address k, bool s) external {
    isKeeper[k] = s;
  }

  function setGuardian(address g, bool s) external {
    isGuardian[g] = s;
  }

  function setRiskSteward(address s, bool ok) external {
    isRiskSteward[s] = ok;
  }

  function isGuardianOrAuth(address sender, address auth) external view returns (bool) {
    return sender == auth || isGuardian[sender];
  }
}

/// @notice Multi-feed external IOracle for pool tests. Pools wire `primary = address(this)` and
///         `feedId = feedIdFor(token)`; seed a fresh mark per token via `setMark`. Mirrors the
///         external-mark model (lastPrice = quote source), so quoting reads a fresh, keeper-pushed
///         mark rather than any internal accumulator.
contract MockOracle is IOracle {
  mapping(bytes32 => FeedData) internal feeds;

  /// @notice One feed per token (pool-test convention).
  function feedIdFor(address token) public pure returns (bytes32) {
    return bytes32(uint256(uint160(token)));
  }

  /// @notice Seed/refresh a mark at default σ=1%, confidence=0, ttl=max.
  function setMark(address token, uint64 priceB64) external {
    _set(feedIdFor(token), priceB64, uint32(SC.ONE_PCT_PBPS), 0, type(uint16).max);
  }

  /// @notice Full control (id, price, σ, CI, ttl) for staleness/confidence tests.
  function setFeed(bytes32 id, uint64 priceB64, uint32 sigma, uint16 confidence, uint16 ttl)
    external
  {
    _set(id, priceB64, sigma, confidence, ttl);
  }

  function _set(bytes32 id, uint64 priceB64, uint32 sigma, uint16 confidence, uint16 ttl) internal {
    feeds[id] = FeedData({
      lastPriceB64: priceB64,
      sigma: sigma,
      updatedAt: uint32(block.timestamp),
      ttl: ttl,
      confidence: confidence,
      flags: 0,
      maxDeviation: 0,
      sourceTs: 0
    });
  }

  function getFeed(bytes32 id) external view returns (FeedData memory f) {
    f = feeds[id];
  }

  function isFeedFresh(bytes32 id, uint32 maxAge) external view returns (bool) {
    FeedData storage f = feeds[id];
    if (f.updatedAt == 0) return false;
    unchecked {
      return block.timestamp - f.updatedAt <= maxAge;
    }
  }

  function isFeedFresh(bytes32 id) external view returns (bool) {
    FeedData storage f = feeds[id];
    if (f.updatedAt == 0) return false;
    unchecked {
      return block.timestamp - f.updatedAt <= f.ttl;
    }
  }
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
  function makeB64(uint64 mantissa, uint8 exponent, uint8 decimal) internal pure returns (uint64) {
    return (mantissa << 12) | (uint64(exponent) << 7) | uint64(decimal);
  }

  /// @notice Assert two B64 values are approximately equal (within tolerance)
  function assertB64Approx(uint64 actual, uint64 expected, uint64 tolerance, string memory message)
    internal
    pure
  {
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
  // DEFAULT PRESET CURVE (quartic I-spline)
  // ═══════════════════════════════════════════════════════════════════════════

  /// @dev Canonical test preset: near-linear monotone quartic spanning ±500 pbps at dispRef=1000 —
  ///      the shape-scale twin of the retired Hermite default (knots ±50 × dispersion). Install via
  ///      `admin.setCurve(pool, DEFAULT_PRESET, defaultCurveInterior(), defaultCurveWQ(), 1000, 0)`
  ///      BEFORE the first addAsset referencing DEFAULT_PRESET.
  uint16 internal constant DEFAULT_PRESET = 1;

  function defaultCurveInterior() internal pure returns (uint256[] memory it) {
    it = new uint256[](4);
    (it[0], it[1], it[2], it[3]) = (2000, 4000, 6000, 8000);
  }

  function defaultCurveWQ() internal pure returns (int256[] memory wQ) {
    wQ = new int256[](9);
    for (uint256 i = 0; i < 9; ++i) {
      wQ[i] = -500e9 + int256(i) * 125e9; // linear ramp −500..+500 pbps·Q
    }
  }

  /// @notice Build a FeedData directly (external-mark model).
  function makeFeedData(uint64 priceB64, uint32 sigma, uint16 confidence)
    internal
    view
    returns (IOracle.FeedData memory)
  {
    return IOracle.FeedData({
      lastPriceB64: priceB64,
      sigma: sigma,
      updatedAt: uint32(block.timestamp),
      ttl: 3600,
      confidence: confidence,
      flags: 0,
      maxDeviation: 0,
      sourceTs: 0
    });
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

  function assertInt32Approx(int32 actual, int32 expected, int32 tolerance, string memory message)
    internal
    pure
  {
    int32 diff = actual > expected ? actual - expected : expected - actual;
    require(diff <= tolerance, message);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // CONSTANTS FOR TESTING
  // ═══════════════════════════════════════════════════════════════════════════

  uint256 internal constant WAD = 1e18;
  uint256 internal constant ONE_PERCENT = 1e16; // 1% in WAD
  uint256 internal constant ONE_BASIS_POINT = 1e14; // 0.01% in WAD

  // B64 testing constants
  uint256 internal constant B64_MANTISSA_MAX = (1 << 52) - 1;
  uint256 internal constant B64_EXPONENT_MAX = (1 << 5) - 1;
  uint256 internal constant B64_DECIMAL_MAX = (1 << 7) - 1;

  // Volatility testing constants (1e6 units)
  uint32 internal constant VOL_0_1_PCT = 1_000; // 0.1% in 1e6 units
  uint32 internal constant VOL_1_PCT = 10_000; // 1% in 1e6 units
  uint32 internal constant VOL_10_PCT = 100_000; // 10% in 1e6 units
  uint32 internal constant VOL_50_PCT = 500_000; // 50% in 1e6 units
  uint32 internal constant VOL_MAX = 1_000_000; // 100% in 1e6 units
}

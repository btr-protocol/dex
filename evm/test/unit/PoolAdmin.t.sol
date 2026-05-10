// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {PoolAdmin} from "../../src/libraries/PoolAdmin.sol";
import {PoolOracle} from "../../src/libraries/PoolOracle.sol";
import {Maths as M} from "../../src/libraries/Maths.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @notice Mock IOracle that returns a canned FeedData (or reverts) on getFeed.
contract MockOracle {
    bool public shouldRevert;
    function setRevert(bool v) external { shouldRevert = v; }
    function getFeed(bytes32) external view returns (IOracle.FeedData memory d) {
        if (shouldRevert) revert("mock-oracle-revert");
        d.lastPriceB64 = 1;
    }
}

/// @notice Harness exposing PoolAdmin internals over a slot-0 PoolStorage instance.
contract PoolAdminHarness {
    IPool.PoolStorage internal $;

    function setBaseToken(address t) external { $.baseToken = t; }
    function getAsset(address t) external view returns (IPool.Asset memory) { return $.assets[t]; }
    function getOracleConfig(address t) external view returns (IPool.OracleConfig memory) { return $.oracleConfigs[t]; }
    function getRiskConfig(address t) external view returns (IPool.RiskConfig memory) { return $.riskConfigs[t]; }
    function getProfile(address t) external view returns (IPool.LiquidityProfile memory) { return $.profiles[t]; }
    function getAccumulator(address t) external view returns (IPool.FeedAccumulator memory) { return $.accumulators[t]; }

    function callValidateProfileMemory(IPool.LiquidityProfile memory p) external pure {
        PoolAdmin.validateProfileMemory(p);
    }

    function callValidateOracleConfig(IPool.OracleConfig memory cfg, address self) external view {
        PoolAdmin.validateOracleConfig(cfg, self);
    }

    function callInitAsset(
        address t,
        uint8 decimals,
        uint16 minFeeBps,
        uint32 minDispersion,
        uint32 maxDispersion,
        uint16 gamma,
        uint16 vega,
        uint16 lambda
    ) external {
        PoolAdmin.initAsset($, t, decimals, minFeeBps, minDispersion, maxDispersion, gamma, vega, lambda);
    }

    function callSetupOracleAndConfig(
        address self,
        address t,
        IPool.OracleConfig memory oracleCfg,
        IPool.RiskConfig memory riskCfg,
        IPool.LiquidityProfile memory profile,
        uint64 initialPrice,
        uint32 fastVol,
        uint32 slowVol
    ) external {
        PoolAdmin.setupOracleAndConfig($, self, t, oracleCfg, riskCfg, profile, initialPrice, fastVol, slowVol);
    }
}

/// @title PoolAdminTest
/// @notice Phase 42H.D · Round 3 (G8) — direct unit tests for PoolAdmin library.
///         Covers validateProfileMemory edge cases, validateOracleConfig boundaries,
///         initAsset full path (base vs non-base, default fallbacks), and
///         setupOracleAndConfig integration (self-oracle seeding + non-self skip).
contract PoolAdminTest is Test {
    PoolAdminHarness h;
    MockOracle mock;
    address constant BASE = address(0xBA5E);
    address constant TKA = address(0xA1);

    function setUp() public {
        h = new PoolAdminHarness();
        mock = new MockOracle();
        h.setBaseToken(BASE);
        vm.warp(1_700_000_000);
    }

    function _validProfile() internal pure returns (IPool.LiquidityProfile memory p) {
        // 2 segments, weights sum=200, knots span 100.
        p.weights[0] = 100;
        p.weights[1] = 100;
        p.knots[0] = -50;
        p.knots[1] = 0;
        p.knots[2] = 50;
    }

    // ─── validateProfileMemory ───

    function test_validateProfile_validPasses() public view {
        h.callValidateProfileMemory(_validProfile());
    }

    function test_validateProfile_revertsOnZeroFirstWeight() public {
        IPool.LiquidityProfile memory p = _validProfile();
        p.weights[0] = 0;
        vm.expectRevert(Err.InvalidInput.selector);
        h.callValidateProfileMemory(p);
    }

    function test_validateProfile_revertsOnSumNot200() public {
        IPool.LiquidityProfile memory p = _validProfile();
        p.weights[1] = 50; // sum=150
        vm.expectRevert(Err.InvalidInput.selector);
        h.callValidateProfileMemory(p);
    }

    function test_validateProfile_revertsOnNonMonotonicKnots() public {
        IPool.LiquidityProfile memory p = _validProfile();
        p.knots[1] = -60; // < knots[0]
        vm.expectRevert(Err.InvalidInput.selector);
        h.callValidateProfileMemory(p);
    }

    function test_validateProfile_revertsOnSpanNot100() public {
        IPool.LiquidityProfile memory p = _validProfile();
        p.knots[2] = 49; // span = 49 - (-50) = 99
        vm.expectRevert(Err.InvalidInput.selector);
        h.callValidateProfileMemory(p);
    }

    // ─── validateOracleConfig ───

    function test_validateOracle_revertsOnZeroPrimary() public {
        IPool.OracleConfig memory cfg;
        cfg.primary = address(0);
        vm.expectRevert(Err.InvalidInput.selector);
        h.callValidateOracleConfig(cfg, address(h));
    }

    function test_validateOracle_selfPrimaryBypassesGetFeed() public view {
        IPool.OracleConfig memory cfg;
        cfg.primary = address(h); // self
        h.callValidateOracleConfig(cfg, address(h));
    }

    function test_validateOracle_externalPrimaryReachable() public view {
        IPool.OracleConfig memory cfg;
        cfg.primary = address(mock);
        h.callValidateOracleConfig(cfg, address(h));
    }

    function test_validateOracle_externalPrimaryReverts() public {
        mock.setRevert(true);
        IPool.OracleConfig memory cfg;
        cfg.primary = address(mock);
        vm.expectRevert(Err.InvalidInput.selector);
        h.callValidateOracleConfig(cfg, address(h));
    }

    function test_validateOracle_secondaryReverts() public {
        MockOracle bad = new MockOracle();
        bad.setRevert(true);
        IPool.OracleConfig memory cfg;
        cfg.primary = address(mock);
        cfg.secondary = address(bad);
        vm.expectRevert(Err.InvalidInput.selector);
        h.callValidateOracleConfig(cfg, address(h));
    }

    // ─── initAsset ───

    function test_initAsset_baseTokenHasNoAnchor() public {
        h.callInitAsset(BASE, 18, 30, 0, 0, 0, 0, 0);
        IPool.Asset memory a = h.getAsset(BASE);
        assertEq(a.decimals, 18);
        assertEq(a.minFeeBps, 30);
        assertEq(a.maxFeeBps, 10000);
        assertEq(a.anchor, address(0), "base has no anchor");
        assertEq(a.anchorDepth, 0);
        // Defaults applied on zero inputs.
        assertEq(a.minDispersion, 1000);
        assertEq(a.maxDispersion, 100000);
        assertEq(a.gamma, 10000);
        assertEq(a.vega, 10000);
        assertEq(a.lambda, 10000);
        assertEq(a.haircutSuppressor, 10000);
    }

    function test_initAsset_nonBaseAnchorsToBase() public {
        h.callInitAsset(TKA, 6, 25, 500, 50000, 8000, 9000, 9500);
        IPool.Asset memory a = h.getAsset(TKA);
        assertEq(a.decimals, 6);
        assertEq(a.minFeeBps, 25);
        assertEq(a.anchor, BASE, "non-base anchors to baseToken");
        assertEq(a.anchorDepth, 1);
        assertEq(a.minDispersion, 500);
        assertEq(a.maxDispersion, 50000);
        assertEq(a.gamma, 8000);
        assertEq(a.vega, 9000);
        assertEq(a.lambda, 9500);
    }

    // ─── setupOracleAndConfig ───

    function test_setupOracleAndConfig_writesAllSlots() public {
        IPool.OracleConfig memory oc;
        oc.primary = address(mock);
        oc.feedId = bytes32(uint256(1));
        IPool.RiskConfig memory rc;
        rc.decayStartRatioBps = 5000;
        IPool.LiquidityProfile memory p = _validProfile();

        h.callSetupOracleAndConfig(
            address(h), TKA, oc, rc, p,
            M.encodeB64(1e18, 6), uint32(100), uint32(50)
        );

        assertEq(h.getOracleConfig(TKA).primary, address(mock));
        assertEq(h.getRiskConfig(TKA).decayStartRatioBps, 5000);
        assertEq(uint256(h.getProfile(TKA).weights[0]), 100);
        // Non-self primary → no accumulator seeding.
        assertEq(h.getAccumulator(TKA).lastUpdate, 0, "non-self oracle skips initFeed");
    }

    function test_setupOracleAndConfig_selfOracleSeedsAccumulator() public {
        IPool.OracleConfig memory oc;
        oc.primary = address(h); // self
        oc.accDecimals = 0; // → defaults to 6
        IPool.RiskConfig memory rc;
        IPool.LiquidityProfile memory p = _validProfile();
        uint64 px = M.encodeB64(1500e18, 6);

        h.callSetupOracleAndConfig(
            address(h), TKA, oc, rc, p, px, uint32(123), uint32(456)
        );

        IPool.FeedAccumulator memory acc = h.getAccumulator(TKA);
        assertEq(acc.lastPriceB64, px);
        assertEq(acc.accDecimals, 6, "default accDecimals=6");
        assertEq(acc.fastVolEMA, 123);
        assertEq(acc.slowVolEMA, 456);
        assertEq(acc.lastUpdate, uint32(block.timestamp));
        assertEq(acc.confidence, 100);
        assertEq(acc.ttl, PoolOracle.DEFAULT_TTL);
    }
}

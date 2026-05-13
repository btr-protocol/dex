// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {PoolEdge} from "../../src/libraries/PoolEdge.sol";
import {PoolOracle} from "../../src/libraries/PoolOracle.sol";
import {Maths as M} from "../../src/libraries/Maths.sol";

/// @notice Harness mirroring Pool.sol's midPrice / pokeMidPrice surface.
/// @dev    Slot-0 PoolStorage; midPrice is `view` and pokeMidPrice mutates
///         (writes transient TCache via PoolOracle.readOracle).
contract MidPriceHarness {
    using M for uint64;
    IPool.PoolStorage internal $;

    function setAccumulator(
        address tk,
        uint64 lastPriceB64,
        uint8 accDecimals,
        uint32 lastUpdate,
        uint16 ttl
    ) external {
        IPool.FeedAccumulator storage acc = $.accumulators[tk];
        acc.lastPriceB64 = lastPriceB64;
        acc.accDecimals = accDecimals;
        acc.lastUpdate = lastUpdate;
        acc.ttl = ttl;
        acc.confidence = 100;
    }

    function setSelfPrimaryOracle(address tk) external {
        $.oracleConfigs[tk].primary = address(this);
    }

    function getAccumulator(address tk) external view returns (IPool.FeedAccumulator memory) {
        return $.accumulators[tk];
    }

    /// @notice Mirrors `Pool.midPrice` — pure view, reads cached b64 price.
    function midPrice(address tk) external view returns (uint256) {
        return $.accumulators[tk].lastPriceB64.b64To1e18();
    }

    /// @notice Mirrors `Pool.pokeMidPrice` — non-view (writes TCache).
    function pokeMidPrice(address tk) external returns (uint256) {
        return PoolEdge.pokeMidPrice($, address(this), tk);
    }
}

/// @title PoolMidPriceTest
/// @notice Wave-3b Cohort-2 follow-up: view-vs-mutating split of midPrice/pokeMidPrice.
contract PoolMidPriceTest is Test {
    MidPriceHarness h;
    address constant TKA = address(0xA1);

    function setUp() public {
        h = new MidPriceHarness();
        vm.warp(1_700_000_000);
    }

    function test_midPrice_isView_callableViaStaticcall() public {
        uint64 px = M.encodeB64(1_500e18, 6);
        h.setAccumulator(TKA, px, 6, uint32(block.timestamp), PoolOracle.DEFAULT_TTL);

        IPool.FeedAccumulator memory before = h.getAccumulator(TKA);

        // Static call must succeed for a true `view` fn.
        (bool ok, bytes memory ret) =
            address(h).staticcall(abi.encodeWithSelector(h.midPrice.selector, TKA));
        assertTrue(ok, "midPrice must be callable via staticcall");
        uint256 decoded = abi.decode(ret, (uint256));
        assertEq(decoded, M.b64To1e18(px), "midPrice returns b64To1e18(lastPriceB64)");

        // No state change.
        IPool.FeedAccumulator memory afterAcc = h.getAccumulator(TKA);
        assertEq(afterAcc.lastUpdate, before.lastUpdate);
        assertEq(afterAcc.lastPriceB64, before.lastPriceB64);
    }

    function test_pokeMidPrice_mutatesAccumulator() public {
        // Configure self-primary oracle + fresh accumulator → pokeMidPrice
        // takes the self-primary fresh path which writes to transient cache
        // (TSTORE). TSTORE is forbidden in staticcall, so pokeMidPrice MUST
        // NOT be staticcall-able. That proves the non-view nature.
        uint64 px = M.encodeB64(2_000e18, 6);
        h.setAccumulator(TKA, px, 6, uint32(block.timestamp), PoolOracle.DEFAULT_TTL);
        h.setSelfPrimaryOracle(TKA);

        // 1. Direct (non-static) call succeeds and returns the converted price.
        uint256 result = h.pokeMidPrice(TKA);
        assertEq(result, M.b64To1e18(px), "pokeMidPrice returns b64To1e18(lastPriceB64)");

        // 2. Fresh token (no TCache hit) → readOracle reaches TSTORE
        //    cacheOracleFeed branch → static call MUST fail.
        address freshTk = address(0xBEEF);
        h.setAccumulator(freshTk, px, 6, uint32(block.timestamp), PoolOracle.DEFAULT_TTL);
        h.setSelfPrimaryOracle(freshTk);
        (bool ok,) =
            address(h).staticcall(abi.encodeWithSelector(h.pokeMidPrice.selector, freshTk));
        assertFalse(ok, "pokeMidPrice must NOT be staticcall-able (mutates TCache)");
    }

    function test_midPrice_returnsLastPrice() public {
        // Accumulator with known b64-encoded price → midPrice converts via b64To1e18.
        uint64 px = M.encodeB64(1_234_567e12, 6); // arbitrary 1e18-domain value
        h.setAccumulator(TKA, px, 6, uint32(block.timestamp), PoolOracle.DEFAULT_TTL);

        uint256 got = h.midPrice(TKA);
        assertEq(got, M.b64To1e18(px), "midPrice mirrors b64To1e18 of stored accumulator price");
        assertGt(got, 0, "non-zero output for non-zero input");
    }
}

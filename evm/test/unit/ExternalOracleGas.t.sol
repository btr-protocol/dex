// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ExternalOracle} from "../../src/oracles/ExternalOracle.sol";
import {Maths as M} from "../../src/libraries/Maths.sol";
import {MockAC} from "../fixtures/BaseTestSetup.sol";

/// @title ExternalOracleGasTest
/// @notice Gas benchmarks for the hot path: batchPush at N=1..30 feeds (warm slots, non-zero ->
///         non-zero SSTORE), matching the steady-state keeper cadence (thousands of txs/day,
///         multi-chain). Each N test logs total + per-feed marginal vs the N=1 fixed cost.
contract ExternalOracleGasTest is Test {
    ExternalOracle ext;
    uint32 constant TAU = 100;
    uint256 constant MAX_N = 30;
    bytes32[] feedIdList;

    function setUp() public {
        ext = new ExternalOracle(address(new MockAC(address(this))), address(this));
        vm.warp(1_700_000_000);
        for (uint256 i; i < MAX_N; ++i) {
            address base = address(uint160(0xB000 + i));
            address quote = address(uint160(0x9000 + i));
            ext.addFeed(base, quote, M.encodeB64(3000e18, 18), 1e4, 5, uint16(TAU), uint16(TAU), ext.MAX_DEV_THRESHOLD(), 3600);
            feedIdList.push(keccak256(abi.encodePacked(base, quote)));
        }
        // Warm push so benchmarks measure steady-state (non-zero slots, dt > 0).
        vm.warp(block.timestamp + TAU);
        _batch(MAX_N);
        vm.warp(block.timestamp + TAU);
    }

    function _batch(uint256 n) internal returns (uint256 gasUsed) {
        bytes32[] memory ids = new bytes32[](n);
        uint64[] memory prices = new uint64[](n);
        uint32[] memory sigmas = new uint32[](n);
        uint16[] memory confs = new uint16[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = feedIdList[i];
            prices[i] = M.encodeB64(3010e18, 18);
            sigmas[i] = 1e4;
            confs[i] = 5;
        }
        uint256 g = gasleft();
        ext.batchPush(ids, prices, sigmas, confs);
        gasUsed = g - gasleft();
    }

    function _bench(uint256 n) internal {
        uint256 g = _batch(n);
        console2.log("batchPush feeds:", n);
        console2.log("  total gas:", g);
        console2.log("  gas per feed:", g / n);
    }

    function test_gas_batchPush_1feed() public { _bench(1); }
    function test_gas_batchPush_6feeds() public { _bench(6); }
    function test_gas_batchPush_8feeds() public { _bench(8); }
    function test_gas_batchPush_10feeds() public { _bench(10); }
    function test_gas_batchPush_12feeds() public { _bench(12); }
    function test_gas_batchPush_20feeds() public { _bench(20); }
    function test_gas_batchPush_30feeds() public { _bench(30); }
}

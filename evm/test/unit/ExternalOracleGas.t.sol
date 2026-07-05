// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ExternalOracle} from "../../src/oracles/ExternalOracle.sol";
import {Maths as M} from "../../src/libraries/Maths.sol";
import {MockAC} from "../fixtures/BaseTestSetup.sol";

/// @title ExternalOracleGasTest
/// @notice Gas benchmarks for the hot path: batchPush 1 vs 6 feeds (warm slots, non-zero -> non-zero
///         SSTORE), matching the steady-state keeper cadence (thousands of txs/day, multi-chain).
contract ExternalOracleGasTest is Test {
    ExternalOracle ext;
    uint32 constant TAU = 100;
    uint256 constant N = 6;
    bytes32[] ids6;

    function setUp() public {
        ext = new ExternalOracle(address(new MockAC(address(this))), address(this));
        vm.warp(1_700_000_000);
        for (uint256 i; i < N; ++i) {
            address base = address(uint160(0xB000 + i));
            address quote = address(uint160(0x9000 + i));
            ext.addFeed(base, quote, M.encodeB64(3000e18, 18), 1e4, 5, TAU, 0, 3600);
            ids6.push(keccak256(abi.encodePacked(base, quote)));
        }
        // Warm push so benchmarks measure steady-state (non-zero slots, dt > 0).
        vm.warp(block.timestamp + TAU);
        _batch(N);
        vm.warp(block.timestamp + TAU);
    }

    function _batch(uint256 n) internal returns (uint256 gasUsed) {
        bytes32[] memory ids = new bytes32[](n);
        uint64[] memory prices = new uint64[](n);
        uint32[] memory sigmas = new uint32[](n);
        uint16[] memory confs = new uint16[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = ids6[i];
            prices[i] = M.encodeB64(3010e18, 18);
            sigmas[i] = 1e4;
            confs[i] = 5;
        }
        uint256 g = gasleft();
        ext.batchPush(ids, prices, sigmas, confs);
        gasUsed = g - gasleft();
    }

    function test_gas_batchPush_1feed() public {
        console2.log("batchPush 1 feed (steady-state):", _batch(1));
    }

    function test_gas_batchPush_6feeds() public {
        uint256 g = _batch(6);
        console2.log("batchPush 6 feeds (steady-state):", g);
        console2.log("  per-feed marginal:", g / 6);
    }
}

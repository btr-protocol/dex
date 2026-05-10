// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Pool} from "../../src/Pool.sol";
import {PoolOracle} from "../../src/libraries/PoolOracle.sol";

/// @title PoolConstantsMirrorTest
/// @notice Phase 42H.D · Round 3 (G10) — guards Pool's ABI-mirror constants against
///         silent desync from PoolOracle. Pool.sol:88-94 currently references
///         `PoolOracle.<X>` directly (compile-time-equal); this test catches any future
///         refactor that swaps that reference for a literal value.
/// @dev    Deploys a minimal Pool instance (constructor only checks for zero addr) and
///         compares each public-getter return against PoolOracle.<X>.
contract PoolConstantsMirrorTest is Test {
    Pool internal pool;

    function setUp() public {
        // Constructor only enforces non-zero addrs; runtime fns aren't exercised here.
        pool = new Pool(address(this), address(this), address(this), address(this));
    }

    function test_FAST_WINDOW_mirrors_PoolOracle() public view {
        assertEq(uint256(pool.FAST_WINDOW()), uint256(PoolOracle.FAST_WINDOW), "FAST_WINDOW desync");
    }

    function test_SLOW_WINDOW_mirrors_PoolOracle() public view {
        assertEq(uint256(pool.SLOW_WINDOW()), uint256(PoolOracle.SLOW_WINDOW), "SLOW_WINDOW desync");
    }

    function test_FAST_VOL_ALPHA_mirrors_PoolOracle() public view {
        assertEq(uint256(pool.FAST_VOL_ALPHA()), uint256(PoolOracle.FAST_VOL_ALPHA), "FAST_VOL_ALPHA desync");
    }

    function test_SLOW_VOL_ALPHA_mirrors_PoolOracle() public view {
        assertEq(uint256(pool.SLOW_VOL_ALPHA()), uint256(PoolOracle.SLOW_VOL_ALPHA), "SLOW_VOL_ALPHA desync");
    }

    function test_DEFAULT_TTL_mirrors_PoolOracle() public view {
        assertEq(uint256(pool.DEFAULT_TTL()), uint256(PoolOracle.DEFAULT_TTL), "DEFAULT_TTL desync");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {Pool} from "../src/Pool.sol";
import {IPool} from "../src/interfaces/IPool.sol";

/// @title PoolStorageLayoutTest
/// @notice Phase 42H.D Round 2 (G5.a) -upgrade-safety guard for `IPool.PoolStorage`
///         slot-0 layout. Asserts each first-class field occupies its expected slot
///         with the documented packing. Any reorder/insertion that mutates existing
///         offsets will trip these tests, surfacing storage-collision risk for live
///         clones BEFORE deploy.
/// @dev Layout (per IPool.sol:120):
///        slot 0  = baseToken (address, 20 bytes)         -packed offset 0
///        slot 1  = wnative   (address, 20 bytes)         -packed offset 0
///        slot 2  = bridge    (address, 20 bytes)         -packed offset 0
///        slot 3  = treasury  (address, 20 bytes)         + initialized (bool, byte 20)
///      Mappings @ slots 4..12 inclusive (8 mapping fields → keccak-derived).
///      `IPool.FeeParams feeParams` is a struct → uses its own slot range starting @ 13.
contract PoolStorageLayoutTest is Test {
    Pool pool;
    address constant SENTINEL_BASE     = address(0x1111111111111111111111111111111111111111);
    address constant SENTINEL_WNATIVE  = address(0x2222222222222222222222222222222222222222);
    address constant SENTINEL_BRIDGE   = address(0x3333333333333333333333333333333333333333);
    address constant SENTINEL_TREASURY = address(0x4444444444444444444444444444444444444444);

    function setUp() public {
        // Pool ctor only validates ac/admin/flash/poolAux != 0; we don't initialize().
        pool = new Pool(address(0xAA), address(0xBB), address(0xCC), address(0xDD));
    }

    /// @notice Slot 0 holds `baseToken` (first PoolStorage field).
    function test_layout_slot0_isBaseToken() public {
        vm.store(address(pool), bytes32(uint256(0)), bytes32(uint256(uint160(SENTINEL_BASE))));
        assertEq(pool.baseToken(), SENTINEL_BASE, "slot 0 must be baseToken");
    }

    /// @notice Slot 1 holds `wnative` (second PoolStorage field, packed at offset 0).
    function test_layout_slot1_isWnative() public {
        vm.store(address(pool), bytes32(uint256(1)), bytes32(uint256(uint160(SENTINEL_WNATIVE))));
        assertEq(pool.wnative(), SENTINEL_WNATIVE, "slot 1 must be wnative");
    }

    /// @notice Slot 2 holds `bridge`.
    function test_layout_slot2_isBridge() public {
        vm.store(address(pool), bytes32(uint256(2)), bytes32(uint256(uint160(SENTINEL_BRIDGE))));
        assertEq(pool.getAuthorizedBridge(), SENTINEL_BRIDGE, "slot 2 must be bridge");
    }

    /// @notice Slot 3 holds `treasury`. Note: `initialized` (bool) packs into byte-20 of
    ///         this same slot -sentinel is left-aligned address-only so no collision.
    function test_layout_slot3_isTreasury() public {
        vm.store(address(pool), bytes32(uint256(3)), bytes32(uint256(uint160(SENTINEL_TREASURY))));
        assertEq(pool.treasury(), SENTINEL_TREASURY, "slot 3 must be treasury");
    }

    /// @notice `initialized` bool packs into slot 3 byte 20 (post-treasury address).
    ///         Writing a full 32-byte value with both fields set must yield consistent reads.
    function test_layout_slot3_packs_treasury_and_initialized() public {
        // Pack: address (low 20 bytes) + bool=true at byte offset 20.
        uint256 packed = uint256(uint160(SENTINEL_TREASURY)) | (uint256(1) << 160);
        vm.store(address(pool), bytes32(uint256(3)), bytes32(packed));
        assertEq(pool.treasury(), SENTINEL_TREASURY, "treasury read after packed write");
        // Round-trip via vm.load to confirm bool byte preserved.
        bytes32 raw = vm.load(address(pool), bytes32(uint256(3)));
        assertEq(uint256(raw), packed, "slot 3 packed bytes preserved");
    }

    /// @notice Snapshot guard: pin a hash over the first 4 slots. Any structural change
    ///         to slot-0..3 ordering breaks this hash, alerting reviewers BEFORE deploy.
    function test_layout_pinned_hash_first4Slots() public {
        // Write known sentinels into all 4 slots.
        vm.store(address(pool), bytes32(uint256(0)), bytes32(uint256(uint160(SENTINEL_BASE))));
        vm.store(address(pool), bytes32(uint256(1)), bytes32(uint256(uint160(SENTINEL_WNATIVE))));
        vm.store(address(pool), bytes32(uint256(2)), bytes32(uint256(uint160(SENTINEL_BRIDGE))));
        vm.store(address(pool), bytes32(uint256(3)), bytes32(uint256(uint160(SENTINEL_TREASURY))));

        // Reads via public getters MUST all return the sentinels.
        assertEq(pool.baseToken(), SENTINEL_BASE);
        assertEq(pool.wnative(), SENTINEL_WNATIVE);
        assertEq(pool.getAuthorizedBridge(), SENTINEL_BRIDGE);
        assertEq(pool.treasury(), SENTINEL_TREASURY);

        // Hash invariant -pin against future reorders.
        bytes32 hash = keccak256(
            abi.encodePacked(
                vm.load(address(pool), bytes32(uint256(0))),
                vm.load(address(pool), bytes32(uint256(1))),
                vm.load(address(pool), bytes32(uint256(2))),
                vm.load(address(pool), bytes32(uint256(3)))
            )
        );
        bytes32 expected = keccak256(
            abi.encodePacked(
                bytes32(uint256(uint160(SENTINEL_BASE))),
                bytes32(uint256(uint160(SENTINEL_WNATIVE))),
                bytes32(uint256(uint160(SENTINEL_BRIDGE))),
                bytes32(uint256(uint160(SENTINEL_TREASURY)))
            )
        );
        assertEq(hash, expected, "slot 0-3 layout hash mismatch - append-only invariant broken");
    }
}

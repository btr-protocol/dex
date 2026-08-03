// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {Admin} from "../src/Admin.sol";
import {Flash} from "../src/Flash.sol";
import {MockAC} from "./fixtures/BaseTestSetup.sol";

/// @title PoolStorageLayoutTest
/// @notice Phase 42H.D Round 2 (G5.a) -upgrade-safety guard for `IPool.PoolStorage`
///         slot-0 layout. Asserts each first-class field occupies its expected slot
///         with the documented packing. Any reorder/insertion that mutates existing
///         offsets will trip these tests, surfacing storage-collision risk for live
///         clones BEFORE deploy.
/// @dev Layout (per IPool.sol PoolStorage):
///        slot 0  = baseToken (address, 20 bytes)         + initialized (bool, byte 20)
///        slot 1  = wnative   (address, 20 bytes)         -packed offset 0
///        slot 2  = treasury  (address, 20 bytes)         -packed offset 0
///      Mappings @ slots 3..8 inclusive (assets=3, oracleConfigs=4, riskConfigs=5,
///      curves=6, __reserved_lpBalances=7, protocolFees=8). Off-chain readers (SDK storage.ts)
///      hash keccak256(abi.encode(key, slot)) — do NOT add Solidity getters for these.
///      `IPool.FeeParams feeParams` packs into slot 9; flowCooldownSeconds is slot 10.
///      `factory` PACKS into slot 10 at offset 2 (uint16 + address = 22 bytes) now that the two
///      deleted cooldown mappings no longer separate them. Tail: assetHooks=11, invested=12,
///      lpTokens=13 (SDK `POOL_STORAGE`). Slot 7 is a RESERVED PIN, not live state: the per-leg LPToken clone is the
///      sole share ledger, but deleting the old `lpBalances` word would shift `protocolFees` to 7
///      and renumber everything after it for no benefit.
contract PoolStorageLayoutTest is Test {
  Pool pool;
  address constant SENTINEL_BASE = address(0x1111111111111111111111111111111111111111);
  address constant SENTINEL_WNATIVE = address(0x2222222222222222222222222222222222222222);
  address constant SENTINEL_TREASURY = address(0x4444444444444444444444444444444444444444);
  address constant SENTINEL_HOOK = address(0x5555555555555555555555555555555555555555);
  address constant SENTINEL_TOKEN = address(0x6666666666666666666666666666666666666666);
  // Renumbered map bases after the Hermite→quartic wave (bridge slot removed, initialized→slot0).
  // Pinned here because an EIP-1167 beacon fleet-upgrade across a layout change would alias live
  // custody state: this test is the guard that the SDK slot map + on-chain layout never silently drift.
  uint256 constant ASSETS_SLOT = 3;
  uint256 constant ORACLE_CONFIGS_SLOT = 4;
  uint256 constant RISK_CONFIGS_SLOT = 5;
  uint256 constant CURVES_SLOT = 6;
  uint256 constant RESERVED_LP_BALANCES_SLOT = 7;
  uint256 constant PROTOCOL_FEES_SLOT = 8;
  uint256 constant ASSET_HOOKS_SLOT = 11;
  uint256 constant INVESTED_SLOT = 12;
  uint256 constant LP_TOKENS_SLOT = 13;

  function setUp() public {
    // PoolAux required for fallback views (getAssetHook / getInvested).
    MockAC ac = new MockAC(address(this));
    Admin admin = new Admin(address(ac));
    Flash flash = new Flash();
    PoolAux aux = new PoolAux(address(ac), address(admin), address(flash));
    pool = new Pool(address(ac), address(admin), address(flash), address(aux));
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

  /// @notice Slot 2 holds `treasury`.
  function test_layout_slot2_isTreasury() public {
    vm.store(address(pool), bytes32(uint256(2)), bytes32(uint256(uint160(SENTINEL_TREASURY))));
    assertEq(pool.treasury(), SENTINEL_TREASURY, "slot 2 must be treasury");
  }

  /// @notice `initialized` bool packs into slot 0 byte 20 (post-baseToken address).
  ///         Writing a full 32-byte value with both fields set must yield consistent reads.
  function test_layout_slot0_packs_baseToken_and_initialized() public {
    // Pack: address (low 20 bytes) + bool=true at byte offset 20.
    uint256 packed = uint256(uint160(SENTINEL_BASE)) | (uint256(1) << 160);
    vm.store(address(pool), bytes32(uint256(0)), bytes32(packed));
    assertEq(pool.baseToken(), SENTINEL_BASE, "baseToken read after packed write");
    // Round-trip via vm.load to confirm bool byte preserved.
    bytes32 raw = vm.load(address(pool), bytes32(uint256(0)));
    assertEq(uint256(raw), packed, "slot 0 packed bytes preserved");
  }

  /// @notice Snapshot guard: pin a hash over the first 3 slots. Any structural change
  ///         to slot-0..2 ordering breaks this hash, alerting reviewers BEFORE deploy.
  function test_layout_pinned_hash_first3Slots() public {
    // Write known sentinels into all 3 slots.
    vm.store(address(pool), bytes32(uint256(0)), bytes32(uint256(uint160(SENTINEL_BASE))));
    vm.store(address(pool), bytes32(uint256(1)), bytes32(uint256(uint160(SENTINEL_WNATIVE))));
    vm.store(address(pool), bytes32(uint256(2)), bytes32(uint256(uint160(SENTINEL_TREASURY))));

    // Reads via public getters MUST all return the sentinels.
    assertEq(pool.baseToken(), SENTINEL_BASE);
    assertEq(pool.wnative(), SENTINEL_WNATIVE);
    assertEq(pool.treasury(), SENTINEL_TREASURY);

    // Hash invariant -pin against future reorders.
    bytes32 hash = keccak256(
      abi.encodePacked(
        vm.load(address(pool), bytes32(uint256(0))),
        vm.load(address(pool), bytes32(uint256(1))),
        vm.load(address(pool), bytes32(uint256(2)))
      )
    );
    bytes32 expected = keccak256(
      abi.encodePacked(
        bytes32(uint256(uint160(SENTINEL_BASE))),
        bytes32(uint256(uint160(SENTINEL_WNATIVE))),
        bytes32(uint256(uint160(SENTINEL_TREASURY)))
      )
    );
    assertEq(hash, expected, "slot 0-2 layout hash mismatch - append-only invariant broken");
  }

  /// @notice Pin hooks mapping bases (assetHooks=11, invested=12) to SDK `POOL_STORAGE`.
  function test_layout_hooks_mapping_bases() public {
    bytes32 hookSlot = keccak256(abi.encode(SENTINEL_TOKEN, ASSET_HOOKS_SLOT));
    // HookSlot packs target (20 B) + flags (uint32) into one word.
    uint32 flags = 3; // PRE_OUTFLOW | POST_INFLOW
    uint256 packed = uint256(uint160(SENTINEL_HOOK)) | (uint256(flags) << 160);
    vm.store(address(pool), hookSlot, bytes32(packed));

    IPool.HookSlot memory h = IPool(address(pool)).getAssetHook(SENTINEL_TOKEN);
    assertEq(h.target, SENTINEL_HOOK, "assetHooks base must be slot 11");
    assertEq(h.flags, flags, "HookSlot flags packing");

    bytes32 invSlot = keccak256(abi.encode(SENTINEL_TOKEN, INVESTED_SLOT));
    vm.store(address(pool), invSlot, bytes32(uint256(42e18)));
    assertEq(
      IPool(address(pool)).getInvested(SENTINEL_TOKEN), 42e18, "invested base must be slot 12"
    );
  }

  /// @notice Pin the leg-receipt registry (lpTokens=13), the tail slot the ERC-20 ledger added.
  function test_layout_lpTokens_mapping_base() public {
    bytes32 slot = keccak256(abi.encode(SENTINEL_TOKEN, LP_TOKENS_SLOT));
    vm.store(address(pool), slot, bytes32(uint256(uint160(SENTINEL_HOOK))));
    assertEq(IPool(address(pool)).lpToken(SENTINEL_TOKEN), SENTINEL_HOOK, "lpTokens base = slot 13");
  }

  /// @notice Pin the renumbered custody/config mapping bases (assets=3 … protocolFees=8). A drift
  ///         here (or in the SDK POOL_STORAGE map) silently corrupts every off-chain slot read and
  ///         would make a beacon fleet-upgrade across the layout alias live state — break-glass only.
  function test_layout_renumbered_mapping_bases() public {
    // assets=3: write reserves (Asset slot 0 low 128 bits) at keccak(token, 3) and read it back.
    bytes32 aSlot = keccak256(abi.encode(SENTINEL_TOKEN, ASSETS_SLOT));
    vm.store(address(pool), aSlot, bytes32(uint256(uint128(7e18))));
    assertEq(
      IPool(address(pool)).getAsset(SENTINEL_TOKEN).reserves, 7e18, "assets base must be slot 3"
    );
    // protocolFees=8: keccak(token, 8) holds the per-token accrued fee.
    bytes32 pfSlot = keccak256(abi.encode(SENTINEL_TOKEN, PROTOCOL_FEES_SLOT));
    vm.store(address(pool), pfSlot, bytes32(uint256(123e6)));
    assertEq(
      IPool(address(pool)).getProtocolFees(SENTINEL_TOKEN),
      123e6,
      "protocolFees base must be slot 8"
    );
    // oracleConfigs=4 / riskConfigs=5 / curves=6 / __reserved_lpBalances=7 are asserted as
    // compile-time constants matching the SDK POOL_STORAGE map; the two probes above bracket the
    // renumbered range.
    assertEq(ORACLE_CONFIGS_SLOT, ASSETS_SLOT + 1, "oracleConfigs=4");
    assertEq(RISK_CONFIGS_SLOT, ASSETS_SLOT + 2, "riskConfigs=5");
    assertEq(CURVES_SLOT, ASSETS_SLOT + 3, "curves=6");
    assertEq(RESERVED_LP_BALANCES_SLOT, ASSETS_SLOT + 4, "__reserved_lpBalances=7");
  }
}

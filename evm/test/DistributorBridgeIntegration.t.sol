// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {Admin} from "../src/Admin.sol";
import {Flash} from "../src/Flash.sol";
import {Bridge} from "@btr-shared/Bridge.sol";
import {GovTreasury} from "@btr-shared/GovTreasury.sol";
import {OpsTreasury} from "@btr-shared/OpsTreasury.sol";
import {Distributor} from "@btr-shared/Distributor.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {IDistributor} from "@btr-shared/interfaces/IDistributor.sol";
import {IBridge} from "@btr-shared/interfaces/IBridge.sol";
import {IOpsTreasury} from "@btr-shared/interfaces/IOpsTreasury.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {BaseTestSetup, MockAC, MockOracle} from "./fixtures/BaseTestSetup.sol";
import {Err} from "@btr-shared/Errors.sol";

contract DistributorBridgeIntegrationTest is BaseTestSetup {
  using stdStorage for StdStorage;

  PoolFactory factory;
  Pool poolImpl;
  Admin admin;
  Flash flashSingleton;
  Distributor dist;
  MockAC ac;
  MockOracle oracle;
  Pool pool;
  MockERC20 base;
  MockERC20 quote;

  address constant OWNER = address(0xA11CE);
  address constant USER = address(0xBEEF);
  address constant USER2 = address(0xC0FE);
  uint8 constant PROTO_SHARE = 25;

  function _risk() internal pure returns (IPool.RiskConfig memory r) {
    r.coverageMin = 5000;
    r.coverageMax = 20000;
    r.depthAmplifier = 10000;
    r.flags = C.SWAP_ENABLED_BIT;
  }

  /// @dev M-1: EXTERNAL spokes must carry a cumulative bound; armed via the shared mirror-ref fixture.
  function _oracleCfg(address token) internal returns (IPool.OracleConfig memory o) {
    o = externalOracleCfg(oracle, token);
  }

  function setUp() public override {
    ac = new MockAC(OWNER);
    admin = new Admin(address(ac));
    flashSingleton = new Flash();
    dist = new Distributor(address(ac));
    PoolAux poolAux = new PoolAux(address(ac), address(admin), address(flashSingleton));
    poolImpl = new Pool(address(ac), address(admin), address(flashSingleton), address(poolAux));
    factory = new PoolFactory(address(poolImpl), address(this), address(ac));

    base = new MockERC20("Base", "BASE", 18);
    quote = new MockERC20("Quote", "QUOT", 18);
    address[] memory toks = new address[](2);
    toks[0] = address(base);
    toks[1] = address(quote);
    IPool.FeeParams memory fp = IPool.FeeParams({protoShare: PROTO_SHARE, flashFeePbps: 100});
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0xCAFE), fp);
    address pa = factory.createPool(address(base), toks, initdata);
    pool = Pool(payable(pa));

    oracle = new MockOracle();
    oracle.setMark(address(base), M.encodeB64(1e18, 18));
    oracle.setMark(address(quote), M.encodeB64(1e18, 18));
    IPool.RiskConfig memory rc = _risk();
    vm.startPrank(OWNER);
    admin.setCurve(pa, DEFAULT_PRESET, defaultCurveInterior(), defaultCurveWQ(), 1000, 0);
    admin.addAsset(
      pa,
      address(base),
      _oracleCfg(address(base)),
      rc,
      DEFAULT_PRESET,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );
    admin.addAsset(
      pa,
      address(quote),
      _oracleCfg(address(quote)),
      rc,
      DEFAULT_PRESET,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );
    vm.stopPrank();
  }

  /// @dev Propose a root as OWNER (campaign manager), wait out ROOT_COOLDOWN (24h), finalize it live.
  function _goLive(address p, uint256 id, bytes32 root, uint256 total) internal {
    vm.prank(OWNER);
    dist.proposeCampaignRoot(p, id, root, uint32(block.timestamp), total);
    vm.warp(block.timestamp + 1 days + 1);
    dist.finalizeCampaignRoot(p, id);
  }

  // ─── R14 Distributor ───

  /// @notice R14 MED: first campaign id is 1, never 0 (lazy-bump fix).
  function test_R14_first_campaignId_is_1() public {
    MockERC20 reward = new MockERC20("R", "R", 18);
    vm.prank(OWNER);
    uint256 id1 = dist.createTokenCampaign(address(pool), address(reward), OWNER);
    assertEq(id1, 1, "first id = 1");
    vm.prank(OWNER);
    uint256 id2 = dist.createTokenCampaign(address(pool), address(reward), OWNER);
    assertEq(id2, 2, "second id = 2");
  }

  /// @notice R14 LOW: Merkle leaf includes (pool, campaignId) for cross-pool/cross-campaign domain
  ///         separation. A leaf valid in (poolA, 1) MUST NOT verify in (poolB, 1) or (poolA, 2).
  function test_R14_merkle_leaf_pool_campaign_separation() public {
    MockERC20 reward = new MockERC20("R", "R", 18);
    // Mint reward escrow to dist (manager pre-funds).
    reward.mint(address(dist), 1_000e18);

    vm.prank(OWNER);
    uint256 id = dist.createTokenCampaign(address(pool), address(reward), OWNER);

    // Single-leaf root: leaf = keccak(abi.encodePacked(pool, id, idx, account, totalEarned))
    uint256 idx = 0;
    uint256 totalEarned = 100e18;
    bytes32 leaf = keccak256(abi.encodePacked(address(pool), id, idx, USER, totalEarned));
    bytes32[] memory proof = new bytes32[](0);

    _goLive(address(pool), id, leaf, totalEarned);

    // Valid claim (correct pool + id).
    vm.prank(USER);
    dist.claimCampaign(address(pool), id, idx, USER, totalEarned, proof);
    assertEq(reward.balanceOf(USER), totalEarned, "claim succeeds for correct domain");

    // Now create a campaign on a DIFFERENT pool with same root → claim must NOT verify.
    // Spin a second pool clone via factory.
    address[] memory toks2 = new address[](1);
    toks2[0] = address(base);
    IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 0, flashFeePbps: 0});
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0xCAFE), fp);
    address pool2 = factory.createPool(address(base), toks2, initdata);

    vm.prank(OWNER);
    uint256 id2 = dist.createTokenCampaign(pool2, address(reward), OWNER);
    // Same leaf bytes -but interpreted under (pool2, id2). MerkleProofLib.verify with
    // empty proof: leaf must equal root. Here leaf-under-pool2 != stored-root (pool-bound).
    _goLive(pool2, id2, leaf, totalEarned);

    // Claim against pool2 with same (idx, USER, totalEarned). Internal recomputed leaf
    // uses (pool2, id2) → ≠ stored root (which is the (pool,id)-leaf). Returns claimable=0
    // → revert InvalidState.
    vm.prank(USER);
    vm.expectRevert(Err.InvalidState.selector);
    dist.claimCampaign(pool2, id2, idx, USER, totalEarned, proof);
  }

  /// @notice R14: proposeCampaignRoot forbids lowering totalAllocated below already-claimed.
  function test_R14_totalAllocated_floor() public {
    MockERC20 reward = new MockERC20("R", "R", 18);
    reward.mint(address(dist), 1_000e18);
    vm.prank(OWNER);
    uint256 id = dist.createTokenCampaign(address(pool), address(reward), OWNER);

    bytes32 leaf = keccak256(abi.encodePacked(address(pool), id, uint256(0), USER, uint256(100e18)));
    _goLive(address(pool), id, leaf, 100e18);

    bytes32[] memory proof = new bytes32[](0);
    vm.prank(USER);
    dist.claimCampaign(address(pool), id, 0, USER, 100e18, proof);

    // Now try to lower totalClaimable below 100e18 (already-claimed).
    vm.prank(OWNER);
    vm.expectRevert(Err.InvalidInput.selector);
    dist.proposeCampaignRoot(address(pool), id, bytes32(uint256(1)), uint32(block.timestamp), 50e18);
  }

  // ─── R15 Treasury bridge selector ───

  /// @notice R15 HIGH: Treasury.getBridge() returns wired bridge, not auto-getter `bridge()` only.
  function test_R15_treasury_getBridge_explicit_selector() public {
    // Deploy a GovToken owned by a fresh Treasury.
    // Treasury constructor takes govToken. Use a placeholder address; we won't mint here.
    MockAC localAC = new MockAC(address(this));
    GovTreasury tr = new GovTreasury(address(localAC));
    MockERC20 placeholder = new MockERC20("G", "G", 18);
    tr.initialize(address(placeholder));

    // Pre-wire: getBridge() returns 0.
    assertEq(tr.getBridge(), address(0), "no bridge wired");

    // Wire a fake bridge via setBridge. GOV-02: setBridge now rejects a non-contract bridge, so use
    // a deployed contract address (the placeholder token) rather than a bare EOA sentinel.
    address fakeBridge = address(placeholder);
    tr.setBridge(fakeBridge);

    assertEq(tr.getBridge(), fakeBridge, "getBridge() returns wired bridge");
    // Sanity: auto-getter `bridge()` matches.
    assertEq(tr.bridge(), fakeBridge, "bridge() auto-getter matches");
  }

  /// @notice R15 LOW: executeEmissionsCapChange revalidates newCap >= claimed.
  function test_R15_executeEmissionsCap_revalidates_floor() public {
    // Treasury w/ minimal scaffolding.
    MockAC localAC = new MockAC(address(this));
    GovTreasury tr = new GovTreasury(address(localAC));
    MockERC20 placeholder = new MockERC20("G", "G", 18);
    tr.initialize(address(placeholder));
    tr.initializeEmissions(1_000e18);

    // Request a cap reduction.
    tr.requestEmissionsCapChange(500e18);

    // Simulate 800e18 minted during the timelock (claimed rises above the pending 500e18 cap).
    // stdstore targets emissionsSchedule.claimed (getter return index 1) — layout-independent, so
    // it survives storage reordering (e.g. the UpgradeGate base hoist).
    stdstore.target(address(tr)).sig("emissionsSchedule()").depth(1).checked_write(uint256(800e18));

    // Skip past the timelock but stay within grace window.
    vm.warp(block.timestamp + 8 days);

    vm.expectRevert(Err.InvalidState.selector);
    tr.executeEmissionsCapChange();
  }

  // ─── R16 Staking lpBalances drain (CRIT) ───
  // Removed: test_R16_stake_unstake_conservation
  // Rationale: Staking refactored to IStakable-keyed shared singleton; no longer keyed by
  //            (pool, lpToken). Pool LP balances now decoupled from staking custody (no
  //            stakingAdjustLpBalance callback). Equivalent invariant covered in
  //            alm/evm/test/VaultStaking.t.sol via Vault-share stake/unstake conservation.

  // ─── Salvage ───

  /// @notice OpsTreasury.salvage admin-only ERC20 sweep + Salvaged event.
  function test_salvage_treasury_owner_only() public {
    MockAC localAC = new MockAC(address(this));
    OpsTreasury tr = new OpsTreasury(address(localAC));

    // Drop stuck tokens into OpsTreasury.
    MockERC20 stuck = new MockERC20("S", "S", 18);
    stuck.mint(address(tr), 1_000e18);

    // Non-owner cannot sweep.
    vm.prank(USER);
    vm.expectRevert(Err.NotOwner.selector);
    tr.salvage(address(stuck), USER, 1_000e18);

    // Owner sweeps.
    tr.salvage(address(stuck), USER, 1_000e18);
    assertEq(stuck.balanceOf(USER), 1_000e18, "swept");
  }

  /// @notice Salvage emits Salvaged event with correct args.
  function test_salvage_treasury_emits_event() public {
    MockAC localAC = new MockAC(address(this));
    OpsTreasury tr = new OpsTreasury(address(localAC));
    MockERC20 stuck = new MockERC20("S", "S", 18);
    stuck.mint(address(tr), 500e18);
    vm.expectEmit(true, true, false, true);
    emit IOpsTreasury.Salvaged(address(stuck), USER, 500e18);
    tr.salvage(address(stuck), USER, 500e18);
  }

  /// @notice R15: requestEmissionsCapChange floor -newCap < claimed reverts at request.
  function test_R15_requestEmissionsCap_floor() public {
    MockAC localAC = new MockAC(address(this));
    GovTreasury tr = new GovTreasury(address(localAC));
    MockERC20 placeholder = new MockERC20("G", "G", 18);
    tr.initialize(address(placeholder));
    tr.initializeEmissions(1_000e18);
    // Force claimed = 600e18 (layout-independent; see stdstore note above).
    stdstore.target(address(tr)).sig("emissionsSchedule()").depth(1).checked_write(uint256(600e18));
    vm.expectRevert(Err.InvalidInput.selector);
    tr.requestEmissionsCapChange(500e18);
  }

  /// @notice R14: pause + resume cycle gates claims.
  function test_R14_pause_resume_gates_claim() public {
    MockERC20 reward = new MockERC20("R", "R", 18);
    reward.mint(address(dist), 1_000e18);
    vm.prank(OWNER);
    uint256 id = dist.createTokenCampaign(address(pool), address(reward), OWNER);
    bytes32 leaf = keccak256(abi.encodePacked(address(pool), id, uint256(0), USER, uint256(100e18)));
    _goLive(address(pool), id, leaf, 100e18);

    vm.prank(OWNER);
    dist.pauseCampaign(address(pool), id);

    bytes32[] memory proof = new bytes32[](0);
    vm.prank(USER);
    vm.expectRevert(Err.InvalidState.selector);
    dist.claimCampaign(address(pool), id, 0, USER, 100e18, proof);

    vm.prank(OWNER);
    dist.resumeCampaign(address(pool), id);
    vm.prank(USER);
    dist.claimCampaign(address(pool), id, 0, USER, 100e18, proof);
    assertEq(reward.balanceOf(USER), 100e18, "claim post-resume");
  }

  /// @notice R14: only manager can update root.
  function test_R14_only_manager_updates_root() public {
    MockERC20 reward = new MockERC20("R", "R", 18);
    vm.prank(OWNER);
    uint256 id = dist.createTokenCampaign(address(pool), address(reward), OWNER);
    vm.prank(USER);
    vm.expectRevert(Err.NotAuth.selector);
    dist.proposeCampaignRoot(address(pool), id, bytes32(uint256(1)), uint32(block.timestamp), 1);
  }

  /// @notice R14: pre-claim, claimable for unbounded leaf returns 0 (won't revert at view).
  function test_R14_zero_claimable_pre_root() public {
    MockERC20 reward = new MockERC20("R", "R", 18);
    vm.prank(OWNER);
    uint256 id = dist.createTokenCampaign(address(pool), address(reward), OWNER);
    bytes32[] memory proof = new bytes32[](0);
    uint256 claimable = dist.getCampaignClaimable(address(pool), id, 0, USER, 100e18, proof);
    assertEq(claimable, 0, "no root means 0 claimable");
  }

  /// @notice Bridge.salvage owner-only.
  function test_salvage_bridge_owner_only() public {
    // Bridge requires LZ_ENDPOINT immutable; pass a non-zero placeholder.
    MockAC localAC = new MockAC(address(this));
    Bridge br = new Bridge(address(0x1234), address(localAC));

    MockERC20 stuck = new MockERC20("S", "S", 18);
    stuck.mint(address(br), 1_000e18);

    vm.prank(USER);
    vm.expectRevert(Err.NotOwner.selector);
    br.salvage(address(stuck), USER, 1_000e18);

    br.salvage(address(stuck), USER, 1_000e18);
    assertEq(stuck.balanceOf(USER), 1_000e18, "swept");
  }
}

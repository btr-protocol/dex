// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {Admin} from "../src/Admin.sol";
import {Staking} from "../src/Staking.sol";
import {Flash} from "../src/Flash.sol";
import {Bridge} from "@btr-shared/Bridge.sol";
import {Treasury} from "@btr-shared/Treasury.sol";
import {Distributor} from "@btr-shared/Distributor.sol";
import {GovToken} from "@btr-shared/tokens/GovToken.sol";
import {StakedLP} from "../src/tokens/StakedLP.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {IDistributor} from "@btr-shared/interfaces/IDistributor.sol";
import {IStaking} from "../src/interfaces/IStaking.sol";
import {IBridge} from "@btr-shared/interfaces/IBridge.sol";
import {ITreasury} from "@btr-shared/interfaces/ITreasury.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {Maths as M} from "../src/libraries/Maths.sol";
import {MockAC} from "./fixtures/BaseTestSetup.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract Phase42HB3eR14R15R16Test is Test {
    PoolFactory factory;
    Pool poolImpl;
    Admin admin;
    Staking stakingSingleton;
    Flash flashSingleton;
    Distributor dist;
    MockAC ac;
    Pool pool;
    MockERC20 base;
    MockERC20 quote;

    address constant OWNER = address(0xA11CE);
    address constant USER  = address(0xBEEF);
    address constant USER2 = address(0xC0FE);
    uint8  constant PROTO_SHARE = 25;

    function _profile() internal pure returns (IPool.LiquidityProfile memory p) {
        p.weights[0] = 50; p.weights[1] = 50; p.weights[2] = 50; p.weights[3] = 50;
        p.knots[0] = -50; p.knots[1] = -25; p.knots[2] = 0; p.knots[3] = 25; p.knots[4] = 50;
    }
    function _risk() internal pure returns (IPool.RiskConfig memory r) {
        r.coverageMin = 5000; r.coverageMax = 20000; r.depthAmplifier = 10000;
        r.flags = C.SWAP_ENABLED_BIT | C.STAKEABLE_BIT;
    }
    function _oracleCfg() internal view returns (IPool.OracleConfig memory o) {
        o.primary = address(pool); o.modeFlags = C.MODE_USE_INTERNAL; o.accDecimals = 18;
    }

    function setUp() public {
        ac = new MockAC(OWNER);
        admin = new Admin(address(ac));
        stakingSingleton = new Staking(address(ac));
        flashSingleton = new Flash();
        dist = new Distributor(address(ac));
        PoolAux poolAux = new PoolAux(address(ac), address(admin), address(stakingSingleton), address(flashSingleton));
        poolImpl = new Pool(address(ac), address(admin), address(stakingSingleton), address(flashSingleton), address(poolAux));
        factory = new PoolFactory(address(poolImpl), address(this), address(ac));

        base = new MockERC20("Base", "BASE", 18);
        quote = new MockERC20("Quote", "QUOT", 18);
        address[] memory toks = new address[](2);
        toks[0] = address(base); toks[1] = address(quote);

        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: PROTO_SHARE, flashFeeBps: 100, _pad: pad});
        bytes memory initdata = abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0xCAFE), fp);
        address pa = factory.createPool(address(base), toks, initdata);
        pool = Pool(payable(pa));

        IPool.OracleConfig memory oc = _oracleCfg();
        IPool.RiskConfig memory rc = _risk();
        IPool.LiquidityProfile memory pf = _profile();
        uint64 px = M.encodeB64(1e18, 18);
        vm.startPrank(OWNER);
        admin.addAsset(pa, address(base),  oc, rc, pf, 1000, 18, px, 10_000, 10_000, 1000, 100000, 10000, 10000, 10000);
        admin.addAsset(pa, address(quote), oc, rc, pf, 1000, 18, px, 10_000, 10_000, 1000, 100000, 10000, 10000, 10000);
        vm.stopPrank();
    }

    // ─── R14 Distributor ───

    /// @notice R14 MED: first campaign id is 1, never 0 (lazy-bump fix).
    function test_R14_first_campaignId_is_1() public {
        MockERC20 reward = new MockERC20("R","R",18);
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
        MockERC20 reward = new MockERC20("R","R",18);
        // Mint reward escrow to dist (manager pre-funds).
        reward.mint(address(dist), 1_000e18);

        vm.prank(OWNER);
        uint256 id = dist.createTokenCampaign(address(pool), address(reward), OWNER);

        // Single-leaf root: leaf = keccak(abi.encodePacked(pool, id, idx, account, totalEarned))
        uint256 idx = 0;
        uint256 totalEarned = 100e18;
        bytes32 leaf = keccak256(abi.encodePacked(address(pool), id, idx, USER, totalEarned));
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(OWNER);
        dist.updateCampaignRoot(address(pool), id, leaf, uint32(block.timestamp), totalEarned);

        // Valid claim (correct pool + id).
        vm.prank(USER);
        dist.claimCampaign(address(pool), id, idx, USER, totalEarned, proof);
        assertEq(reward.balanceOf(USER), totalEarned, "claim succeeds for correct domain");

        // Now create a campaign on a DIFFERENT pool with same root → claim must NOT verify.
        // Spin a second pool clone via factory.
        address[] memory toks2 = new address[](1); toks2[0] = address(base);
        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 0, flashFeeBps: 0, _pad: pad});
        bytes memory initdata = abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0xCAFE), fp);
        address pool2 = factory.createPool(address(base), toks2, initdata);

        vm.prank(OWNER);
        uint256 id2 = dist.createTokenCampaign(pool2, address(reward), OWNER);
        // Same leaf bytes -but interpreted under (pool2, id2). MerkleProofLib.verify with
        // empty proof: leaf must equal root. Here leaf-under-pool2 != stored-root (pool-bound).
        vm.prank(OWNER);
        dist.updateCampaignRoot(pool2, id2, leaf, uint32(block.timestamp), totalEarned);

        // Claim against pool2 with same (idx, USER, totalEarned). Internal recomputed leaf
        // uses (pool2, id2) → ≠ stored root (which is the (pool,id)-leaf). Returns claimable=0
        // → revert InvalidState.
        vm.prank(USER);
        vm.expectRevert(Err.InvalidState.selector);
        dist.claimCampaign(pool2, id2, idx, USER, totalEarned, proof);
    }

    /// @notice R14: updateCampaignRoot forbids lowering totalAllocated below already-claimed.
    function test_R14_totalAllocated_floor() public {
        MockERC20 reward = new MockERC20("R","R",18);
        reward.mint(address(dist), 1_000e18);
        vm.prank(OWNER);
        uint256 id = dist.createTokenCampaign(address(pool), address(reward), OWNER);

        bytes32 leaf = keccak256(abi.encodePacked(address(pool), id, uint256(0), USER, uint256(100e18)));
        vm.prank(OWNER);
        dist.updateCampaignRoot(address(pool), id, leaf, uint32(block.timestamp), 100e18);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(USER);
        dist.claimCampaign(address(pool), id, 0, USER, 100e18, proof);

        // Now try to lower totalClaimable below 100e18 (already-claimed).
        vm.prank(OWNER);
        vm.expectRevert(Err.InvalidInput.selector);
        dist.updateCampaignRoot(address(pool), id, bytes32(uint256(1)), uint32(block.timestamp), 50e18);
    }

    // ─── R15 Treasury bridge selector ───

    /// @notice R15 HIGH: Treasury.getBridge() returns wired bridge, not auto-getter `bridge()` only.
    function test_R15_treasury_getBridge_explicit_selector() public {
        // Deploy a GovToken owned by a fresh Treasury.
        // Treasury constructor takes govToken. Use a placeholder address; we won't mint here.
        MockAC localAC = new MockAC(address(this));
        Treasury tr = new Treasury(address(localAC));
        MockERC20 placeholder = new MockERC20("G","G",18);
        tr.initialize(address(placeholder));

        // Pre-wire: getBridge() returns 0.
        assertEq(tr.getBridge(), address(0), "no bridge wired");

        // Wire a fake bridge address via setBridge.
        address fakeBridge = address(0xB123);
        tr.setBridge(fakeBridge);

        assertEq(tr.getBridge(), fakeBridge, "getBridge() returns wired bridge");
        // Sanity: auto-getter `bridge()` matches.
        assertEq(tr.bridge(), fakeBridge, "bridge() auto-getter matches");
    }

    /// @notice R15 LOW: executeEmissionsCapChange revalidates newCap >= claimed.
    function test_R15_executeEmissionsCap_revalidates_floor() public {
        // Treasury w/ minimal scaffolding.
        MockAC localAC = new MockAC(address(this));
        Treasury tr = new Treasury(address(localAC));
        MockERC20 placeholder = new MockERC20("G","G",18);
        tr.initialize(address(placeholder));
        tr.initializeEmissions(1_000e18);

        // Request a cap reduction.
        tr.requestEmissionsCapChange(500e18);

        // Manipulate emissionsSchedule.claimed via vm.store to simulate mints during timelock.
        // Treasury layout: emissionsSchedule struct @ slot 4. Fields: totalAllocation (slot 4),
        // claimed (slot 5), then cliffTime/endTime/cliffAmount/suppressor packed into slot 6.
        vm.store(address(tr), bytes32(uint256(5)), bytes32(uint256(800e18))); // emissionsSchedule.claimed (new layout: AC immutable, govToken+_initialized @ slot 0, then tgeTimestamp, maxSupply, totalVestingAllocation, vestingSchedules, emissionsSchedule @ slot 5)

        // Skip past the timelock but stay within grace window.
        vm.warp(block.timestamp + 8 days);

        vm.expectRevert(Err.InvalidState.selector);
        tr.executeEmissionsCapChange();
    }

    // ─── R16 Staking lpBalances drain (CRIT) ───

    /// @notice R16 CRIT: stake → unstake conserves user's lpBalance + sLP balance under invariant.
    ///         A user cannot drain by staking and then directly withdraw the original lpBalances slot.
    function test_R16_stake_unstake_conservation() public {
        // Deposit some quote LP first.
        uint256 amt = 1_000e18;
        quote.mint(USER, amt);
        vm.prank(USER); quote.approve(address(pool), type(uint256).max);
        vm.prank(USER); pool.deposit(address(quote), amt);
        uint256 lp0 = pool.getLPBalance(USER, address(quote));
        assertGt(lp0, 0, "lp credited");

        // Configure staking on this pool. Need real gov + sGov tokens (minimal).
        GovToken gov = new GovToken(address(stakingSingleton), "G","G");
        // sGov: a StakedLP-like wrapper bound to gov.
        StakedLP sGov = new StakedLP(address(stakingSingleton), address(gov), address(pool));
        vm.prank(OWNER);
        stakingSingleton.configurePool(address(pool), address(gov), address(sGov), 0);

        // Register sLP for the quote LP token.
        vm.prank(OWNER);
        stakingSingleton.updateStakingConfig(address(pool), address(quote), bytes32(uint256(1)));

        // Stake all.
        vm.prank(USER);
        stakingSingleton.stakeLP(address(pool), address(quote), lp0);

        // Pool's lpBalance debited; staking accounting credits sLP balance.
        uint256 lp1 = pool.getLPBalance(USER, address(quote));
        uint256 staked1 = stakingSingleton.getStakedLP(address(pool), USER, address(quote));
        assertEq(lp1, 0, "lpBalance fully debited");
        assertEq(staked1, lp0, "staked = lp0");
        // Conservation: lpBalance + staked == lp0.
        assertEq(lp1 + staked1, lp0, "stake conservation");

        // Now user attempts withdraw on Pool -must fail (lpBalance=0).
        vm.prank(USER);
        vm.expectRevert();
        pool.withdraw(address(quote), 1, 0);

        // Unstake half.
        vm.prank(USER);
        stakingSingleton.unstakeLP(address(pool), address(quote), lp0 / 2);

        uint256 lp2 = pool.getLPBalance(USER, address(quote));
        uint256 staked2 = stakingSingleton.getStakedLP(address(pool), USER, address(quote));
        assertEq(lp2, lp0 / 2, "half restored to lpBalance");
        assertEq(staked2, lp0 - lp0 / 2, "half remains staked");
        assertEq(lp2 + staked2, lp0, "unstake conservation");
    }

    // ─── Salvage ───

    /// @notice Treasury.salvage owner-only ERC20 sweep + Salvaged event.
    function test_salvage_treasury_owner_only() public {
        MockAC localAC = new MockAC(address(this));
        Treasury tr = new Treasury(address(localAC));
        MockERC20 placeholder = new MockERC20("G","G",18);
        tr.initialize(address(placeholder));

        // Drop stuck tokens into Treasury.
        MockERC20 stuck = new MockERC20("S","S",18);
        stuck.mint(address(tr), 1_000e18);

        // Non-owner cannot sweep.
        vm.prank(USER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        tr.salvage(address(stuck), USER, 1_000e18);

        // Owner sweeps.
        tr.salvage(address(stuck), USER, 1_000e18);
        assertEq(stuck.balanceOf(USER), 1_000e18, "swept");
    }

    /// @notice Salvage emits Salvaged event with correct args.
    function test_salvage_treasury_emits_event() public {
        MockAC localAC = new MockAC(address(this));
        Treasury tr = new Treasury(address(localAC));
        MockERC20 placeholder = new MockERC20("G","G",18);
        tr.initialize(address(placeholder));
        MockERC20 stuck = new MockERC20("S","S",18);
        stuck.mint(address(tr), 500e18);
        vm.expectEmit(true, true, false, true);
        emit ITreasury.Salvaged(address(stuck), USER, 500e18);
        tr.salvage(address(stuck), USER, 500e18);
    }

    /// @notice R15: requestEmissionsCapChange floor -newCap < claimed reverts at request.
    function test_R15_requestEmissionsCap_floor() public {
        MockAC localAC = new MockAC(address(this));
        Treasury tr = new Treasury(address(localAC));
        MockERC20 placeholder = new MockERC20("G","G",18);
        tr.initialize(address(placeholder));
        tr.initializeEmissions(1_000e18);
        // Force claimed = 600e18 via storage.
        vm.store(address(tr), bytes32(uint256(5)), bytes32(uint256(600e18))); // emissionsSchedule.claimed (slot 6 post Track-B Phase-1b)
        vm.expectRevert(Err.InvalidInput.selector);
        tr.requestEmissionsCapChange(500e18);
    }

    /// @notice R14: pause + resume cycle gates claims.
    function test_R14_pause_resume_gates_claim() public {
        MockERC20 reward = new MockERC20("R","R",18);
        reward.mint(address(dist), 1_000e18);
        vm.prank(OWNER);
        uint256 id = dist.createTokenCampaign(address(pool), address(reward), OWNER);
        bytes32 leaf = keccak256(abi.encodePacked(address(pool), id, uint256(0), USER, uint256(100e18)));
        vm.prank(OWNER);
        dist.updateCampaignRoot(address(pool), id, leaf, uint32(block.timestamp), 100e18);

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
        MockERC20 reward = new MockERC20("R","R",18);
        vm.prank(OWNER);
        uint256 id = dist.createTokenCampaign(address(pool), address(reward), OWNER);
        vm.prank(USER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        dist.updateCampaignRoot(address(pool), id, bytes32(uint256(1)), uint32(block.timestamp), 1);
    }

    /// @notice R14: pre-claim, claimable for unbounded leaf returns 0 (won't revert at view).
    function test_R14_zero_claimable_pre_root() public {
        MockERC20 reward = new MockERC20("R","R",18);
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
        br.initialize();

        MockERC20 stuck = new MockERC20("S","S",18);
        stuck.mint(address(br), 1_000e18);

        vm.prank(USER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        br.salvage(address(stuck), USER, 1_000e18);

        br.salvage(address(stuck), USER, 1_000e18);
        assertEq(stuck.balanceOf(USER), 1_000e18, "swept");
    }
}

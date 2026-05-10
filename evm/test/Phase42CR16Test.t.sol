// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../src/modules/Pool.sol";
import {Admin} from "../src/Admin.sol";
import {Staking} from "../src/Staking.sol";
import {InternalOracle} from "../src/modules/InternalOracle.sol";
import {PoolProxy} from "../src/PoolProxy.sol";
import {PoolProxyFactory} from "../src/PoolProxyFactory.sol";
import {StakedGov} from "../src/tokens/StakedGov.sol";
import {StakedLP} from "../src/tokens/StakedLP.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {IAdmin} from "../src/interfaces/IAdmin.sol";
import {IStaking} from "../src/interfaces/IStaking.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {Maths as M} from "../src/libraries/Maths.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {BTRToken} from "./fixtures/BTRToken.sol";
import {MockAC} from "./fixtures/BaseTestSetup.sol";

/// @title Phase42CR16Test (post-42H.B.3b — Staking promoted to singleton)
/// @notice Phase 42C R16 remediation re-asserted on the singleton-Staking topology:
///   - F-A1-R16-2 (CRITICAL): sGovToken wiring → Staking.configurePool.
///   - F-A1-R16-3 (CRITICAL): StakedGov/StakedLP public mint/burn auth (gated by singleton STAKING).
///   - F-A1-R16-1 (HIGH): stakeLP debits Pool.lpBalances via stakingAdjustLpBalance.
///   - F-A2-R16-2 (LOW): requestStakeLockDurationUpdate gains pending guard + 365d bound.
contract Phase42CR16Test is Test {
    PoolProxyFactory factory;
    Pool poolImpl;
    Admin admin;
    Staking stakingSingleton;
    InternalOracle oracleImpl;
    PoolProxy refProxy;
    PoolProxy proxy;

    MockERC20 base;
    MockERC20 quote;
    BTRToken gov;
    StakedGov sGov;
    MockAC ac;

    address constant OWNER = address(0xA11CE);
    address constant USER  = address(0xBEEF);
    uint8  constant PROTO_SHARE = 25;
    uint16 constant FLASH_FEE_BPS = 100;

    // Pool selector wiring — only Pool selectors (Staking is no longer a Diamond module).
    function _poolSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](11);
        s[0] = Pool.deposit.selector;
        s[1] = Pool.withdraw.selector;
        s[2] = Pool.getAsset.selector;
        s[3] = Pool.getLPBalance.selector;
        s[4] = Pool.getRiskFlags.selector;
        s[5] = Pool.baseToken.selector;
        s[6] = Pool.owner.selector;
        s[7] = Pool.adminInitAsset.selector;
        s[8] = Pool.adminSetGovToken.selector;
        s[9] = Pool.adminSetStakedGovToken.selector;
        s[10] = Pool.stakingAdjustLpBalance.selector;
    }

    function _oracleSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = InternalOracle.updateFeed.selector;
        s[1] = InternalOracle.pushFeedInternal.selector;
    }

    function _registerModule(address proxyAddr, address impl, bytes4[] memory sels) internal {
        uint256 modulesSlot = uint256(C.CORE_STORAGE_LOC) + 13;
        for (uint256 i = 0; i < sels.length; ++i) {
            bytes32 slot = keccak256(abi.encode(sels[i], modulesSlot));
            vm.store(proxyAddr, slot, bytes32(uint256(uint160(impl))));
        }
    }

    function _defaultProfile() internal pure returns (IPool.LiquidityProfile memory p) {
        p.weights[0] = 50; p.weights[1] = 50; p.weights[2] = 50; p.weights[3] = 50;
        p.knots[0] = -50; p.knots[1] = -25; p.knots[2] = 0; p.knots[3] = 25; p.knots[4] = 50;
    }

    function _defaultRisk() internal pure returns (IPool.RiskConfig memory r) {
        r.decayStartRatioBps = 5000;
        r.coverageMin = 5000;
        r.coverageMax = 20000;
        r.decaySlope = 0;
        r.depthAmplifier = 10000;
        r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT | C.STAKEABLE_BIT;
    }

    function _oracleCfg() internal view returns (IPool.OracleConfig memory o) {
        o.primary = address(proxy);
        o.secondary = address(0);
        o.feedId = bytes32(0);
        o.modeFlags = C.MODE_USE_INTERNAL;
        o.accDecimals = 18;
    }

    function setUp() public {
        ac = new MockAC(OWNER);

        admin            = new Admin(address(ac));
        stakingSingleton = new Staking(address(ac));
        poolImpl         = new Pool(address(ac), address(admin), address(stakingSingleton), address(0xF1A571));
        oracleImpl       = new InternalOracle(address(ac));

        refProxy = new PoolProxy();
        factory  = new PoolProxyFactory(address(refProxy), address(this), address(ac));

        base  = new MockERC20("Base",  "BASE", 18);
        quote = new MockERC20("Quote", "QUOT", 18);
        gov   = new BTRToken("BTR", "BTR", 18);

        address[] memory toks = new address[](2);
        toks[0] = address(base);
        toks[1] = address(quote);

        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({
            protoShare: PROTO_SHARE,
            flashFeeBps: FLASH_FEE_BPS,
            _pad: pad
        });
        bytes memory initdata = abi.encodeWithSelector(
            PoolProxy.initialize.selector,
            OWNER, address(base), address(0xCAFE), fp
        );
        address proxyAddr = factory.createPool(address(base), toks, initdata);
        proxy = PoolProxy(payable(proxyAddr));

        _registerModule(proxyAddr, address(poolImpl),    _poolSelectors());
        _registerModule(proxyAddr, address(oracleImpl),  _oracleSelectors());

        IPool.OracleConfig memory oc = _oracleCfg();
        IPool.RiskConfig    memory rc = _defaultRisk();
        IPool.LiquidityProfile memory pf = _defaultProfile();
        uint64 priceB64 = M.encodeB64(1e18, 18);

        vm.startPrank(OWNER);
        admin.addAsset(proxyAddr, address(base),  oc, rc, pf, 1000, 18, priceB64, 10_000, 10_000, 1000, 100000, 10000, 10000, 10000);
        admin.addAsset(proxyAddr, address(quote), oc, rc, pf, 1000, 18, priceB64, 10_000, 10_000, 1000, 100000, 10000, 10000, 10000);
        vm.stopPrank();

        // sGov bound to (singleton, gov, pool).
        sGov = new StakedGov(address(stakingSingleton), address(gov), proxyAddr, "sBTR", "sBTR");
        // Configure pool on the singleton (one-shot).
        vm.prank(OWNER);
        stakingSingleton.configurePool(proxyAddr, address(gov), address(sGov), 15);
    }

    // ════════════════════════════════════════════════════════════════════
    // F-A1-R16-2 — pool config one-shot
    // ════════════════════════════════════════════════════════════════════

    function test_R16_configurePool_idempotent() public {
        StakedGov s2 = new StakedGov(address(stakingSingleton), address(gov), address(proxy), "sBTR2", "sBTR2");
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Err.AlreadyConfigured.selector, Err.Resource.STAKING, address(gov)));
        stakingSingleton.configurePool(address(proxy), address(gov), address(s2), 15);
    }

    function test_R16_configurePool_zeroAddress_reverts() public {
        // Fresh proxy w/o pool config set.
        address[] memory toks = new address[](1);
        toks[0] = address(base);
        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 0, flashFeeBps: 0, _pad: pad});
        bytes memory initdata = abi.encodeWithSelector(
            PoolProxy.initialize.selector, OWNER, address(base), address(0xCAFE), fp
        );
        address p2 = factory.createPool(address(base), toks, initdata);
        _registerModule(p2, address(poolImpl), _poolSelectors());
        vm.prank(OWNER);
        vm.expectRevert(Err.ZeroValue.selector);
        stakingSingleton.configurePool(p2, address(gov), address(0), 15);
    }

    function test_R16_configurePool_onlyOwner() public {
        StakedGov s2 = new StakedGov(address(stakingSingleton), address(gov), address(proxy), "sBTR2", "sBTR2");
        vm.prank(USER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        stakingSingleton.configurePool(address(proxy), address(gov), address(s2), 15);
    }

    // ════════════════════════════════════════════════════════════════════
    // F-A1-R16-3 — StakedToken public mint/burn auth (gated by singleton STAKING)
    // ════════════════════════════════════════════════════════════════════

    function test_R16_StakedToken_mint_unauthorized_reverts() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        sGov.mint(USER, 1e18);
    }

    function test_R16_StakedToken_burn_unauthorized_reverts() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        sGov.burn(USER, 1e18);
    }

    // ════════════════════════════════════════════════════════════════════
    // stakeGov full round-trip
    // ════════════════════════════════════════════════════════════════════

    function test_R16_stakeGov_roundTrip() public {
        uint256 amount = 100e18;
        gov.mint(USER, amount);

        vm.prank(USER);
        gov.approve(address(stakingSingleton), type(uint256).max);

        vm.prank(USER);
        stakingSingleton.stakeGov(address(proxy), amount);
        assertEq(gov.balanceOf(USER), 0, "gov pulled");
        assertEq(gov.balanceOf(address(stakingSingleton)), amount, "singleton holds gov");
        assertEq(stakingSingleton.getStakedGov(address(proxy), USER), amount, "staked tracked");

        skip(30);

        vm.prank(USER);
        stakingSingleton.unstakeGov(address(proxy), amount);
        assertEq(gov.balanceOf(USER), amount, "gov returned");
        assertEq(stakingSingleton.getStakedGov(address(proxy), USER), 0, "staked cleared");
    }

    // ════════════════════════════════════════════════════════════════════
    // F-A1-R16-1 — stakeLP debits lpBalances via singleton + Pool restricted setter
    // ════════════════════════════════════════════════════════════════════

    function test_R16_stakeLP_decrements_lpBalances_and_mints_sLP() public {
        vm.prank(OWNER);
        stakingSingleton.updateStakingConfig(address(proxy), address(base), keccak256("salt-base"));
        address sLP = stakingSingleton.getSLPToken(address(proxy), address(base));
        assertTrue(sLP != address(0), "sLP deployed");

        uint256 depAmt = 1_000e18;
        base.mint(USER, depAmt);
        vm.prank(USER);
        base.approve(address(proxy), type(uint256).max);
        vm.prank(USER);
        Pool(payable(address(proxy))).deposit(address(base), depAmt);

        uint256 lpBefore = Pool(payable(address(proxy))).getLPBalance(USER, address(base));
        assertGt(lpBefore, 0, "lp credited");

        skip(30);

        vm.prank(USER);
        stakingSingleton.stakeLP(address(proxy), address(base), lpBefore);

        uint256 lpAfter = Pool(payable(address(proxy))).getLPBalance(USER, address(base));
        assertEq(lpAfter, 0, "lpBalances fully debited");
        assertEq(stakingSingleton.getStakedBalance(address(proxy), USER, address(base)), lpBefore, "lpStaked credited");
        assertEq(StakedLP(sLP).balanceOf(USER), lpBefore, "sLP minted to user");
    }

    function test_R16_stakeLP_then_withdraw_reverts() public {
        vm.prank(OWNER);
        stakingSingleton.updateStakingConfig(address(proxy), address(base), keccak256("salt-base-2"));

        uint256 depAmt = 1_000e18;
        base.mint(USER, depAmt);
        vm.prank(USER);
        base.approve(address(proxy), type(uint256).max);
        vm.prank(USER);
        Pool(payable(address(proxy))).deposit(address(base), depAmt);
        uint256 lp = Pool(payable(address(proxy))).getLPBalance(USER, address(base));

        skip(30);
        vm.prank(USER);
        stakingSingleton.stakeLP(address(proxy), address(base), lp);

        skip(30);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(Err.InsufficientAmount.selector, 0, lp));
        Pool(payable(address(proxy))).withdraw(address(base), lp, 0);
    }

    function test_R16_stakeLP_unstakeLP_roundTrip_conservation() public {
        vm.prank(OWNER);
        stakingSingleton.updateStakingConfig(address(proxy), address(base), keccak256("salt-base-3"));
        address sLP = stakingSingleton.getSLPToken(address(proxy), address(base));

        uint256 depAmt = 500e18;
        base.mint(USER, depAmt);
        vm.prank(USER);
        base.approve(address(proxy), type(uint256).max);
        vm.prank(USER);
        Pool(payable(address(proxy))).deposit(address(base), depAmt);
        uint256 lp = Pool(payable(address(proxy))).getLPBalance(USER, address(base));

        assertEq(lp + StakedLP(sLP).balanceOf(USER), lp, "pre-stake conservation");

        skip(30);
        vm.prank(USER);
        stakingSingleton.stakeLP(address(proxy), address(base), lp);

        assertEq(
            Pool(payable(address(proxy))).getLPBalance(USER, address(base)) + StakedLP(sLP).balanceOf(USER),
            lp,
            "post-stake conservation"
        );

        skip(30);
        vm.prank(USER);
        stakingSingleton.unstakeLP(address(proxy), address(base), lp);

        assertEq(
            Pool(payable(address(proxy))).getLPBalance(USER, address(base)) + StakedLP(sLP).balanceOf(USER),
            lp,
            "post-unstake conservation"
        );
        assertEq(Pool(payable(address(proxy))).getLPBalance(USER, address(base)), lp, "lpBalances restored");
        assertEq(StakedLP(sLP).balanceOf(USER), 0, "sLP burned");

        skip(60);
        vm.prank(USER);
        Pool(payable(address(proxy))).withdraw(address(base), lp, 0);
        assertEq(base.balanceOf(USER), depAmt, "underlying recovered");
    }

    // ════════════════════════════════════════════════════════════════════
    // F-A2-R16-2 — requestStakeLockDurationUpdate guards
    // ════════════════════════════════════════════════════════════════════

    function test_R16_requestStakeLockDurationUpdate_boundsAt365days() public {
        vm.prank(OWNER);
        vm.expectRevert(Err.InvalidInput.selector);
        stakingSingleton.requestStakeLockDurationUpdate(address(proxy), uint48(366 days));
    }

    function test_R16_requestStakeLockDurationUpdate_acceptsAt365days() public {
        vm.prank(OWNER);
        stakingSingleton.requestStakeLockDurationUpdate(address(proxy), uint48(365 days));
    }

    function test_R16_requestStakeLockDurationUpdate_rejectsDoubleQueue() public {
        vm.prank(OWNER);
        stakingSingleton.requestStakeLockDurationUpdate(address(proxy), uint48(7 days));

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Err.PendingTimelock.selector, uint48(block.timestamp)));
        stakingSingleton.requestStakeLockDurationUpdate(address(proxy), uint48(14 days));
    }
}

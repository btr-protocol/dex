// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../src/modules/Pool.sol";
import {Admin} from "../src/modules/Admin.sol";
import {Staking} from "../src/modules/Staking.sol";
import {InternalOracle} from "../src/modules/InternalOracle.sol";
import {PoolProxy} from "../src/PoolProxy.sol";
import {PoolProxyFactory} from "../src/PoolProxyFactory.sol";
import {StakedGov} from "../src/tokens/StakedGov.sol";
import {StakedLP} from "../src/tokens/StakedLP.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {IAdminConfig, IAdminTimelock} from "../src/interfaces/modules/IAdmin.sol";
import {IStaking} from "../src/interfaces/modules/IStaking.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {Maths as M} from "../src/libraries/Maths.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {BTRToken} from "./fixtures/BTRToken.sol";

/// @title Phase42CR16Test
/// @notice Phase 42C R16 remediation:
///   - F-A1-R16-2 (CRITICAL): sGovToken never wired → Admin.setStakedGovToken + setGovToken.
///   - F-A1-R16-3 (CRITICAL): StakedGov/StakedLP missing public mint/burn → added on StakedToken.
///   - F-A1-R16-1 (HIGH): stakeLP did not debit lpBalances → withdraw drained pool while sLP held.
///   - F-A2-R16-1 (LOW): delegateOf documented DISCARD.
///   - F-A2-R16-2 (LOW): requestStakeLockDurationUpdate gains pending guard + 365 day bound.
///   - F-A4-R16-1 (INFO): unchecked uint48 add — DISCARDED with rationale (lock bound makes safe).
///
/// Conservation invariant (LP):
///   ∀ user u, asset t: lpBalances[u][t] + sLP(t).balanceOf(u) ==
///   (Σ deposit(u,t,x) - Σ withdraw(u,t,x)) preserved across stake/unstake.
contract Phase42CR16Test is Test {
    PoolProxyFactory factory;
    Pool poolImpl;
    Admin adminImpl;
    Staking stakingImpl;
    InternalOracle oracleImpl;
    PoolProxy refProxy;
    PoolProxy proxy;

    MockERC20 base;
    MockERC20 quote;
    BTRToken gov;
    StakedGov sGov;

    address constant OWNER = address(0xA11CE);
    address constant USER  = address(0xBEEF);
    uint8  constant PROTO_SHARE = 25;
    uint16 constant FLASH_FEE_BPS = 100;

    // ── selector lists ──
    function _poolSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = Pool.deposit.selector;
        s[1] = Pool.withdraw.selector;
        s[2] = Pool.getAsset.selector;
        s[3] = Pool.getLPBalance.selector;
        s[4] = Pool.baseToken.selector;
        s[5] = Pool.owner.selector;
    }

    function _adminSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = Admin.addAsset.selector;
        s[1] = Admin.setStakedGovToken.selector;
        s[2] = Admin.setGovToken.selector;
        s[3] = IAdminConfig.getModule.selector;
    }

    function _stakingSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](11);
        s[0] = Staking.stakeGov.selector;
        s[1] = Staking.unstakeGov.selector;
        s[2] = Staking.updateStakingConfig.selector;
        s[3] = Staking.stakeLP.selector;
        s[4] = Staking.unstakeLP.selector;
        s[5] = Staking.getStakedGov.selector;
        s[6] = Staking.getSLPToken.selector;
        s[7] = Staking.getStakedBalance.selector;
        s[8] = Staking.getTotalStaked.selector;
        s[9] = Staking.requestStakeLockDurationUpdate.selector;
        s[10] = Staking.executeStakeLockDurationUpdate.selector;
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
        // STAKEABLE_BIT required for stakeLP path; SWAP/LIAB enabled for completeness.
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
        poolImpl    = new Pool();
        adminImpl   = new Admin();
        stakingImpl = new Staking();
        oracleImpl  = new InternalOracle();

        refProxy = new PoolProxy();
        factory  = new PoolProxyFactory(address(refProxy), address(this));

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
        _registerModule(proxyAddr, address(adminImpl),   _adminSelectors());
        _registerModule(proxyAddr, address(stakingImpl), _stakingSelectors());
        _registerModule(proxyAddr, address(oracleImpl),  _oracleSelectors());

        // Add base + quote as assets w/ STAKEABLE_BIT set.
        IPool.OracleConfig memory oc = _oracleCfg();
        IPool.RiskConfig    memory rc = _defaultRisk();
        IPool.LiquidityProfile memory pf = _defaultProfile();
        uint64 priceB64 = M.encodeB64(1e18, 18);

        vm.startPrank(OWNER);
        Admin(proxyAddr).addAsset(address(base),  oc, rc, pf, 1000, 18, priceB64, 10_000, 10_000, 1000, 100000, 10000, 10000, 10000);
        Admin(proxyAddr).addAsset(address(quote), oc, rc, pf, 1000, 18, priceB64, 10_000, 10_000, 1000, 100000, 10000, 10000, 10000);
        vm.stopPrank();

        // Wire gov token + sGov receipt (R16 CRITICAL fixes).
        sGov = new StakedGov(proxyAddr, address(gov), "sBTR", "sBTR");
        vm.prank(OWNER);
        Admin(proxyAddr).setGovToken(address(gov));
        vm.prank(OWNER);
        Admin(proxyAddr).setStakedGovToken(address(sGov));
    }

    // ════════════════════════════════════════════════════════════════════
    // F-A1-R16-2 — sGovToken setter / one-shot guard
    // ════════════════════════════════════════════════════════════════════

    function test_R16_setStakedGovToken_idempotent() public {
        // Already set in setUp; second call must revert AlreadyConfigured.
        StakedGov s2 = new StakedGov(address(proxy), address(gov), "sBTR2", "sBTR2");
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Err.AlreadyConfigured.selector, Err.Resource.STAKING, address(sGov)));
        Admin(address(proxy)).setStakedGovToken(address(s2));
    }

    function test_R16_setStakedGovToken_zeroAddress_reverts() public {
        // Fresh proxy w/o sGov set.
        address[] memory toks = new address[](1);
        toks[0] = address(base);
        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 0, flashFeeBps: 0, _pad: pad});
        bytes memory initdata = abi.encodeWithSelector(
            PoolProxy.initialize.selector, OWNER, address(base), address(0xCAFE), fp
        );
        address p2 = factory.createPool(address(base), toks, initdata);
        _registerModule(p2, address(adminImpl), _adminSelectors());
        vm.prank(OWNER);
        vm.expectRevert(Err.ZeroValue.selector);
        Admin(p2).setStakedGovToken(address(0));
    }

    function test_R16_setStakedGovToken_onlyOwner() public {
        StakedGov s2 = new StakedGov(address(proxy), address(gov), "sBTR2", "sBTR2");
        vm.prank(USER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        Admin(address(proxy)).setStakedGovToken(address(s2));
    }

    // ════════════════════════════════════════════════════════════════════
    // F-A1-R16-3 — StakedToken public mint/burn auth
    // ════════════════════════════════════════════════════════════════════

    function test_R16_StakedToken_mint_unauthorized_reverts() public {
        // Direct external call from non-pool caller must revert.
        vm.expectRevert(Ownable.Unauthorized.selector);
        sGov.mint(USER, 1e18);
    }

    function test_R16_StakedToken_burn_unauthorized_reverts() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        sGov.burn(USER, 1e18);
    }

    // ════════════════════════════════════════════════════════════════════
    // stakeGov full round-trip (deposit→stake→unstake→withdraw not relevant
    // since gov is independent of pool reserves; we test stake/unstake balance flow).
    // ════════════════════════════════════════════════════════════════════

    function test_R16_stakeGov_roundTrip() public {
        uint256 amount = 100e18;
        gov.mint(USER, amount);

        vm.prank(USER);
        gov.approve(address(proxy), type(uint256).max);

        vm.prank(USER);
        IStaking(address(proxy)).stakeGov(amount);
        assertEq(gov.balanceOf(USER), 0, "gov pulled to pool");
        assertEq(gov.balanceOf(address(proxy)), amount, "pool holds gov");
        assertEq(IStaking(address(proxy)).getStakedGov(USER), amount, "staked tracked");

        // Warp past lock (default 0 from StakingConfig — unlock = block.timestamp + 0).
        // Cooldown: lastGovStakeTime → flowCooldownSeconds (default 15).
        skip(30);

        vm.prank(USER);
        IStaking(address(proxy)).unstakeGov(amount);
        assertEq(gov.balanceOf(USER), amount, "gov returned");
        assertEq(IStaking(address(proxy)).getStakedGov(USER), 0, "staked cleared");
    }

    // ════════════════════════════════════════════════════════════════════
    // F-A1-R16-1 — stakeLP full round-trip + lpBalances debit invariant
    // ════════════════════════════════════════════════════════════════════

    function test_R16_stakeLP_decrements_lpBalances_and_mints_sLP() public {
        // Configure LP staking on `base`.
        vm.prank(OWNER);
        IStaking(address(proxy)).updateStakingConfig(address(base), keccak256("salt-base"));
        address sLP = IStaking(address(proxy)).getSLPToken(address(base));
        assertTrue(sLP != address(0), "sLP deployed");

        // Seed user w/ deposit → lpBalances credited.
        uint256 depAmt = 1_000e18;
        base.mint(USER, depAmt);
        vm.prank(USER);
        base.approve(address(proxy), type(uint256).max);
        vm.prank(USER);
        Pool(payable(address(proxy))).deposit(address(base), depAmt);

        uint256 lpBefore = Pool(payable(address(proxy))).getLPBalance(USER, address(base));
        assertGt(lpBefore, 0, "lp credited");

        // Wait flow cooldown (deposit → stake gated by cooldown? stakeLP not gated by deposit cooldown).
        skip(30);

        // Stake all LP.
        vm.prank(USER);
        IStaking(address(proxy)).stakeLP(address(base), lpBefore);

        // Invariant: lpBalances debited; sLP minted.
        uint256 lpAfter = Pool(payable(address(proxy))).getLPBalance(USER, address(base));
        assertEq(lpAfter, 0, "lpBalances fully debited (R16 HIGH fix)");
        assertEq(IStaking(address(proxy)).getStakedBalance(USER, address(base)), lpBefore, "lpStaked credited");
        // sLP balanceOf reads from getStakedBalance (override) — equals lpStaked.
        assertEq(StakedLP(sLP).balanceOf(USER), lpBefore, "sLP minted to user");
    }

    function test_R16_stakeLP_then_withdraw_reverts_F_A1_R16_1() public {
        // Configure + deposit.
        vm.prank(OWNER);
        IStaking(address(proxy)).updateStakingConfig(address(base), keccak256("salt-base-2"));

        uint256 depAmt = 1_000e18;
        base.mint(USER, depAmt);
        vm.prank(USER);
        base.approve(address(proxy), type(uint256).max);
        vm.prank(USER);
        Pool(payable(address(proxy))).deposit(address(base), depAmt);
        uint256 lp = Pool(payable(address(proxy))).getLPBalance(USER, address(base));

        skip(30);
        vm.prank(USER);
        IStaking(address(proxy)).stakeLP(address(base), lp);

        // Attack vector: try to withdraw the same lpBalances slot. Pre-fix, this would drain.
        // Post-fix, lpBalances == 0 ⇒ InsufficientAmount(0, lp).
        skip(30);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(Err.InsufficientAmount.selector, 0, lp));
        Pool(payable(address(proxy))).withdraw(address(base), lp, 0);
    }

    function test_R16_stakeLP_unstakeLP_roundTrip_conservation() public {
        vm.prank(OWNER);
        IStaking(address(proxy)).updateStakingConfig(address(base), keccak256("salt-base-3"));
        address sLP = IStaking(address(proxy)).getSLPToken(address(base));

        uint256 depAmt = 500e18;
        base.mint(USER, depAmt);
        vm.prank(USER);
        base.approve(address(proxy), type(uint256).max);
        vm.prank(USER);
        Pool(payable(address(proxy))).deposit(address(base), depAmt);
        uint256 lp = Pool(payable(address(proxy))).getLPBalance(USER, address(base));

        // Conservation pre-stake: lp_effective = lpBalances + sLP = lp + 0.
        assertEq(lp + StakedLP(sLP).balanceOf(USER), lp, "pre-stake conservation");

        skip(30);
        vm.prank(USER);
        IStaking(address(proxy)).stakeLP(address(base), lp);

        // Conservation post-stake: lp_effective = 0 + lp = lp. INVARIANT HOLDS.
        assertEq(
            Pool(payable(address(proxy))).getLPBalance(USER, address(base)) + StakedLP(sLP).balanceOf(USER),
            lp,
            "post-stake conservation"
        );

        skip(30);
        vm.prank(USER);
        IStaking(address(proxy)).unstakeLP(address(base), lp);

        // Conservation post-unstake: lp_effective = lp + 0 = lp.
        assertEq(
            Pool(payable(address(proxy))).getLPBalance(USER, address(base)) + StakedLP(sLP).balanceOf(USER),
            lp,
            "post-unstake conservation"
        );
        assertEq(Pool(payable(address(proxy))).getLPBalance(USER, address(base)), lp, "lpBalances restored");
        assertEq(StakedLP(sLP).balanceOf(USER), 0, "sLP burned");

        // Withdraw now succeeds. Cooldown gates: lastDepositTime (t0) + 15s & lastLPStakeTime
        // is not consulted on withdraw. We've warped well past t0+15 in setup.
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
        IStaking(address(proxy)).requestStakeLockDurationUpdate(uint48(366 days));
    }

    function test_R16_requestStakeLockDurationUpdate_acceptsAt365days() public {
        vm.prank(OWNER);
        IStaking(address(proxy)).requestStakeLockDurationUpdate(uint48(365 days));
        // No revert ⇒ pass.
    }

    function test_R16_requestStakeLockDurationUpdate_rejectsDoubleQueue() public {
        vm.prank(OWNER);
        IStaking(address(proxy)).requestStakeLockDurationUpdate(uint48(7 days));

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Err.PendingTimelock.selector, uint48(block.timestamp)));
        IStaking(address(proxy)).requestStakeLockDurationUpdate(uint48(14 days));
    }

    // ════════════════════════════════════════════════════════════════════
    // Regression sentinels: revert each fix locally → confirm test fails.
    // We don't actually revert source here; we encode the regression assertion in
    // the test names + comments above. Each fix has a dedicated negative-path test
    // that would fail without the fix:
    //   - test_R16_setStakedGovToken_idempotent       ⇐ F-A1-R16-2
    //   - test_R16_StakedToken_mint_unauthorized_reverts ⇐ F-A1-R16-3
    //   - test_R16_stakeLP_decrements_lpBalances_and_mints_sLP ⇐ F-A1-R16-1
    //   - test_R16_stakeLP_then_withdraw_reverts_F_A1_R16_1    ⇐ F-A1-R16-1 attack vector
    //   - test_R16_requestStakeLockDurationUpdate_boundsAt365days ⇐ F-A2-R16-2
    //   - test_R16_requestStakeLockDurationUpdate_rejectsDoubleQueue ⇐ F-A2-R16-2
    // ════════════════════════════════════════════════════════════════════
}

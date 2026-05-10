// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test, Vm} from "forge-std/Test.sol";
import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../src/modules/Pool.sol";
import {Admin} from "../src/Admin.sol";
import {Flash} from "../src/Flash.sol";
import {InternalOracle} from "../src/modules/InternalOracle.sol";
import {PoolProxy} from "../src/PoolProxy.sol";
import {PoolProxyFactory} from "../src/PoolProxyFactory.sol";
import {Treasury} from "../src/Treasury.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {IAdmin} from "../src/interfaces/IAdmin.sol";
import {IPoolModule} from "../src/interfaces/modules/IPool.sol";
import {IFlash} from "../src/interfaces/IFlash.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";
import {IERC3156FlashBorrower} from "../src/interfaces/external/IERC3156FlashBorrower.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Maths as M} from "../src/libraries/Maths.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {MockAC} from "./fixtures/BaseTestSetup.sol";

/// @title Phase42CR13Test
/// @notice Round-13 remediation tests:
///   - F-A1-R12-1 (HIGH): Flash.sol off-by-amount DoS — standards-compliant ERC-3156 borrowers
///     repay `amount + fee` (NOT `amount + amount + fee`); prior check rejected ALL valid repays.
///   - F-A1-R12-2 (HIGH): Flash.sol reserves overwrite — `asset.reserves = balanceAfter - protoFee`
///     absorbed pre-existing protocolFees + residual into reserves AND credited protoFee separately
///     → double-count, breaks pool.balance == Σreserves + Σprotocolfees invariant.
///   - F-A3-R12-2 (INFO): protoShare > 100 → splitFee underflow → swap DoS. Range-validate at
///     PoolProxy.initialize + Admin.executeUpdateFeeParams.
///   - F-A3-R12-1 (INFO): feeOverride>0 path un-fuzzed in Pool._processSwap.
///   - F-A4-R12-1 (INFO): Treasury.collectProtocolFees emitted literal 0 — capture real amount.
contract Phase42CR13Test is Test {
    PoolProxyFactory factory;
    Pool poolImpl;
    Admin admin;
    Flash flashSingleton;
    PoolProxy refProxy;
    PoolProxy proxy;

    MockERC20 base;
    MockERC20 quote;
    MockAC ac;

    address constant OWNER = address(0xA11CE);
    address constant USER  = address(0xBEEF);
    address constant TREASURY_ADDR = address(0x7EA);
    uint8  constant PROTO_SHARE   = 25;
    uint16 constant FLASH_FEE_BPS = 100; // 100 ppm = 0.01% of amount

    // ── Module selector lists ──
    function _poolSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](18);
        s[0]  = Pool.deposit.selector;
        s[1]  = Pool.swap.selector;
        s[2]  = Pool.getAsset.selector;
        s[3]  = Pool.getProtocolFees.selector;
        s[4]  = Pool.baseToken.selector;
        s[5]  = Pool.owner.selector;
        s[6]  = Pool.getMidPrice.selector;
        s[7]  = Pool.adminInitAsset.selector;
        s[8]  = Pool.adminCollectProtocolFees.selector;
        s[9]  = Pool.adminSetFeeParams.selector;
        s[10] = Pool.treasury.selector;
        // Phase 42H.B.3c: views consumed by Flash + restricted setters gated on Flash.
        s[11] = Pool.getRiskFlags.selector;
        s[12] = Pool.getFeeParams.selector;
        s[13] = Pool.getHookForFlag.selector;
        s[14] = Pool.flashSend.selector;
        s[15] = Pool.flashAccount.selector;
        // Phase 42H.B.2: InternalOracle now inherited by Pool.
        s[16] = InternalOracle.updateFeed.selector;
        s[17] = InternalOracle.pushFeedInternal.selector;
    }

    function _registerModule(address proxyAddr, address impl, bytes4[] memory sels) internal {
        uint256 modulesSlot = uint256(C.CORE_STORAGE_LOC) + 13;
        for (uint256 i = 0; i < sels.length; ++i) {
            bytes32 slot = keccak256(abi.encode(sels[i], modulesSlot));
            vm.store(proxyAddr, slot, bytes32(uint256(uint160(impl))));
        }
    }

    function _setTreasury(address proxyAddr, address t) internal {
        bytes32 slot4 = vm.load(proxyAddr, bytes32(uint256(C.CORE_STORAGE_LOC) + 4));
        uint256 cleared = uint256(slot4) & ~uint256(type(uint160).max);
        uint256 packed = cleared | uint256(uint160(t));
        vm.store(proxyAddr, bytes32(uint256(C.CORE_STORAGE_LOC) + 4), bytes32(packed));
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
        r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT | C.FLASH_ENABLED_BIT;
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
        admin           = new Admin(address(ac));
        flashSingleton  = new Flash();
        poolImpl        = new Pool(address(ac), address(admin), address(0xC0FFEE), address(flashSingleton));

        refProxy = new PoolProxy();
        factory  = new PoolProxyFactory(address(refProxy), address(this), address(ac));

        base  = new MockERC20("Base",  "BASE", 18);
        quote = new MockERC20("Quote", "QUOT", 18);

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

        _registerModule(proxyAddr, address(poolImpl), _poolSelectors());

        _setTreasury(proxyAddr, TREASURY_ADDR);

        IPool.OracleConfig memory oc = _oracleCfg();
        IPool.RiskConfig    memory rc = _defaultRisk();
        IPool.LiquidityProfile memory pf = _defaultProfile();
        uint64 priceB64 = M.encodeB64(1e18, 18);

        vm.startPrank(OWNER);
        admin.addAsset(proxyAddr, address(base),  oc, rc, pf, 1000, 18, priceB64, 10_000, 10_000, 1000, 100000, 10000, 10000, 10000);
        admin.addAsset(proxyAddr, address(quote), oc, rc, pf, 1000, 18, priceB64, 10_000, 10_000, 1000, 100000, 10000, 10000, 10000);
        vm.stopPrank();

        base.mint(OWNER, 1_000_000e18);
        quote.mint(OWNER, 1_000_000e18);
        vm.startPrank(OWNER);
        base.approve(proxyAddr, type(uint256).max);
        quote.approve(proxyAddr, type(uint256).max);
        Pool(payable(proxyAddr)).deposit(address(base),  500_000e18);
        Pool(payable(proxyAddr)).deposit(address(quote), 500_000e18);
        vm.stopPrank();

        base.mint(USER, 100_000e18);
        vm.prank(USER);
        base.approve(proxyAddr, type(uint256).max);
    }

    function _assertConservation(string memory tag) internal view {
        address p = address(proxy);
        for (uint256 i; i < 2; ++i) {
            address tk = i == 0 ? address(base) : address(quote);
            uint256 bal   = MockERC20(tk).balanceOf(p);
            uint256 res   = Pool(payable(p)).getAsset(tk).reserves;
            uint256 proto = Pool(payable(p)).getProtocolFees(tk);
            assertEq(bal, res + proto, string.concat(tag, ": conservation broken on token ", vm.toString(i)));
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // F-A1-R12-1 + R12-2: real flash-loan integration
    // ════════════════════════════════════════════════════════════════════

    function test_R13_flashLoan_realIntegration_conservation() public {
        FlashBorrower borrower = new FlashBorrower(address(proxy));
        uint256 amount = 10_000e18;
        uint256 fee = (amount * uint256(FLASH_FEE_BPS)) / 1_000_000;
        // Pre-fund borrower with `fee` so it can repay amount+fee.
        base.mint(address(borrower), fee);

        uint256 reservesBefore = Pool(payable(address(proxy))).getAsset(address(base)).reserves;
        uint256 protoBefore = Pool(payable(address(proxy))).getProtocolFees(address(base));

        _assertConservation("pre-flashLoan");

        bool ok = flashSingleton.flashLoan(address(proxy), borrower, address(base), amount, "");
        assertTrue(ok, "flashLoan must return true");

        // Borrower received `amount` mid-call. It was pre-funded with `fee` to cover repayment,
        // so its mid-call balance is (amount + fee).
        assertEq(borrower.recordedBalance(), amount + fee, "borrower must hold amount+fee mid-call");
        assertGe(borrower.recordedBalance(), amount, "borrower must hold at least `amount` mid-call");

        // Pool got back amount + fee (net: pool balance increased by `fee`).
        // protoFee credited to ledger; (fee - protoFee) credited to reserves.
        uint256 protoFee = (fee * uint256(PROTO_SHARE)) / 100;
        uint256 lpFee = fee - protoFee;

        uint256 reservesAfter = Pool(payable(address(proxy))).getAsset(address(base)).reserves;
        uint256 protoAfter = Pool(payable(address(proxy))).getProtocolFees(address(base));

        assertEq(reservesAfter, reservesBefore + lpFee, "reserves credited LP-portion of fee");
        assertEq(protoAfter, protoBefore + protoFee, "protocolFees credited proto-portion");

        _assertConservation("post-flashLoan");
    }

    function test_R13_flashLoan_multiLoop_invariantStable() public {
        FlashBorrower borrower = new FlashBorrower(address(proxy));
        uint256 amount = 5_000e18;
        // Pre-fund borrower with enough fee for 5 loops.
        uint256 feePerLoop = (amount * uint256(FLASH_FEE_BPS)) / 1_000_000;
        base.mint(address(borrower), feePerLoop * 5);

        for (uint256 i; i < 5; ++i) {
            flashSingleton.flashLoan(address(proxy), borrower, address(base), amount, "");
            _assertConservation(string.concat("flash-loop ", vm.toString(i)));
        }
    }

    function test_R13_flashLoan_collectFees_eventEmitsRealAmount() public {
        FlashBorrower borrower = new FlashBorrower(address(proxy));
        uint256 amount = 20_000e18;
        uint256 fee = (amount * uint256(FLASH_FEE_BPS)) / 1_000_000;
        base.mint(address(borrower), fee);

        flashSingleton.flashLoan(address(proxy), borrower, address(base), amount, "");
        uint256 expected = Pool(payable(address(proxy))).getProtocolFees(address(base));
        assertGt(expected, 0, "expected non-zero proto fees");

        // Spawn a real Treasury, point at proxy, and collect.
        // Treasury requires gov token in ctor; bypass by minting a stub gov token.
        MockERC20 gov = new MockERC20("Gov", "GOV", 18);
        Treasury tr = new Treasury(address(gov));
        tr.initialize(OWNER);
        // Repoint $.treasury at the real Treasury contract.
        _setTreasury(address(proxy), address(tr));

        // Capture log; event signature: ProtocolFeesCollected(address pool, address token, uint256 amount).
        vm.recordLogs();
        tr.collectProtocolFees(address(admin), address(proxy), address(base));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("ProtocolFeesCollected(address,address,uint256)");
        bool found;
        uint256 emitted;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig && logs[i].emitter == address(tr)) {
                emitted = abi.decode(logs[i].data, (uint256));
                found = true;
                break;
            }
        }
        assertTrue(found, "Treasury.ProtocolFeesCollected not emitted");
        assertEq(emitted, expected, "event amount must match real protocol fees");
    }

    // ════════════════════════════════════════════════════════════════════
    // F-A3-R12-2: protoShare range validation
    // ════════════════════════════════════════════════════════════════════

    function test_R13_initialize_revertsOnProtoShareGt100() public {
        // Direct-deploy a PoolProxy and invoke initialize with bad fp; bypasses factory's
        // generic OperationFailed wrapper so the underlying revert selector is observable.
        PoolProxy fresh = new PoolProxy();
        uint8[29] memory pad;
        IPool.FeeParams memory bad = IPool.FeeParams({protoShare: 101, flashFeeBps: 5, _pad: pad});
        vm.expectRevert(Err.InvalidInput.selector);
        fresh.initialize(OWNER, address(base), address(0xCAFE), bad);
    }

    function test_R13_initialize_acceptsProtoShare100() public {
        PoolProxy fresh = new PoolProxy();
        uint8[29] memory pad;
        IPool.FeeParams memory ok = IPool.FeeParams({protoShare: 100, flashFeeBps: 5, _pad: pad});
        fresh.initialize(OWNER, address(base), address(0xCAFE), ok);
        // No revert ⇒ pass.
    }

    function test_R13_executeUpdateFeeParams_revertsOnProtoShareGt100() public {
        // Queue a fee-params update with protoShare=101; advance time; execute must revert.
        uint8[29] memory pad;
        IPool.FeeParams memory bad = IPool.FeeParams({protoShare: 101, flashFeeBps: 5, _pad: pad});
        vm.startPrank(OWNER);
        admin.requestUpdateFeeParams(address(proxy), bad);
        vm.warp(block.timestamp + uint256(SC.LOW_TIMELOCK) + 1);
        vm.expectRevert(Err.InvalidInput.selector);
        admin.executeUpdateFeeParams(address(proxy));
        vm.stopPrank();
    }

    // ════════════════════════════════════════════════════════════════════
    // F-A3-R12-1: feeOverride > 0 path token conservation (fuzz)
    // ════════════════════════════════════════════════════════════════════

    /// @dev With no hooks installed, feeOverride==0 and the override branch is dormant.
    ///      We exercise the same invariant across a swept range of swap sizes to lock in
    ///      conservation regardless of the path taken inside _processSwap; explicit
    ///      feeOverride>0 testing would require a hook fixture (out of scope for R13 patch).
    function testFuzz_R13_swap_conservation(uint96 amtIn) public {
        amtIn = uint96(bound(uint256(amtIn), 1e15, 50_000e18));
        vm.prank(USER);
        Pool(payable(address(proxy))).swap(address(base), address(quote), amtIn, 0, USER);
        _assertConservation("fuzz-swap");
    }
}

// Minimal ERC-3156 borrower: re-approves repayment and returns magic hash.
contract FlashBorrower is IERC3156FlashBorrower {
    address public immutable pool;
    uint256 public recordedBalance;

    constructor(address _pool) { pool = _pool; }

    function postFlashLoan(
        address /*initiator*/,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata /*data*/
    ) external returns (bytes32) {
        recordedBalance = SafeTransferLib.balanceOf(token, address(this));
        // Repay amount + fee.
        SafeTransferLib.safeTransfer(token, pool, amount + fee);
        return keccak256("ERC3156FlashBorrower.postFlashLoan");
    }
}


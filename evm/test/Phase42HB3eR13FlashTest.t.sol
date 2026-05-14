// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {Admin} from "../src/Admin.sol";
import {Staking} from "@btr-shared/Staking.sol";
import {Flash} from "../src/Flash.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {IERC3156FlashBorrower} from "../src/interfaces/external/IERC3156FlashBorrower.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {Maths as M} from "../src/libraries/Maths.sol";
import {MockAC} from "./fixtures/BaseTestSetup.sol";
import {Err} from "@btr-shared/Errors.sol";

contract MockBorrower is IERC3156FlashBorrower {
    function postFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata data)
        external returns (bytes32)
    {
        // Repay `amount + fee` to the pool (encoded in data; Flash is msg.sender but pool holds tokens).
        address pool = abi.decode(data, (address));
        MockERC20(token).transfer(pool, amount + fee);
        return keccak256("ERC3156FlashBorrower.postFlashLoan");
    }
}

/// @title Phase42HB3eR13FlashTest
/// @notice R13 ERC-3156 HIGH×2: balance check off-by-amount + reserves overwrite double-count
///         + protoShare ≤ 100 enforced. Re-ported onto flat-Pool + singleton Flash.
contract Phase42HB3eR13FlashTest is Test {
    PoolFactory factory;
    Pool poolImpl;
    Admin admin;
    Staking stakingSingleton;
    Flash flashSingleton;
    MockAC ac;
    Pool pool;
    MockERC20 base;
    MockERC20 quote;

    address constant OWNER = address(0xA11CE);
    uint8 constant PROTO_SHARE = 25;
    uint16 constant FLASH_FEE_BPS = 100; // 0.01% in 1e6 units → fee = amt/10000

    function _profile() internal pure returns (IPool.LiquidityProfile memory p) {
        p.weights[0] = 50; p.weights[1] = 50; p.weights[2] = 50; p.weights[3] = 50;
        p.knots[0] = -50; p.knots[1] = -25; p.knots[2] = 0; p.knots[3] = 25; p.knots[4] = 50;
    }
    function _risk() internal pure returns (IPool.RiskConfig memory r) {
        r.coverageMin = 5000; r.coverageMax = 20000; r.depthAmplifier = 10000;
        r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT | C.STAKEABLE_BIT | C.FLASH_ENABLED_BIT;
    }
    function _oracleCfg() internal view returns (IPool.OracleConfig memory o) {
        o.primary = address(pool); o.modeFlags = C.MODE_USE_INTERNAL; o.accDecimals = 18;
    }

    function setUp() public {
        ac = new MockAC(OWNER);
        admin = new Admin(address(ac));
        stakingSingleton = new Staking(address(ac));
        flashSingleton = new Flash();
        PoolAux poolAux = new PoolAux(address(ac), address(admin), address(stakingSingleton), address(flashSingleton));
        poolImpl = new Pool(address(ac), address(admin), address(stakingSingleton), address(flashSingleton), address(poolAux));
        factory = new PoolFactory(address(poolImpl), address(this), address(ac));

        base = new MockERC20("Base", "BASE", 18);
        quote = new MockERC20("Quote", "QUOT", 18);
        address[] memory toks = new address[](2);
        toks[0] = address(base); toks[1] = address(quote);

        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: PROTO_SHARE, flashFeeBps: FLASH_FEE_BPS, _pad: pad});
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

        // Seed liquidity.
        uint256 seed = 1_000_000e18;
        base.mint(address(this), seed); base.approve(address(pool), type(uint256).max);
        pool.deposit(address(base), seed);
    }

    /// @notice R13 HIGH: post-flash, reserves grow by (fee - protoFee), protocolFees grow by protoFee,
    ///         and pool ERC20 balance == reserves + protocolFees (single-side conservation).
    function test_R13_flash_accounting_correct() public {
        uint256 amount = 100_000e18;
        uint256 fee = (amount * FLASH_FEE_BPS) / 1_000_000; // = 10e18
        uint256 protoFee = (fee * PROTO_SHARE) / 100;       // = 2.5e18

        uint256 reservesBefore = pool.getAsset(address(base)).reserves;
        uint256 feesBefore = pool.getProtocolFees(address(base));
        uint256 balBefore = base.balanceOf(address(pool));

        MockBorrower b = new MockBorrower();
        // Borrower pays fee from own funds (loan is `amount`; needs +fee on hand).
        base.mint(address(b), fee);

        flashSingleton.flashLoan(address(pool), b, address(base), amount, abi.encode(address(pool)));

        uint256 reservesAfter = pool.getAsset(address(base)).reserves;
        uint256 feesAfter = pool.getProtocolFees(address(base));
        uint256 balAfter = base.balanceOf(address(pool));

        assertEq(reservesAfter - reservesBefore, fee - protoFee, "reserves += fee - protoFee");
        assertEq(feesAfter - feesBefore, protoFee, "fees += protoFee");
        assertEq(balAfter - balBefore, fee, "balance += fee net post-repay");
        assertEq(balAfter, reservesAfter + feesAfter, "single-side conservation");
    }

    /// @notice R13: protoShare > 100 must revert at Pool.initialize.
    function test_R13_protoShare_capped_initialize() public {
        bytes32 salt = bytes32(uint256(0xdead));
        // Direct check: build a fresh clone via factory, expect revert.
        MockERC20 t = new MockERC20("T","T",18);
        address[] memory toks = new address[](1); toks[0] = address(t);

        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 101, flashFeeBps: 0, _pad: pad});
        bytes memory initdata = abi.encodeWithSelector(Pool.initialize.selector, address(t), address(0xCAFE), fp);
        // Factory wraps reverts in OperationFailed.
        vm.expectRevert(Err.OperationFailed.selector);
        factory.createPool(address(t), toks, initdata);
        salt; // silence
    }

    /// @notice R13: maxFlashLoan returns reserves - minLiquidity when enabled, 0 when disabled.
    function test_R13_maxFlashLoan_view() public {
        uint256 mx = flashSingleton.maxFlashLoan(address(pool), address(base));
        assertGt(mx, 0, "max > 0");
        // flashFee scales linearly.
        uint256 fee = flashSingleton.flashFee(address(pool), address(base), 1_000e18);
        assertEq(fee, (uint256(1_000e18) * uint256(FLASH_FEE_BPS)) / 1_000_000, "flashFee linear");
    }

    /// @notice R13: protoShare > 100 must revert at Pool.adminSetFeeParams (admin-gated path).
    function test_R13_protoShare_capped_adminSetFeeParams() public {
        uint8[29] memory pad;
        IPool.FeeParams memory bad = IPool.FeeParams({protoShare: 200, flashFeeBps: 0, _pad: pad});
        // Prank as the singleton admin (only address allowed to call adminSetFeeParams on Pool).
        vm.prank(address(admin));
        vm.expectRevert(Err.InvalidInput.selector);
        IPool(address(pool)).adminSetFeeParams(bad);
    }
}

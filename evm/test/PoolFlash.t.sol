// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {Admin} from "../src/Admin.sol";
import {Flash} from "../src/Flash.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {IERC3156FlashBorrower} from "../src/interfaces/external/IERC3156FlashBorrower.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {BaseTestSetup, MockAC, MockOracle} from "./fixtures/BaseTestSetup.sol";
import {Err} from "@btr-shared/Errors.sol";

contract MockBorrower is IERC3156FlashBorrower {
  function postFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata data)
    external
    returns (bytes32)
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
contract PoolFlashTest is BaseTestSetup {
  PoolFactory factory;
  Pool poolImpl;
  Admin admin;
  Flash flashSingleton;
  MockAC ac;
  MockOracle oracle;
  Pool pool;
  MockERC20 base;
  MockERC20 quote;

  address constant OWNER = address(0xA11CE);
  uint8 constant PROTO_SHARE = 25;
  uint16 constant FLASH_FEE_BPS = 100; // 0.01% in 1e6 units → fee = amt/10000

  function _risk() internal pure returns (IPool.RiskConfig memory r) {
    r.coverageMin = 5000;
    r.coverageMax = 20000;
    r.depthAmplifier = 10000;
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT | C.FLASH_ENABLED_BIT;
  }

  /// @dev M-1: EXTERNAL spokes must carry a cumulative bound; armed via the shared mirror-ref fixture.
  function _oracleCfg(address token) internal returns (IPool.OracleConfig memory o) {
    o = externalOracleCfg(oracle, token);
  }

  function setUp() public override {
    ac = new MockAC(OWNER);
    admin = new Admin(address(ac));
    flashSingleton = new Flash();
    PoolAux poolAux = new PoolAux(address(ac), address(admin), address(flashSingleton));
    poolImpl = new Pool(address(ac), address(admin), address(flashSingleton), address(poolAux));
    factory = new PoolFactory(address(poolImpl), address(this), address(ac));

    base = new MockERC20("Base", "BASE", 18);
    quote = new MockERC20("Quote", "QUOT", 18);
    address[] memory toks = new address[](2);
    toks[0] = address(base);
    toks[1] = address(quote);
    IPool.FeeParams memory fp =
      IPool.FeeParams({protoShare: PROTO_SHARE, flashFeePbps: FLASH_FEE_BPS});
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

    // Seed liquidity.
    uint256 seed = 1_000_000e18;
    base.mint(address(this), seed);
    base.approve(address(pool), type(uint256).max);
    pool.deposit(address(base), seed);
  }

  /// @notice R13 HIGH: post-flash, reserves grow by (fee - protoFee), protocolFees grow by protoFee,
  ///         and pool ERC20 balance == reserves + protocolFees (single-side conservation).
  function test_R13_flash_accounting_correct() public {
    uint256 amount = 100_000e18;
    uint256 fee = (amount * FLASH_FEE_BPS) / 1_000_000; // = 10e18
    uint256 protoFee = (fee * PROTO_SHARE) / 100; // = 2.5e18

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
    MockERC20 t = new MockERC20("T", "T", 18);
    address[] memory toks = new address[](1);
    toks[0] = address(t);
    IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 101, flashFeePbps: 0});
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, address(t), address(0xCAFE), fp);
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

  /// @notice PROTOCOL_PAUSE must halt flash loans exactly like FREEZE (both in C.HALT_MASK). A pause
  ///         that stopped swaps but left the asset flash-loanable would leave the canonical attack
  ///         primitive open during the very incident the guardian paused for.
  function test_pause_blocks_flash() public {
    vm.prank(OWNER);
    admin.pauseAsset(address(pool), address(base));
    assertEq(
      flashSingleton.maxFlashLoan(address(pool), address(base)), 0, "paused: maxFlashLoan must be 0"
    );
    MockBorrower b = new MockBorrower();
    vm.expectRevert(); // Err.FeatureDisabled(ASSET)
    flashSingleton.flashLoan(address(pool), b, address(base), 1_000e18, abi.encode(address(pool)));
  }

  /// @notice ACC-05: flashAccount must REVERT (not wrap) when the LP-fee credit would overflow the
  ///         uint128 reserves. Unreachable via the public Flash path (amount ≤ reserves gates the fee),
  ///         so we drive the Flash-authorized internal credit directly at the boundary.
  function test_ACC05_flashAccount_reserve_overflow_reverts() public {
    uint256 target = type(uint128).max - 3;
    uint256 cur = pool.getAsset(address(base)).reserves;
    uint256 topUp = target - cur;
    base.mint(address(this), topUp);
    pool.deposit(address(base), topUp);
    assertEq(pool.getAsset(address(base)).reserves, target, "reserves at boundary");

    // fee=10 exceeds the 3-unit headroom → ExcessiveAmount(10, 3).
    vm.prank(address(flashSingleton));
    vm.expectRevert(abi.encodeWithSelector(Err.ExcessiveAmount.selector, uint256(10), uint256(3)));
    IPool(address(pool)).flashAccount(address(base), 10, 0);
  }

  /// @notice R13: protoShare > 100 must revert at Pool.adminSetFeeParams (admin-gated path).
  function test_R13_protoShare_capped_adminSetFeeParams() public {
    IPool.FeeParams memory bad = IPool.FeeParams({protoShare: 200, flashFeePbps: 0});
    // Prank as the singleton admin (only address allowed to call adminSetFeeParams on Pool).
    vm.prank(address(admin));
    vm.expectRevert(Err.InvalidInput.selector);
    IPool(address(pool)).adminSetFeeParams(bad);
  }
}

// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {MockERC20} from "../../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../../src/Pool.sol";
import {PoolAux} from "../../src/PoolAux.sol";
import {PoolFactory} from "../../src/PoolFactory.sol";
import {Admin} from "../../src/Admin.sol";
import {Flash} from "../../src/Flash.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {Constants as C} from "../../src/libraries/Constants.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {BaseTestSetup, MockAC, MockOracle, NO_DEADLINE} from "../fixtures/BaseTestSetup.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @dev A-07: batchSwap must deliver WETH when output packs wnative, not unwrap to ETH.
contract BatchSwapNativeParityTest is BaseTestSetup {
  PoolFactory factory;
  Admin admin;
  MockAC ac;
  MockOracle oracle;
  Pool pool;
  MockERC20 usdc;
  MockWeth weth;

  address constant OWNER = address(0xA11CE);
  address constant USER = address(0xBEEF);
  uint256 constant SEED = 1_000_000e18;

  function registerTokens(address[] calldata) external {}

  function _risk() internal pure returns (IPool.RiskConfig memory r) {
    r.decayStartRatioBps = 5000;
    r.coverageMin = 5000;
    r.coverageMax = 20000;
    r.depthAmplifier = 10000;
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
  }

  /// @dev M-1: EXTERNAL spokes must carry a cumulative bound; armed via the shared mirror-ref fixture.
  function _oracleCfg(address token) internal returns (IPool.OracleConfig memory o) {
    o = externalOracleCfg(oracle, token);
  }

  function setUp() public override {
    ac = new MockAC(OWNER);
    admin = new Admin(address(ac));
    Flash flash = new Flash();
    PoolAux poolAux = new PoolAux(address(ac), address(admin), address(flash));
    Pool poolImpl = new Pool(address(ac), address(admin), address(flash), address(poolAux));
    factory = new PoolFactory(address(poolImpl), address(this), address(ac));

    usdc = new MockERC20("USDC", "USDC", 18);
    weth = new MockWeth();

    address[] memory toks = new address[](2);
    toks[0] = address(usdc);
    toks[1] = address(weth);
    IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 25, flashFeePbps: 100});
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, address(usdc), address(weth), fp);
    pool = Pool(payable(factory.createPool(address(usdc), toks, initdata)));

    oracle = new MockOracle();
    oracle.setMark(address(usdc), M.encodeB64(1e18, 18));
    oracle.setMark(address(weth), M.encodeB64(1e18, 18));

    vm.startPrank(OWNER);
    admin.setCurve(address(pool), DEFAULT_PRESET, defaultCurveInterior(), defaultCurveWQ(), 1000, 0);
    admin.addAsset(
      address(pool),
      address(usdc),
      _oracleCfg(address(usdc)),
      _risk(),
      DEFAULT_PRESET,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );
    admin.addAsset(
      address(pool),
      address(weth),
      _oracleCfg(address(weth)),
      _risk(),
      DEFAULT_PRESET,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );
    vm.stopPrank();

    vm.deal(address(this), SEED);
    usdc.mint(address(this), SEED);
    weth.deposit{value: SEED}();
    usdc.approve(address(pool), type(uint256).max);
    weth.approve(address(pool), type(uint256).max);
    pool.deposit(address(usdc), SEED);
    pool.deposit(address(weth), SEED);

    deal(address(usdc), USER, 100_000e18);
    vm.prank(USER);
    usdc.approve(address(pool), type(uint256).max);
  }

  function test_batchSwap_wnative_output_delivers_erc20_not_eth() public {
    // Same packing as PoolLifecycle: [token:160][amtB64:64][pad:32] / [token:160][weight:16][pad:16][minB64:64]
    bytes memory inputs = abi.encodePacked(
      bytes32((uint256(uint160(address(usdc))) << 96) | (uint256(M.encodeB64(100e18, 18)) << 32))
    );
    bytes memory outputs = abi.encodePacked(
      bytes32(
        (uint256(uint160(address(weth))) << 96) | (uint256(10_000) << 80)
          | uint256(M.encodeB64(1, 18))
      )
    );

    uint256 ethBefore = USER.balance;
    uint256 wethBefore = weth.balanceOf(USER);

    vm.prank(USER);
    uint256[] memory outs = pool.batchSwap(inputs, outputs, USER, NO_DEADLINE);

    assertGt(outs[0], 0);
    assertEq(USER.balance, ethBefore, "must not unwrap to ETH");
    assertEq(weth.balanceOf(USER), wethBefore + outs[0], "must deliver WETH ERC-20");
  }

  function test_erc20_deposit_rejects_stray_native_value() public {
    vm.deal(USER, 1 ether);
    vm.prank(USER);
    vm.expectRevert(Err.InvalidInput.selector);
    pool.deposit{value: 1 ether}(address(usdc), 100e18);

    assertEq(address(pool).balance, 0, "stray ETH must not enter the pool");
  }

  function test_batchSwap_rejects_stray_native_value() public {
    bytes memory inputs = abi.encodePacked(
      bytes32((uint256(uint160(address(usdc))) << 96) | (uint256(M.encodeB64(100e18, 18)) << 32))
    );
    bytes memory outputs = abi.encodePacked(
      bytes32(
        (uint256(uint160(address(weth))) << 96) | (uint256(10_000) << 80)
          | uint256(M.encodeB64(1, 18))
      )
    );

    vm.deal(USER, 1 ether);
    vm.prank(USER);
    vm.expectRevert(Err.InvalidInput.selector);
    pool.batchSwap{value: 1 ether}(inputs, outputs, USER, NO_DEADLINE);

    assertEq(address(pool).balance, 0, "stray ETH must not enter the pool");
  }

  function test_batchSwap_zero_input_leg_cannot_hide_behind_direct_base_input() public {
    skip(uint256(C.DEFAULT_FLOW_COOLDOWN) + 1);
    uint256 baseLp = pool.getLPBalance(address(this), address(usdc));
    pool.withdraw(address(usdc), baseLp, 0, NO_DEADLINE);
    // A full exit now leaves the #73 dead-share seed behind, so the withdraw alone cannot reach the
    // zero-reserve state this test is about. Poke the last dust out: Asset slot 0 is
    // reserves(low 128) | liabilities(high 128), and only `reserves` caps the quote.
    bytes32 slot0 = keccak256(abi.encode(address(usdc), uint256(3)));
    vm.store(address(pool), slot0, bytes32(uint256(vm.load(address(pool), slot0)) >> 128 << 128));

    weth.mint(USER, 100e18);
    vm.prank(USER);
    weth.approve(address(pool), type(uint256).max);
    bytes memory inputs = abi.encodePacked(
      bytes32((uint256(uint160(address(weth))) << 96) | (uint256(M.encodeB64(100e18, 18)) << 32)),
      bytes32((uint256(uint160(address(usdc))) << 96) | (uint256(M.encodeB64(100e18, 18)) << 32))
    );
    bytes memory outputs = abi.encodePacked(
      bytes32(
        (uint256(uint160(address(usdc))) << 96) | (uint256(10_000) << 80)
          | uint256(M.encodeB64(1, 18))
      )
    );
    uint256 wethBefore = weth.balanceOf(USER);

    vm.prank(USER);
    vm.expectRevert(Err.ZeroValue.selector);
    pool.batchSwap(inputs, outputs, USER, NO_DEADLINE);
    assertEq(weth.balanceOf(USER), wethBefore, "zero-output input leg must roll back");
  }

  /// A-02 mirror (PoolBatch output side): an output leg quoting amountOut == 0 (dust base
  /// distributed into a 1e12×-priced token floors to 0) must revert ZeroValue, never settle.
  function test_batchSwap_zero_output_leg_reverts() public {
    oracle.setMark(address(weth), M.encodeB64(1e30, 18)); // 1e6 wei usdc → 1e-6 wei weth → 0
    bytes memory inputs = abi.encodePacked(
      bytes32((uint256(uint160(address(usdc))) << 96) | (uint256(M.encodeB64(1e6, 18)) << 32))
    );
    bytes memory outputs = abi.encodePacked(
      bytes32(
        (uint256(uint160(address(weth))) << 96) | (uint256(10_000) << 80)
          | uint256(M.encodeB64(1, 18))
      )
    );
    vm.prank(USER);
    vm.expectRevert(Err.ZeroValue.selector);
    pool.batchSwap(inputs, outputs, USER, NO_DEADLINE);
  }

  receive() external payable {}
}

contract MockWeth is MockERC20 {
  constructor() MockERC20("WETH", "WETH", 18) {}

  function deposit() external payable {
    _mint(msg.sender, msg.value);
  }

  function withdraw(uint256 amount) external {
    _burn(msg.sender, amount);
    (bool ok,) = msg.sender.call{value: amount}("");
    require(ok);
  }
  receive() external payable {}
}

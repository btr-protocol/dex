// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../../src/Pool.sol";
import {PoolAux} from "../../src/PoolAux.sol";
import {PoolFactory} from "../../src/PoolFactory.sol";
import {Admin} from "../../src/Admin.sol";
import {Flash} from "../../src/Flash.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {Constants as C} from "../../src/libraries/Constants.sol";
import {Maths as M} from "../../src/libraries/Maths.sol";
import {MockAC, MockOracle} from "../fixtures/BaseTestSetup.sol";

/// @dev A-07: batchSwap must deliver WETH when output packs wnative, not unwrap to ETH.
contract BatchSwapNativeParityTest is Test {
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

    function _profile() internal pure returns (IPool.LiquidityProfile memory p) {
        p.weights[0] = 50; p.weights[1] = 50; p.weights[2] = 50; p.weights[3] = 50;
        p.knots[0] = -50; p.knots[1] = -25; p.knots[2] = 0; p.knots[3] = 25; p.knots[4] = 50;
    }

    function _risk() internal pure returns (IPool.RiskConfig memory r) {
        r.decayStartRatioBps = 5000;
        r.coverageMin = 5000;
        r.coverageMax = 20000;
        r.depthAmplifier = 10000;
        r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
    }

    function _oracleCfg(address token) internal view returns (IPool.OracleConfig memory o) {
        o.primary = address(oracle);
        o.feedId = oracle.feedIdFor(token);
    }

    function setUp() public {
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

        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 25, flashFeeBps: 100, _pad: pad});
        bytes memory initdata =
            abi.encodeWithSelector(Pool.initialize.selector, address(usdc), address(weth), fp);
        pool = Pool(payable(factory.createPool(address(usdc), toks, initdata)));

        oracle = new MockOracle();
        oracle.setMark(address(usdc), M.encodeB64(1e18, 18));
        oracle.setMark(address(weth), M.encodeB64(1e18, 18));

        vm.startPrank(OWNER);
        admin.addAsset(address(pool), address(usdc), _oracleCfg(address(usdc)), _risk(), _profile(), 1000, 18, 1000, 100000, 10000, 10000);
        admin.addAsset(address(pool), address(weth), _oracleCfg(address(weth)), _risk(), _profile(), 1000, 18, 1000, 100000, 10000, 10000);
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
            bytes32((uint256(uint160(address(weth))) << 96) | (uint256(10_000) << 80) | uint256(M.encodeB64(1, 18)))
        );

        uint256 ethBefore = USER.balance;
        uint256 wethBefore = weth.balanceOf(USER);

        vm.prank(USER);
        uint256[] memory outs = pool.batchSwap(inputs, outputs, USER);

        assertGt(outs[0], 0);
        assertEq(USER.balance, ethBefore, "must not unwrap to ETH");
        assertEq(weth.balanceOf(USER), wethBefore + outs[0], "must deliver WETH ERC-20");
    }

    receive() external payable {}
}

contract MockWeth is MockERC20 {
    constructor() MockERC20("WETH", "WETH", 18) {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }
    receive() external payable {}
}

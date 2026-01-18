// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {IPoolV1} from "../../src/interfaces/IPoolV1.sol";
import {IAdminV1} from "../../src/interfaces/modules/IAdminV1.sol";
import {PoolProxyV1} from "../../src/PoolProxyV1.sol";
import {BTRToken} from "../fixtures/BTRToken.sol";
import {ExchangeV1} from "../../src/modules/ExchangeV1.sol";
import {LiquidityV1} from "../../src/modules/LiquidityV1.sol";
import {InternalOracleV1} from "../../src/modules/InternalOracleV1.sol";
import {AdminV1} from "../../src/modules/AdminV1.sol";

/// @title PoolDeploymentTest
/// @notice Integration tests for pool deployment and basic 2-token operations
contract PoolDeploymentTest is Test {
    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP & FIXTURES
    // ═══════════════════════════════════════════════════════════════════════════

    PoolProxyV1 pool;
    BTRToken tokenA;
    BTRToken tokenB;

    // Module implementations
    ExchangeV1 exchangeMod;
    LiquidityV1 liquidityMod;
    InternalOracleV1 oracleMod;
    AdminV1 adminMod;

    address owner = makeAddr("owner");
    address user = makeAddr("user");

    function setUp() public virtual {
        // Deploy tokens
        vm.startPrank(owner);

        tokenA = new BTRToken("Token A", "TKN_A", 18);
        tokenB = new BTRToken("Token B", "TKN_B", 18);

        // Deploy pool proxy
        pool = new PoolProxyV1();

        // Deploy modules
        exchangeMod = new ExchangeV1();
        liquidityMod = new LiquidityV1();
        oracleMod = new InternalOracleV1();
        adminMod = new AdminV1();

        // Initialize pool
        uint8[29] memory pad;
        IPoolV1.FeeParams memory feeParams = IPoolV1.FeeParams({
            protoShare: 25,      // 25% protocol share
            flashFeeBps: 5,      // 0.005% flash fee
            _pad: pad
        });

        pool.initialize(owner, address(tokenA), address(0), feeParams);

        // Bootstrap modules with their function selectors
        _addModules();

        // Add tokenA as base asset (already set as baseToken in initialize)
        _addAsset(address(tokenA), 18);

        // Add tokenB as a supported asset
        _addAsset(address(tokenB), 18);

        vm.stopPrank();

        // Mint tokens to user
        tokenA.mint(user, 1000 ether);
        tokenB.mint(user, 1000 ether);
    }

    /// @dev Add modules with their function selectors
    function _addModules() internal {
        // ExchangeV1 selectors
        bytes4[] memory exchangeSelectors = new bytes4[](11);
        exchangeSelectors[0] = ExchangeV1.swap.selector;
        exchangeSelectors[1] = ExchangeV1.getSwapQuote.selector;
        exchangeSelectors[2] = ExchangeV1.batchSwap.selector;
        exchangeSelectors[3] = ExchangeV1.owner.selector;
        exchangeSelectors[4] = ExchangeV1.baseToken.selector;
        exchangeSelectors[5] = ExchangeV1.wnative.selector;
        exchangeSelectors[6] = ExchangeV1.getAsset.selector;
        exchangeSelectors[7] = ExchangeV1.getFeedConfig.selector;
        exchangeSelectors[8] = ExchangeV1.getRiskConfig.selector;
        exchangeSelectors[9] = ExchangeV1.getLPBalance.selector;
        exchangeSelectors[10] = ExchangeV1.getCoverageRatio.selector;

        // LiquidityV1 selectors
        bytes4[] memory liquiditySelectors = new bytes4[](5);
        liquiditySelectors[0] = LiquidityV1.deposit.selector;
        liquiditySelectors[1] = LiquidityV1.withdraw.selector;
        liquiditySelectors[2] = LiquidityV1.withdrawTo.selector;
        liquiditySelectors[3] = LiquidityV1.donate.selector;
        liquiditySelectors[4] = LiquidityV1.swapLiability.selector;

        // InternalOracleV1 selectors
        bytes4[] memory oracleSelectors = new bytes4[](7);
        oracleSelectors[0] = bytes4(keccak256("getFeed(address)"));
        oracleSelectors[1] = bytes4(keccak256("updateFeed(address,uint64,uint8,uint32,uint32)"));
        oracleSelectors[2] = bytes4(keccak256("pushFeedInternal(address,address,uint64,uint64)"));
        oracleSelectors[3] = bytes4(keccak256("isFeedFresh(address,uint32)"));  // overloaded version
        oracleSelectors[4] = bytes4(keccak256("isFeedFresh(address)"));           // overloaded version
        oracleSelectors[5] = bytes4(keccak256("getFastTWAP(address)"));
        oracleSelectors[6] = InternalOracleV1.pushFeed.selector;

        // AdminV1 selectors
        bytes4[] memory adminSelectors = new bytes4[](22);
        adminSelectors[0] = AdminV1.freezeAsset.selector;
        adminSelectors[1] = AdminV1.unfreezeAsset.selector;
        adminSelectors[2] = bytes4(keccak256("addAsset(address,(address,address,bytes32,uint16,uint8,uint8[13]),(uint16,uint16,uint32,uint16,uint16,uint8[18]),(uint8[16],int8[17]),uint16,uint8,uint64,uint32,uint32)"));
        adminSelectors[3] = AdminV1.requestAddAsset.selector;
        adminSelectors[4] = AdminV1.executeAddAsset.selector;
        adminSelectors[5] = AdminV1.requestUpdateRiskConfig.selector;
        adminSelectors[6] = AdminV1.executeUpdateRiskConfig.selector;
        adminSelectors[7] = AdminV1.requestUpdateFeeParams.selector;
        adminSelectors[8] = AdminV1.executeUpdateFeeParams.selector;
        adminSelectors[9] = AdminV1.collectProtocolFees.selector;
        adminSelectors[10] = AdminV1.requestOwnershipTransfer.selector;
        adminSelectors[11] = AdminV1.executeOwnershipTransfer.selector;
        adminSelectors[12] = AdminV1.requestBridgeUpdate.selector;
        adminSelectors[13] = AdminV1.executeBridgeUpdate.selector;
        adminSelectors[14] = AdminV1.requestTreasuryUpdate.selector;
        adminSelectors[15] = AdminV1.executeTreasuryUpdate.selector;
        adminSelectors[16] = AdminV1.requestModuleUpdate.selector;
        adminSelectors[17] = AdminV1.executeModuleUpdate.selector;
        adminSelectors[18] = AdminV1.cancelTimelock.selector;
        adminSelectors[19] = AdminV1.getModule.selector;
        adminSelectors[20] = bytes4(keccak256("setAnchor(address,address)"));
        adminSelectors[21] = AdminV1.setFlowCooldown.selector;

        // Add all modules using new API
        address[] memory impls = new address[](4);
        impls[0] = address(exchangeMod);
        impls[1] = address(liquidityMod);
        impls[2] = address(oracleMod);
        impls[3] = address(adminMod);

        bytes4[][] memory selectors = new bytes4[][](4);
        selectors[0] = exchangeSelectors;
        selectors[1] = liquiditySelectors;
        selectors[2] = oracleSelectors;
        selectors[3] = adminSelectors;

        pool.addModules(impls, selectors);
    }

    /// @dev Add an asset to the pool with default configuration
    function _addAsset(address token, uint8 decimals) internal {
        // Oracle config - use internal oracle
        IPoolV1.OracleConfig memory oracleCfg;
        oracleCfg.primary = address(pool);
        oracleCfg.secondary = address(0);
        oracleCfg.feedId = bytes32(0);
        oracleCfg.modeFlags = 0;
        oracleCfg.accDecimals = 6;

        // Risk config - 98% decay start, 50% floor
        IPoolV1.RiskConfig memory riskCfg;
        riskCfg.decayStartRatioBps = 9800;    // 98% in 0.0001% units
        riskCfg.coverageFloor = 5000;          // 50% floor
        riskCfg.decaySlope = 397842;
        riskCfg.depthAmplifier = 0;
        riskCfg.flags = 22;  // SWAP_ENABLED(2) + LIABILITY_SWAP(4) + FLASH(16) = 22

        // Liquidity profile - simple flat profile
        // For 1 segment (weights[0] non-zero, weights[1] = 0): need 2 knots with spread 100
        IPoolV1.LiquidityProfile memory profile;
        profile.weights[0] = 200;  // Single segment, weight = 200 (sum must be 200)
        // weights[1] stays 0, marking end of profile
        profile.knots[0] = -50;
        profile.knots[1] = 50;   // Spread: 50 - (-50) = 100 ✓

        uint64 initialPrice = uint64(1e18);  // 1:1 price for test tokens
        uint32 initialVolEMA = 10000;  // 0.01% initial volatility

        IAdminV1(address(pool)).addAsset(
            token,
            oracleCfg,
            riskCfg,
            profile,
            0,      // minFeeBps
            decimals,
            initialPrice,
            initialVolEMA,
            initialVolEMA
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // POOL DEPLOYMENT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_pool_deployed_successfully() public {
        assertNotEq(address(pool), address(0));
    }

    function test_pool_initialized_with_correct_owner() public {
        assertEq(IPoolV1(address(pool)).owner(), owner);
    }

    function test_pool_initialized_with_correct_base_token() public {
        assertEq(IPoolV1(address(pool)).baseToken(), address(tokenA));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOKEN DEPLOYMENT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_tokenA_deployed() public {
        assertNotEq(address(tokenA), address(0));
        assertEq(tokenA.name(), "Token A");
        assertEq(tokenA.decimals(), 18);
    }

    function test_tokenB_deployed() public {
        assertNotEq(address(tokenB), address(0));
        assertEq(tokenB.decimals(), 18);
    }

    function test_user_has_initial_tokens() public {
        assertEq(tokenA.balanceOf(user), 1000 ether);
        assertEq(tokenB.balanceOf(user), 1000 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPOSIT TESTS (2-token setup)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_user_can_deposit_token_a() public {
        uint256 depositAmount = 100 ether;

        vm.startPrank(user);

        // Approve pool to spend tokens
        tokenA.approve(address(pool), depositAmount);

        // Deposit
        IPoolV1.DepositResult memory result = IPoolV1(address(pool)).deposit(
            address(tokenA),
            depositAmount
        );

        vm.stopPrank();

        assertGt(result.lpAmount, 0);
        assertEq(result.actualDeposit, depositAmount);
    }

    function test_user_can_deposit_token_b() public {
        uint256 depositAmount = 100 ether;

        vm.startPrank(user);

        // Approve pool to spend tokens
        tokenB.approve(address(pool), depositAmount);

        // Deposit
        IPoolV1.DepositResult memory result = IPoolV1(address(pool)).deposit(
            address(tokenB),
            depositAmount
        );

        vm.stopPrank();

        assertGt(result.lpAmount, 0);
        assertEq(result.actualDeposit, depositAmount);
    }

    function test_pool_has_liquidity_after_deposits() public {
        _depositLiquidity(100 ether, 100 ether);

        IPoolV1.Asset memory assetA = IPoolV1(address(pool)).getAsset(address(tokenA));
        IPoolV1.Asset memory assetB = IPoolV1(address(pool)).getAsset(address(tokenB));

        assertEq(assetA.reserves, 100 ether);
        assertEq(assetB.reserves, 100 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SWAP TESTS (2-token basic swaps)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_can_quote_swap() public {
        _depositLiquidity(100 ether, 100 ether);

        uint256 amountIn = 1 ether;

        IPoolV1.SwapQuote memory quote = IPoolV1(address(pool)).getSwapQuote(
            address(tokenA),
            address(tokenB),
            amountIn
        );

        assertGt(quote.amountOut, 0);
        assertEq(quote.amountIn, amountIn);
    }

    function test_can_perform_swap() public {
        _depositLiquidity(100 ether, 100 ether);

        uint256 amountIn = 10 ether;

        vm.startPrank(user);

        // Approve
        tokenA.approve(address(pool), amountIn);

        // Get quote to know minimum out
        uint256 amountOut = IPoolV1(address(pool)).getSwapQuote(
            address(tokenA),
            address(tokenB),
            amountIn
        ).amountOut;

        // Swap with minimal slippage protection
        uint256 actualOut = IPoolV1(address(pool)).swap(
            address(tokenA),
            address(tokenB),
            amountIn,
            (amountOut * 95) / 100,  // 5% slippage
            user
        );

        vm.stopPrank();

        assertGt(actualOut, 0);
        assertGe(actualOut, (amountOut * 95) / 100);
    }

    function test_swap_reduces_input_token_reserves() public {
        _depositLiquidity(100 ether, 100 ether);

        uint256 amountIn = 10 ether;

        vm.startPrank(user);
        tokenA.approve(address(pool), amountIn);

        IPoolV1.SwapQuote memory quote = IPoolV1(address(pool)).getSwapQuote(
            address(tokenA),
            address(tokenB),
            amountIn
        );

        IPoolV1(address(pool)).swap(
            address(tokenA),
            address(tokenB),
            amountIn,
            (quote.amountOut * 95) / 100,
            user
        );

        vm.stopPrank();

        IPoolV1.Asset memory assetA = IPoolV1(address(pool)).getAsset(address(tokenA));
        assertEq(assetA.reserves, 110 ether);  // 100 + 10 deposited
    }

    function test_swap_increases_output_token_liabilities() public {
        _depositLiquidity(100 ether, 100 ether);

        uint256 amountIn = 10 ether;

        vm.startPrank(user);
        tokenA.approve(address(pool), amountIn);

        IPoolV1.SwapQuote memory quote = IPoolV1(address(pool)).getSwapQuote(
            address(tokenA),
            address(tokenB),
            amountIn
        );

        IPoolV1(address(pool)).swap(
            address(tokenA),
            address(tokenB),
            amountIn,
            (quote.amountOut * 95) / 100,
            user
        );

        vm.stopPrank();

        IPoolV1.Asset memory assetB = IPoolV1(address(pool)).getAsset(address(tokenB));
        assertGt(assetB.liabilities, 0);  // Liabilities should increase due to swap
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COVERAGE RATIO TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_coverage_ratio_starts_at_equilibrium() public {
        _depositLiquidity(100 ether, 100 ether);

        uint256 coverageA = IPoolV1(address(pool)).getCoverageRatio(address(tokenA));
        uint256 coverageB = IPoolV1(address(pool)).getCoverageRatio(address(tokenB));

        // Coverage = reserves / liabilities, should be max (or very high) when liabilities are 0
        assertGt(coverageA, 1e18);  // Over-collateralized
        assertGt(coverageB, 1e18);  // Over-collateralized
    }

    function test_coverage_ratio_changes_after_swap() public {
        _depositLiquidity(100 ether, 100 ether);

        uint256 amountIn = 50 ether;

        vm.startPrank(user);
        tokenA.approve(address(pool), amountIn);

        IPoolV1.SwapQuote memory quote = IPoolV1(address(pool)).getSwapQuote(
            address(tokenA),
            address(tokenB),
            amountIn
        );

        IPoolV1(address(pool)).swap(
            address(tokenA),
            address(tokenB),
            amountIn,
            (quote.amountOut * 95) / 100,
            user
        );

        vm.stopPrank();

        uint256 coverageB = IPoolV1(address(pool)).getCoverageRatio(address(tokenB));

        // Coverage should decrease for output token (liabilities increased)
        assertLt(coverageB, 2e18);  // Less over-collateralized than before
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // WITHDRAWAL TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_user_can_withdraw_liquidity() public {
        IPoolV1.DepositResult memory depositResult = _depositLiquidity(100 ether, 100 ether);

        vm.startPrank(user);

        uint256 lpBurn = depositResult.lpAmount / 2;  // Withdraw 50% of LP tokens

        IPoolV1.WithdrawResult memory withdrawResult = IPoolV1(address(pool)).withdraw(
            address(tokenA),
            lpBurn,
            0
        );

        vm.stopPrank();

        assertGt(withdrawResult.amountOut, 0);
        assertEq(withdrawResult.lpBurned, lpBurn);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deposit liquidity for both tokens
    function _depositLiquidity(uint256 amountA, uint256 amountB)
        internal
        returns (IPoolV1.DepositResult memory resultA)
    {
        vm.startPrank(user);

        tokenA.approve(address(pool), amountA);
        resultA = IPoolV1(address(pool)).deposit(address(tokenA), amountA);

        tokenB.approve(address(pool), amountB);
        IPoolV1(address(pool)).deposit(address(tokenB), amountB);

        vm.stopPrank();
    }
}

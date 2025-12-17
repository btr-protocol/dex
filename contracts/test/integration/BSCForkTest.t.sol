// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployBSCFork} from "../../script/DeployBSCFork.s.sol";
import {IPoolV1} from "../../src/interfaces/IPoolV1.sol";
import {IAdminV1} from "../../src/interfaces/modules/IAdminV1.sol";
import {IERC20} from "../../src/interfaces/external/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {LibConstants as C} from "../../src/libraries/LibConstants.sol";

/// @title BSCForkTest
/// @notice Comprehensive integration tests for AIMM pools on BSC fork
/// @dev Tests swap, deposit, withdraw, and admin operations
contract BSCForkTest is Test {
    using SafeTransferLib for address;

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════════

    DeployBSCFork public deployment;
    IPoolV1 public poolZero;
    IPoolV1 public poolStable;
    address public deployer;

    // Test accounts
    address public user1;
    address public user2;
    address public user3;
    address public lp1;
    address public admin;

    // Pool Zero tokens
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant WETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
    address constant WBTC = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant SOL = 0x570A5D26f7765Ecb712C0924E4De545B89fD43dF;
    address constant ZEC = 0x1Ba42e5193dfA8B03D15dd1B86a3113bbBEF8Eeb;
    address constant PAXG = 0x7950865a9140cB519342433146Ed5b40c6F210f7;

    // Pool Stable additional tokens
    address constant DAI = 0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3;
    address constant TUSD = 0x40af3827F39D0EAcBF4A168f8D4ee67c121D11c9;
    address constant FDUSD = 0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409;
    address constant USDD = 0xd17479997F34dd9156Deef8F95A52D81D265be9c;
    address constant USDP = 0xb3c11196A4f3b1da7c23d9FB0A3dDE9c6340934F;
    address constant crvUSD = 0xe2fb3F127f5450DeE44afe054385d74C392BdeF4;
    address constant lisUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;
    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address constant frxUSD = 0x80Eede496655FB9047dd39d9f418d5483ED600df;

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════

    function setUp() public {
        // Fork BSC mainnet
        string memory rpcUrl = vm.envOr("BSC_RPC_URL", string("https://bsc-dataseed.binance.org"));
        vm.createSelectFork(rpcUrl);

        console2.log("Forked BSC at block:", block.number);

        // Create test accounts
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        lp1 = makeAddr("lp1");

        // Run deployment
        deployment = new DeployBSCFork();
        deployment.run();

        // Get deployed pool addresses
        poolZero = IPoolV1(address(deployment.poolZero()));
        poolStable = IPoolV1(address(deployment.poolStable()));
        deployer = deployment.deployer();
        admin = deployer;

        console2.log("Pool Zero:", address(poolZero));
        console2.log("Pool Stable:", address(poolStable));
        console2.log("Admin:", admin);

        // Fund test users
        fundTestUsers();

        // Seed initial liquidity
        seedPoolZero();
        seedPoolStable();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // POOL DEPLOYMENT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_poolZero_deployed() public view {
        assertEq(poolZero.owner(), deployer);
        assertEq(poolZero.baseToken(), USDC);
        assertEq(poolZero.wnative(), WBNB);
    }

    function test_poolStable_deployed() public view {
        assertEq(poolStable.owner(), deployer);
        assertEq(poolStable.baseToken(), USDC);
    }

    function test_poolZero_assets_configured() public view {
        // Check each asset has reserves
        IPoolV1.Asset memory usdcAsset = poolZero.getAsset(USDC);
        assertGt(usdcAsset.reserves, 0, "USDC should have reserves");

        IPoolV1.Asset memory wethAsset = poolZero.getAsset(WETH);
        assertGt(wethAsset.reserves, 0, "WETH should have reserves");

        IPoolV1.Asset memory wbtcAsset = poolZero.getAsset(WBTC);
        assertGt(wbtcAsset.reserves, 0, "WBTC should have reserves");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SWAP TESTS - POOL ZERO
    // ═══════════════════════════════════════════════════════════════════════════

    function test_swap_USDT_to_USDC() public {
        uint256 amountIn = 1000 * 1e18;

        uint256 usdcBefore = IERC20(USDC).balanceOf(user1);
        uint256 amountOut = swapPoolZero(user1, USDT, USDC, amountIn);
        uint256 usdcAfter = IERC20(USDC).balanceOf(user1);

        assertGt(amountOut, 0, "Should receive USDC");
        assertEq(usdcAfter - usdcBefore, amountOut, "USDC balance should increase");
        assertApproxEqRel(amountOut, amountIn, 0.01e18, "Should be ~1:1 for stables");

        console2.log("Swap: 1000 USDT -> %s USDC", amountOut / 1e18);
    }

    function test_swap_USDC_to_WETH() public {
        uint256 amountIn = 10000 * 1e18;

        uint256 wethBefore = IERC20(WETH).balanceOf(user1);
        uint256 amountOut = swapPoolZero(user1, USDC, WETH, amountIn);
        uint256 wethAfter = IERC20(WETH).balanceOf(user1);

        assertGt(amountOut, 0, "Should receive WETH");
        assertEq(wethAfter - wethBefore, amountOut);
        assertGt(amountOut, 1e18, "Should get at least 1 WETH");
        assertLt(amountOut, 10e18, "Should get less than 10 WETH");

        console2.log("Swap: 10000 USDC -> %s WETH", amountOut / 1e18);
    }

    function test_swap_WETH_to_USDC() public {
        uint256 amountIn = 1e18;

        uint256 amountOut = swapPoolZero(user1, WETH, USDC, amountIn);

        assertGt(amountOut, 1000e18, "Should get at least 1000 USDC");
        assertLt(amountOut, 10000e18, "Should get less than 10000 USDC");

        console2.log("Swap: 1 WETH -> %s USDC", amountOut / 1e18);
    }

    function test_swap_WBTC_to_WETH() public {
        uint256 amountIn = 0.1e18;

        uint256 amountOut = swapPoolZero(user1, WBTC, WETH, amountIn);

        assertGt(amountOut, 1e18, "Should get at least 1 WETH");

        console2.log("Swap: 0.1 WBTC -> %s WETH", amountOut / 1e18);
    }

    function test_swap_SOL_to_USDC() public {
        uint256 amountIn = 10e18;

        uint256 amountOut = swapPoolZero(user1, SOL, USDC, amountIn);

        assertGt(amountOut, 500e18, "Should get at least 500 USDC");

        console2.log("Swap: 10 SOL -> %s USDC", amountOut / 1e18);
    }

    function test_swap_roundtrip_USDC_WETH() public {
        uint256 startAmount = 10000 * 1e18;

        // USDC -> WETH
        uint256 wethAmount = swapPoolZero(user1, USDC, WETH, startAmount);
        assertGt(wethAmount, 0);

        // Skip cooldown
        vm.warp(block.timestamp + 20);

        // WETH -> USDC
        uint256 endAmount = swapPoolZero(user1, WETH, USDC, wethAmount);
        assertGt(endAmount, 0);

        // Should lose some to fees but be close
        assertApproxEqRel(endAmount, startAmount, 0.05e18, "Should be within 5% after roundtrip");

        console2.log("Roundtrip: 10000 USDC -> %s WETH -> %s USDC", wethAmount / 1e18, endAmount / 1e18);
        if (endAmount >= startAmount) {
            console2.log("Roundtrip gain: %s%%", (endAmount - startAmount) * 100 / startAmount);
        } else {
            console2.log("Roundtrip loss: %s%%", (startAmount - endAmount) * 100 / startAmount);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SWAP TESTS - POOL STABLE
    // ═══════════════════════════════════════════════════════════════════════════

    function test_stableSwap_USDT_to_USDC() public {
        uint256 amountIn = 1000 * 1e18;

        uint256 amountOut = swapPoolStable(user1, USDT, USDC, amountIn);

        assertGt(amountOut, 0);
        assertApproxEqRel(amountOut, amountIn, 0.002e18, "Should be very close to 1:1");

        console2.log("Stable swap: 1000 USDT -> %s USDC", amountOut / 1e18);
    }

    function test_stableSwap_DAI_to_USDC() public {
        uint256 amountIn = 1000 * 1e18;

        uint256 amountOut = swapPoolStable(user1, DAI, USDC, amountIn);

        assertGt(amountOut, 0);
        assertApproxEqRel(amountOut, amountIn, 0.002e18);

        console2.log("Stable swap: 1000 DAI -> %s USDC", amountOut / 1e18);
    }

    function test_stableSwap_roundtrip() public {
        uint256 startAmount = 10000 * 1e18;

        uint256 usdtAmount = swapPoolStable(user1, USDC, USDT, startAmount);
        vm.warp(block.timestamp + 20);
        uint256 endAmount = swapPoolStable(user1, USDT, USDC, usdtAmount);

        assertApproxEqRel(endAmount, startAmount, 0.001e18, "Should be within 0.1%");

        console2.log("Stable roundtrip loss: %s bps", (startAmount - endAmount) * 10000 / startAmount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPOSIT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_deposit_USDC() public {
        uint256 depositAmount = 50000 * 1e18;

        vm.startPrank(user2);
        USDC.safeApprove(address(poolZero), depositAmount);

        uint256 lpBefore = poolZero.getLPBalance(user2, USDC);
        IPoolV1.DepositResult memory result = poolZero.deposit(USDC, depositAmount);
        uint256 lpAfter = poolZero.getLPBalance(user2, USDC);

        assertGt(result.lpAmount, 0, "Should receive LP tokens");
        assertEq(result.actualDeposit, depositAmount, "Should deposit full amount");
        assertEq(lpAfter - lpBefore, result.lpAmount, "LP balance should increase");

        vm.stopPrank();

        console2.log("Deposit: %s USDC -> %s LP", depositAmount / 1e18, result.lpAmount / 1e18);
    }

    function test_deposit_WETH() public {
        uint256 depositAmount = 5 * 1e18;

        vm.startPrank(user2);
        WETH.safeApprove(address(poolZero), depositAmount);

        IPoolV1.DepositResult memory result = poolZero.deposit(WETH, depositAmount);

        assertGt(result.lpAmount, 0, "Should receive LP tokens");
        assertEq(result.actualDeposit, depositAmount);

        vm.stopPrank();

        console2.log("Deposit: %s WETH -> %s LP", depositAmount / 1e18, result.lpAmount / 1e18);
    }

    function test_deposit_multiple_assets() public {
        vm.startPrank(user2);

        // Deposit USDC
        USDC.safeApprove(address(poolZero), type(uint256).max);
        IPoolV1.DepositResult memory r1 = poolZero.deposit(USDC, 10000 * 1e18);

        // Deposit WETH
        WETH.safeApprove(address(poolZero), type(uint256).max);
        IPoolV1.DepositResult memory r2 = poolZero.deposit(WETH, 2 * 1e18);

        // Deposit WBTC
        WBTC.safeApprove(address(poolZero), type(uint256).max);
        IPoolV1.DepositResult memory r3 = poolZero.deposit(WBTC, 0.5e18);

        assertGt(r1.lpAmount, 0);
        assertGt(r2.lpAmount, 0);
        assertGt(r3.lpAmount, 0);

        vm.stopPrank();

        console2.log("Multi-deposit: USDC=%s LP, WETH=%s LP, WBTC=%s LP",
            r1.lpAmount / 1e18, r2.lpAmount / 1e18, r3.lpAmount / 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // WITHDRAW TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_withdraw_USDC() public {
        // First deposit
        vm.startPrank(user2);
        USDC.safeApprove(address(poolZero), type(uint256).max);
        IPoolV1.DepositResult memory depositResult = poolZero.deposit(USDC, 10000 * 1e18);

        // Skip cooldown
        vm.warp(block.timestamp + 20);

        // Withdraw half
        uint256 lpToWithdraw = depositResult.lpAmount / 2;
        uint256 usdcBefore = IERC20(USDC).balanceOf(user2);

        IPoolV1.WithdrawResult memory withdrawResult = poolZero.withdraw(USDC, lpToWithdraw, 0);

        uint256 usdcAfter = IERC20(USDC).balanceOf(user2);

        assertGt(withdrawResult.amountOut, 0, "Should receive USDC");
        assertEq(withdrawResult.lpBurned, lpToWithdraw, "Should burn correct LP");
        assertEq(usdcAfter - usdcBefore, withdrawResult.amountOut);

        vm.stopPrank();

        console2.log("Withdraw: %s LP -> %s USDC", lpToWithdraw / 1e18, withdrawResult.amountOut / 1e18);
    }

    function test_withdrawTo_cross_asset() public {
        // Test withdrawTo: deposit USDC LP, withdraw as USDT
        vm.startPrank(user2);
        USDC.safeApprove(address(poolZero), type(uint256).max);
        IPoolV1.DepositResult memory depositResult = poolZero.deposit(USDC, 10000 * 1e18);

        vm.warp(block.timestamp + 20);

        uint256 usdtBefore = IERC20(USDT).balanceOf(user2);
        IPoolV1.WithdrawResult memory withdrawResult = poolZero.withdrawTo(USDC, USDT, depositResult.lpAmount, 0);
        uint256 usdtAfter = IERC20(USDT).balanceOf(user2);

        assertGt(withdrawResult.amountOut, 0, "Should receive USDT");
        assertEq(usdtAfter - usdtBefore, withdrawResult.amountOut, "USDT balance should increase");
        // Should be close to deposited amount (stablecoin to stablecoin)
        assertApproxEqRel(withdrawResult.amountOut, 10000 * 1e18, 0.02e18, "Should be ~1:1");

        vm.stopPrank();

        console2.log("WithdrawTo: %s USDC LP -> %s USDT", depositResult.lpAmount / 1e18, withdrawResult.amountOut / 1e18);
    }

    function test_withdraw_full_position() public {
        vm.startPrank(user2);
        USDC.safeApprove(address(poolZero), type(uint256).max);
        IPoolV1.DepositResult memory depositResult = poolZero.deposit(USDC, 10000 * 1e18);

        vm.warp(block.timestamp + 20);

        IPoolV1.WithdrawResult memory withdrawResult = poolZero.withdraw(USDC, depositResult.lpAmount, 0);

        // Should get back close to what was deposited (minus any haircut)
        assertApproxEqRel(withdrawResult.amountOut, 10000 * 1e18, 0.05e18, "Should get ~full amount back");

        // LP balance should be zero
        assertEq(poolZero.getLPBalance(user2, USDC), 0, "LP balance should be zero");

        vm.stopPrank();

        console2.log("Full withdraw: deposited 10000, got back %s", withdrawResult.amountOut / 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COVERAGE RATIO TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_coverage_ratio_healthy() public view {
        uint256 coverageUsdc = poolZero.getCoverageRatio(USDC);
        uint256 coverageWeth = poolZero.getCoverageRatio(WETH);

        // Coverage should be 100% for healthy pools (1e18 = 100%)
        assertGe(coverageUsdc, 0.99e18, "USDC coverage should be healthy");
        assertGe(coverageWeth, 0.99e18, "WETH coverage should be healthy");

        console2.log("Coverage: USDC=%s%%, WETH=%s%%", coverageUsdc * 100 / 1e18, coverageWeth * 100 / 1e18);
    }

    function test_coverage_after_large_swap() public {
        // Large swap might impact coverage
        uint256 coverageBefore = poolZero.getCoverageRatio(USDC);

        // Medium swap: 10k USDC -> WETH (pool only has 10 WETH seeded)
        uint256 amountIn = 10000 * 1e18;
        vm.startPrank(user1);
        USDC.safeApprove(address(poolZero), amountIn);
        IPoolV1.SwapQuote memory quote = poolZero.getSwapQuote(USDC, WETH, amountIn);
        poolZero.swap(USDC, WETH, amountIn, quote.amountOut * 90 / 100, user1);
        vm.stopPrank();

        uint256 coverageAfter = poolZero.getCoverageRatio(USDC);

        // Coverage might decrease slightly for outgoing asset
        console2.log("Coverage before: %s%%, after: %s%%",
            coverageBefore * 100 / 1e18, coverageAfter * 100 / 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_admin_freezeAsset() public {
        vm.startPrank(admin);

        // Freeze WETH
        IAdminV1(address(poolZero)).freezeAsset(WETH);

        vm.stopPrank();

        // Try to swap - should fail
        vm.startPrank(user1);
        USDC.safeApprove(address(poolZero), 1000e18);
        vm.expectRevert();
        poolZero.swap(USDC, WETH, 1000e18, 0, user1);
        vm.stopPrank();

        // Unfreeze
        vm.prank(admin);
        IAdminV1(address(poolZero)).unfreezeAsset(WETH);

        // Should work again
        vm.startPrank(user1);
        uint256 amountOut = poolZero.swap(USDC, WETH, 1000e18, 0, user1);
        assertGt(amountOut, 0);
        vm.stopPrank();

        console2.log("Admin: freeze/unfreeze test passed");
    }

    function test_admin_updateRiskConfig() public {
        // Get current risk config
        IPoolV1.RiskConfig memory currentConfig = poolZero.getRiskConfig(USDC);
        console2.log("Current decayStartRatioBps:", currentConfig.decayStartRatioBps);

        // Request new config with different decay threshold
        uint8[18] memory riskPad;
        IPoolV1.RiskConfig memory newConfig = IPoolV1.RiskConfig({
            decayStartRatioBps: 9500,  // Changed from 9800 to 9500
            coverageFloor: 5000,
            decaySlope: 31709791,
            depthAmplifier: 20000,
            flags: C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT,
            _pad: riskPad
        });

        vm.prank(admin);
        IAdminV1(address(poolZero)).requestUpdateRiskConfig(USDC, newConfig);

        // Warp past timelock
        vm.warp(block.timestamp + C.BASE_TIMELOCK + 1);

        // Execute
        vm.prank(admin);
        IAdminV1(address(poolZero)).executeUpdateRiskConfig(USDC);

        // Verify
        IPoolV1.RiskConfig memory updatedConfig = poolZero.getRiskConfig(USDC);
        assertEq(updatedConfig.decayStartRatioBps, 9500, "Config should be updated");

        console2.log("Admin: risk config updated from %s to %s",
            currentConfig.decayStartRatioBps, updatedConfig.decayStartRatioBps);
    }

    function test_admin_updateFeeParams() public {
        // Request new fee params
        uint8[29] memory feePad;
        IPoolV1.FeeParams memory newFees = IPoolV1.FeeParams({
            protoShare: 30,      // Changed from 25 to 30
            flashFeeBps: 10,     // Changed from 5 to 10
            _pad: feePad
        });

        vm.prank(admin);
        IAdminV1(address(poolZero)).requestUpdateFeeParams(newFees);

        vm.warp(block.timestamp + C.LOW_TIMELOCK + 1);

        vm.prank(admin);
        IAdminV1(address(poolZero)).executeUpdateFeeParams();

        console2.log("Admin: fee params updated");
    }

    function test_admin_collectProtocolFees() public {
        // Do some swaps to generate fees
        vm.startPrank(user1);
        USDC.safeApprove(address(poolZero), type(uint256).max);
        for (uint i = 0; i < 5; i++) {
            poolZero.swap(USDC, WETH, 5000e18, 0, user1);
            vm.warp(block.timestamp + 10);
            WETH.safeApprove(address(poolZero), type(uint256).max);
            poolZero.swap(WETH, USDC, 1e18, 0, user1);
            vm.warp(block.timestamp + 10);
        }
        vm.stopPrank();

        // Check accumulated fees
        uint256 feesBefore = poolZero.getProtocolFees(USDC);
        console2.log("Accumulated protocol fees: %s USDC", feesBefore / 1e18);

        if (feesBefore > 0) {
            // Set treasury first (uses HIGH_TIMELOCK = 3 days)
            address treasury = makeAddr("treasury");
            vm.prank(admin);
            IAdminV1(address(poolZero)).requestTreasuryUpdate(treasury);
            vm.warp(block.timestamp + C.HIGH_TIMELOCK + 1);
            vm.prank(admin);
            IAdminV1(address(poolZero)).executeTreasuryUpdate();

            // Collect fees
            uint256 treasuryBefore = IERC20(USDC).balanceOf(treasury);
            vm.prank(treasury);
            IAdminV1(address(poolZero)).collectProtocolFees(USDC, treasury);
            uint256 treasuryAfter = IERC20(USDC).balanceOf(treasury);

            assertEq(treasuryAfter - treasuryBefore, feesBefore, "Treasury should receive fees");
            console2.log("Admin: collected %s USDC in fees", feesBefore / 1e18);
        }
    }

    function test_admin_cancelTimelock() public {
        // Request a treasury update (global operation - supported by cancelTimelock)
        address newTreasury = address(0xBEEF);

        vm.prank(admin);
        IAdminV1(address(poolZero)).requestTreasuryUpdate(newTreasury);

        // Cancel before execution
        vm.prank(admin);
        IAdminV1(address(poolZero)).cancelTimelock(uint8(IPoolV1.OpType.UPDATE_TREASURY));

        // Try to execute - should fail (uses HIGH_TIMELOCK = 3 days)
        vm.warp(block.timestamp + C.HIGH_TIMELOCK + 1);
        vm.expectRevert();
        vm.prank(admin);
        IAdminV1(address(poolZero)).executeTreasuryUpdate();

        console2.log("Admin: timelock cancel test passed");
    }

    function test_admin_only_owner() public {
        vm.prank(user1);
        vm.expectRevert();
        IAdminV1(address(poolZero)).freezeAsset(USDC);

        console2.log("Admin: unauthorized access blocked");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // QUOTE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getSwapQuote() public {
        uint256 amountIn = 1000e18;

        IPoolV1.SwapQuote memory quote = poolZero.getSwapQuote(USDC, WETH, amountIn);

        assertGt(quote.amountOut, 0, "Quote should have output");
        assertEq(quote.amountIn, amountIn, "Input should match");
        assertGt(quote.spreadBps, 0, "Should have spread");

        console2.log("Quote: %s USDC -> %s WETH", amountIn / 1e18, quote.amountOut / 1e18);
        console2.log("Spread: %s bps, Proto fee: %s, LP fee: %s",
            quote.spreadBps, quote.protoFee / 1e18, quote.lpFee / 1e18);
    }

    function test_getMidPrice() public {
        uint256 usdcPrice = poolZero.getMidPrice(USDC);
        uint256 wethPrice = poolZero.getMidPrice(WETH);
        uint256 wbtcPrice = poolZero.getMidPrice(WBTC);

        // USDC should be ~1 (in base token terms, which is also USDC)
        assertApproxEqRel(usdcPrice, 1e18, 0.01e18, "USDC price should be ~1");

        // WETH should be ~3000-4000 USDC
        assertGt(wethPrice, 1000e18, "WETH price too low");
        assertLt(wethPrice, 10000e18, "WETH price too high");

        // WBTC should be ~90000-100000 USDC
        assertGt(wbtcPrice, 50000e18, "WBTC price too low");
        assertLt(wbtcPrice, 200000e18, "WBTC price too high");

        console2.log("Prices: USDC=%s, WETH=%s, WBTC=%s",
            usdcPrice / 1e18, wethPrice / 1e18, wbtcPrice / 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SLIPPAGE PROTECTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_swap_reverts_on_excessive_slippage() public {
        uint256 amountIn = 1000e18;

        IPoolV1.SwapQuote memory quote = poolZero.getSwapQuote(USDC, WETH, amountIn);

        // Set minOut higher than expected output
        uint256 unrealisticMinOut = quote.amountOut * 2;

        vm.startPrank(user1);
        USDC.safeApprove(address(poolZero), amountIn);

        vm.expectRevert();
        poolZero.swap(USDC, WETH, amountIn, unrealisticMinOut, user1);

        vm.stopPrank();

        console2.log("Slippage protection: excessive slippage blocked");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function swapPoolZero(address user, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        vm.startPrank(user);

        tokenIn.safeApprove(address(poolZero), amountIn);

        IPoolV1.SwapQuote memory quote = poolZero.getSwapQuote(tokenIn, tokenOut, amountIn);
        uint256 minOut = (quote.amountOut * 95) / 100;

        amountOut = poolZero.swap(tokenIn, tokenOut, amountIn, minOut, user);

        vm.stopPrank();
    }

    function swapPoolStable(address user, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        vm.startPrank(user);

        tokenIn.safeApprove(address(poolStable), amountIn);

        IPoolV1.SwapQuote memory quote = poolStable.getSwapQuote(tokenIn, tokenOut, amountIn);
        uint256 minOut = (quote.amountOut * 98) / 100;

        amountOut = poolStable.swap(tokenIn, tokenOut, amountIn, minOut, user);

        vm.stopPrank();
    }

    function fundTestUsers() internal {
        console2.log("\n=== Funding Test Users ===");

        address[4] memory users = [user1, user2, user3, lp1];

        for (uint256 i = 0; i < users.length; i++) {
            // Pool Zero tokens
            deal(USDC, users[i], 1_000_000 * 1e18);
            deal(USDT, users[i], 1_000_000 * 1e18);
            deal(WETH, users[i], 100 * 1e18);
            deal(WBTC, users[i], 10 * 1e18);
            deal(WBNB, users[i], 500 * 1e18);
            deal(SOL, users[i], 1000 * 1e18);
            deal(ZEC, users[i], 500 * 1e18);
            deal(PAXG, users[i], 100 * 1e18);

            // Pool Stable tokens
            deal(DAI, users[i], 1_000_000 * 1e18);
            deal(TUSD, users[i], 1_000_000 * 1e18);
            deal(FDUSD, users[i], 1_000_000 * 1e18);
            deal(USDD, users[i], 1_000_000 * 1e18);
        }

        console2.log("Funded 4 test users");
    }

    function seedPoolZero() internal {
        console2.log("\n=== Seeding Pool Zero ===");

        vm.startPrank(lp1);

        // Deposit stablecoins
        USDC.safeApprove(address(poolZero), type(uint256).max);
        poolZero.deposit(USDC, 100_000 * 1e18);

        USDT.safeApprove(address(poolZero), type(uint256).max);
        poolZero.deposit(USDT, 100_000 * 1e18);

        // Deposit volatiles
        WETH.safeApprove(address(poolZero), type(uint256).max);
        poolZero.deposit(WETH, 10 * 1e18);

        WBTC.safeApprove(address(poolZero), type(uint256).max);
        poolZero.deposit(WBTC, 1 * 1e18);

        WBNB.safeApprove(address(poolZero), type(uint256).max);
        poolZero.deposit(WBNB, 50 * 1e18);

        SOL.safeApprove(address(poolZero), type(uint256).max);
        poolZero.deposit(SOL, 100 * 1e18);

        ZEC.safeApprove(address(poolZero), type(uint256).max);
        poolZero.deposit(ZEC, 100 * 1e18);

        PAXG.safeApprove(address(poolZero), type(uint256).max);
        poolZero.deposit(PAXG, 10 * 1e18);

        vm.stopPrank();

        console2.log("Pool Zero seeded with liquidity");
    }

    function seedPoolStable() internal {
        console2.log("\n=== Seeding Pool Stable ===");

        vm.startPrank(lp1);

        USDC.safeApprove(address(poolStable), type(uint256).max);
        poolStable.deposit(USDC, 100_000 * 1e18);

        USDT.safeApprove(address(poolStable), type(uint256).max);
        poolStable.deposit(USDT, 100_000 * 1e18);

        DAI.safeApprove(address(poolStable), type(uint256).max);
        poolStable.deposit(DAI, 100_000 * 1e18);

        TUSD.safeApprove(address(poolStable), type(uint256).max);
        poolStable.deposit(TUSD, 50_000 * 1e18);

        FDUSD.safeApprove(address(poolStable), type(uint256).max);
        poolStable.deposit(FDUSD, 50_000 * 1e18);

        USDD.safeApprove(address(poolStable), type(uint256).max);
        poolStable.deposit(USDD, 50_000 * 1e18);

        vm.stopPrank();

        console2.log("Pool Stable seeded with liquidity");
    }
}

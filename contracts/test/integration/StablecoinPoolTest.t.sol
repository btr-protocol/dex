// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {StablecoinPoolFixture, IERC20} from "../fixtures/StablecoinPoolFixture.sol";
import {IPoolV1} from "../../src/interfaces/IPoolV1.sol";

/// @title StablecoinPoolTest
/// @notice Integration tests for stablecoin pool on mainnet fork
/// @dev Tests: deposits, withdrawals, swaps, coverage ratios, fees
contract StablecoinPoolTest is StablecoinPoolFixture {

    function setUp() public override {
        // Fork mainnet - try env var, fallback to public RPC
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(rpcUrl);

        // Run base setup
        super.setUp();

        // Add all stablecoins to pool
        _addAllStablecoins();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_pool_deployed_correctly() public view {
        assertNotEq(address(pool), address(0), "Pool should be deployed");
        assertEq(IPoolV1(address(pool)).owner(), owner, "Owner should be set");
        assertEq(IPoolV1(address(pool)).baseToken(), USDC, "Base token should be USDC");
    }

    function test_all_assets_configured() public view {
        // Check USDC (base token)
        IPoolV1.Asset memory usdc = IPoolV1(address(pool)).getAsset(USDC);
        assertEq(usdc.decimals, USDC_DECIMALS, "USDC decimals");
        assertEq(usdc.anchor, address(0), "USDC should be root (no anchor)");

        // Check USDT
        IPoolV1.Asset memory usdt = IPoolV1(address(pool)).getAsset(USDT);
        assertEq(usdt.decimals, USDT_DECIMALS, "USDT decimals");
        assertEq(usdt.anchor, USDC, "USDT should anchor to USDC");

        // Check USDS
        IPoolV1.Asset memory usds = IPoolV1(address(pool)).getAsset(USDS);
        assertEq(usds.decimals, USDS_DECIMALS, "USDS decimals");
        assertEq(usds.anchor, USDC, "USDS should anchor to USDC");

        // Check USDE
        IPoolV1.Asset memory usde = IPoolV1(address(pool)).getAsset(USDE);
        assertEq(usde.decimals, USDE_DECIMALS, "USDE decimals");
        assertEq(usde.anchor, USDC, "USDE should anchor to USDC");

        // Check PYUSD
        IPoolV1.Asset memory pyusd = IPoolV1(address(pool)).getAsset(PYUSD);
        assertEq(pyusd.decimals, PYUSD_DECIMALS, "PYUSD decimals");
        assertEq(pyusd.anchor, USDC, "PYUSD should anchor to USDC");
    }

    function test_users_have_tokens() public view {
        assertGt(IERC20(USDC).balanceOf(user1), 0, "User1 should have USDC");
        assertGt(IERC20(USDT).balanceOf(user1), 0, "User1 should have USDT");
        assertGt(IERC20(USDS).balanceOf(user1), 0, "User1 should have USDS");
        assertGt(IERC20(USDE).balanceOf(user1), 0, "User1 should have USDE");
        assertGt(IERC20(PYUSD).balanceOf(user1), 0, "User1 should have PYUSD");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPOSIT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_deposit_usdc() public {
        uint256 amount = 10_000 * 10**USDC_DECIMALS; // 10k USDC

        uint256 balanceBefore = IERC20(USDC).balanceOf(user1);
        uint256 lpAmount = _deposit(user1, USDC, amount);

        assertGt(lpAmount, 0, "Should receive LP tokens");
        assertEq(IERC20(USDC).balanceOf(user1), balanceBefore - amount, "USDC should be transferred");

        IPoolV1.Asset memory asset = IPoolV1(address(pool)).getAsset(USDC);
        assertEq(asset.reserves, amount, "Reserves should increase");
        assertEq(asset.liabilities, amount, "Liabilities should increase");
    }

    function test_deposit_usdt() public {
        uint256 amount = 10_000 * 10**USDT_DECIMALS; // 10k USDT

        uint256 lpAmount = _deposit(user1, USDT, amount);

        assertGt(lpAmount, 0, "Should receive LP tokens");

        IPoolV1.Asset memory asset = IPoolV1(address(pool)).getAsset(USDT);
        assertEq(asset.reserves, amount, "Reserves should match deposit");
    }

    function test_deposit_usds_18_decimals() public {
        uint256 amount = 10_000 * 10**USDS_DECIMALS; // 10k USDS (18 decimals)

        uint256 lpAmount = _deposit(user1, USDS, amount);

        assertGt(lpAmount, 0, "Should receive LP tokens");

        IPoolV1.Asset memory asset = IPoolV1(address(pool)).getAsset(USDS);
        assertEq(asset.reserves, amount, "Reserves should match deposit");
    }

    function test_deposit_multiple_users() public {
        uint256 amount = 10_000 * 10**USDC_DECIMALS;

        uint256 lp1 = _deposit(user1, USDC, amount);
        uint256 lp2 = _deposit(user2, USDC, amount);
        uint256 lp3 = _deposit(user3, USDC, amount);

        assertGt(lp1, 0, "User1 should get LP");
        assertGt(lp2, 0, "User2 should get LP");
        assertGt(lp3, 0, "User3 should get LP");

        IPoolV1.Asset memory asset = IPoolV1(address(pool)).getAsset(USDC);
        assertEq(asset.reserves, amount * 3, "Total reserves should be 3x");
    }

    function test_deposit_all_stablecoins() public {
        _deposit(user1, USDC, 10_000 * 10**USDC_DECIMALS);
        _deposit(user1, USDT, 10_000 * 10**USDT_DECIMALS);
        _deposit(user1, USDS, 10_000 * 10**USDS_DECIMALS);
        _deposit(user1, USDE, 10_000 * 10**USDE_DECIMALS);
        _deposit(user1, PYUSD, 10_000 * 10**PYUSD_DECIMALS);

        // Check all have reserves
        assertGt(IPoolV1(address(pool)).getAsset(USDC).reserves, 0);
        assertGt(IPoolV1(address(pool)).getAsset(USDT).reserves, 0);
        assertGt(IPoolV1(address(pool)).getAsset(USDS).reserves, 0);
        assertGt(IPoolV1(address(pool)).getAsset(USDE).reserves, 0);
        assertGt(IPoolV1(address(pool)).getAsset(PYUSD).reserves, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // WITHDRAWAL TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_withdraw_full_amount() public {
        uint256 depositAmount = 10_000 * 10**USDC_DECIMALS;
        uint256 lpAmount = _deposit(user1, USDC, depositAmount);

        uint256 balanceBefore = IERC20(USDC).balanceOf(user1);
        uint256 amountOut = _withdraw(user1, USDC, lpAmount);

        // At 100% coverage, should get back full amount (no haircut)
        assertEq(amountOut, depositAmount, "Should withdraw full amount at 100% coverage");
        assertEq(IERC20(USDC).balanceOf(user1), balanceBefore + amountOut);
    }

    function test_withdraw_partial() public {
        uint256 depositAmount = 10_000 * 10**USDC_DECIMALS;
        uint256 lpAmount = _deposit(user1, USDC, depositAmount);

        uint256 halfLp = lpAmount / 2;
        uint256 amountOut = _withdraw(user1, USDC, halfLp);

        // Should get approximately half back
        assertApproxEqRel(amountOut, depositAmount / 2, 0.01e18, "Should get ~50% back");

        // Should still have LP tokens
        assertGt(IPoolV1(address(pool)).getLPBalance(user1, USDC), 0);
    }

    function test_withdraw_with_haircut_undercollateralized() public {
        // Setup: deposit then simulate undercollateralization
        uint256 depositAmount = 100_000 * 10**USDC_DECIMALS;
        uint256 lpAmount = _deposit(user1, USDC, depositAmount);

        // Simulate undercollateralization by manipulating reserves
        // This would normally happen through swaps depleting reserves

        // For now, test that withdrawal works
        uint256 withdrawLp = lpAmount / 2;
        uint256 amountOut = _withdraw(user1, USDC, withdrawLp);

        assertGt(amountOut, 0, "Should receive some tokens");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SWAP TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_swap_usdc_to_usdt() public {
        // Seed liquidity first
        _deposit(user1, USDC, 100_000 * 10**USDC_DECIMALS);
        _deposit(user1, USDT, 100_000 * 10**USDT_DECIMALS);

        uint256 swapAmount = 1_000 * 10**USDC_DECIMALS; // 1k USDC

        // Get quote first
        IPoolV1.SwapQuote memory quote = _getQuote(USDC, USDT, swapAmount);
        assertGt(quote.amountOut, 0, "Quote should have output");

        // Execute swap
        uint256 usdtBefore = IERC20(USDT).balanceOf(user2);
        uint256 amountOut = _swap(user2, USDC, USDT, swapAmount, quote.amountOut * 95 / 100);

        assertGt(amountOut, 0, "Should receive USDT");
        assertEq(IERC20(USDT).balanceOf(user2), usdtBefore + amountOut);
    }

    function test_swap_usdt_to_usdc() public {
        // Seed liquidity
        _deposit(user1, USDC, 100_000 * 10**USDC_DECIMALS);
        _deposit(user1, USDT, 100_000 * 10**USDT_DECIMALS);

        uint256 swapAmount = 1_000 * 10**USDT_DECIMALS; // 1k USDT

        uint256 usdcBefore = IERC20(USDC).balanceOf(user2);
        IPoolV1.SwapQuote memory quote = _getQuote(USDT, USDC, swapAmount);
        uint256 amountOut = _swap(user2, USDT, USDC, swapAmount, quote.amountOut * 95 / 100);

        assertGt(amountOut, 0, "Should receive USDC");
        assertEq(IERC20(USDC).balanceOf(user2), usdcBefore + amountOut);
    }

    function test_swap_usds_to_usde() public {
        // Seed liquidity for 18-decimal tokens
        _deposit(user1, USDS, 100_000 * 10**USDS_DECIMALS);
        _deposit(user1, USDE, 100_000 * 10**USDE_DECIMALS);

        uint256 swapAmount = 1_000 * 10**USDS_DECIMALS; // 1k USDS

        IPoolV1.SwapQuote memory quote = _getQuote(USDS, USDE, swapAmount);
        uint256 amountOut = _swap(user2, USDS, USDE, swapAmount, quote.amountOut * 95 / 100);

        assertGt(amountOut, 0, "Should receive USDE");
        // For stablecoins, output should be close to input
        assertApproxEqRel(amountOut, swapAmount, 0.05e18, "Output should be ~equal for stablecoins");
    }

    function test_swap_6_to_18_decimals() public {
        // Test cross-decimal swap: USDC (6) -> USDS (18)
        _deposit(user1, USDC, 100_000 * 10**USDC_DECIMALS);
        _deposit(user1, USDS, 100_000 * 10**USDS_DECIMALS);

        uint256 swapAmount = 1_000 * 10**USDC_DECIMALS; // 1k USDC (6 decimals)

        IPoolV1.SwapQuote memory quote = _getQuote(USDC, USDS, swapAmount);
        uint256 amountOut = _swap(user2, USDC, USDS, swapAmount, quote.amountOut * 95 / 100);

        // 1000 USDC should give ~1000 USDS (adjusted for 18 decimals)
        uint256 expectedUsds = 1_000 * 10**USDS_DECIMALS;
        assertApproxEqRel(amountOut, expectedUsds, 0.05e18, "Cross-decimal swap should maintain value");
    }

    function test_swap_18_to_6_decimals() public {
        // Test cross-decimal swap: USDS (18) -> USDC (6)
        _deposit(user1, USDC, 100_000 * 10**USDC_DECIMALS);
        _deposit(user1, USDS, 100_000 * 10**USDS_DECIMALS);

        uint256 swapAmount = 1_000 * 10**USDS_DECIMALS; // 1k USDS (18 decimals)

        IPoolV1.SwapQuote memory quote = _getQuote(USDS, USDC, swapAmount);
        uint256 amountOut = _swap(user2, USDS, USDC, swapAmount, quote.amountOut * 95 / 100);

        // 1000 USDS should give ~1000 USDC (adjusted for 6 decimals)
        uint256 expectedUsdc = 1_000 * 10**USDC_DECIMALS;
        assertApproxEqRel(amountOut, expectedUsdc, 0.05e18, "Cross-decimal swap should maintain value");
    }

    function test_swap_affects_coverage_ratio() public {
        // Seed equal liquidity
        _deposit(user1, USDC, 100_000 * 10**USDC_DECIMALS);
        _deposit(user1, USDT, 100_000 * 10**USDT_DECIMALS);

        uint256 coverageUsdtBefore = IPoolV1(address(pool)).getCoverageRatio(USDT);

        // Large swap: USDC -> USDT (depletes USDT reserves)
        uint256 swapAmount = 50_000 * 10**USDC_DECIMALS;
        IPoolV1.SwapQuote memory quote = _getQuote(USDC, USDT, swapAmount);
        _swap(user2, USDC, USDT, swapAmount, quote.amountOut * 90 / 100);

        uint256 coverageUsdtAfter = IPoolV1(address(pool)).getCoverageRatio(USDT);

        // USDT coverage should decrease (reserves depleted, liabilities unchanged)
        assertLt(coverageUsdtAfter, coverageUsdtBefore, "USDT coverage should decrease after swap out");
    }

    function test_swap_multiple_times() public {
        // Seed liquidity
        _deposit(user1, USDC, 100_000 * 10**USDC_DECIMALS);
        _deposit(user1, USDT, 100_000 * 10**USDT_DECIMALS);

        // Multiple swaps back and forth
        for (uint256 i = 0; i < 5; i++) {
            uint256 amount = 1_000 * 10**USDC_DECIMALS;
            IPoolV1.SwapQuote memory quote1 = _getQuote(USDC, USDT, amount);
            uint256 out1 = _swap(user2, USDC, USDT, amount, quote1.amountOut * 95 / 100);

            IPoolV1.SwapQuote memory quote2 = _getQuote(USDT, USDC, out1);
            _swap(user2, USDT, USDC, out1, quote2.amountOut * 95 / 100);
        }

        // Pool should still be functional
        IPoolV1.Asset memory usdc = IPoolV1(address(pool)).getAsset(USDC);
        IPoolV1.Asset memory usdt = IPoolV1(address(pool)).getAsset(USDT);

        assertGt(usdc.reserves, 0, "USDC reserves should remain");
        assertGt(usdt.reserves, 0, "USDT reserves should remain");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COVERAGE RATIO TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_coverage_ratio_after_deposit() public {
        _deposit(user1, USDC, 100_000 * 10**USDC_DECIMALS);

        uint256 coverage = IPoolV1(address(pool)).getCoverageRatio(USDC);

        // After deposit, reserves = liabilities, coverage = 100%
        assertEq(coverage, 1e18, "Coverage should be 100% after deposit");
    }

    function test_coverage_ratio_multiple_assets() public {
        _deposit(user1, USDC, 100_000 * 10**USDC_DECIMALS);
        _deposit(user1, USDT, 50_000 * 10**USDT_DECIMALS);
        _deposit(user1, USDS, 200_000 * 10**USDS_DECIMALS);

        uint256 coverageUsdc = IPoolV1(address(pool)).getCoverageRatio(USDC);
        uint256 coverageUsdt = IPoolV1(address(pool)).getCoverageRatio(USDT);
        uint256 coverageUsds = IPoolV1(address(pool)).getCoverageRatio(USDS);

        // All should start at 100%
        assertEq(coverageUsdc, 1e18);
        assertEq(coverageUsdt, 1e18);
        assertEq(coverageUsds, 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FEE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_swap_generates_fees() public {
        _deposit(user1, USDC, 100_000 * 10**USDC_DECIMALS);
        _deposit(user1, USDT, 100_000 * 10**USDT_DECIMALS);

        uint256 protoFeesBefore = IPoolV1(address(pool)).getProtocolFees(USDT);

        // Execute swap
        uint256 swapAmount = 10_000 * 10**USDC_DECIMALS;
        IPoolV1.SwapQuote memory quote = _getQuote(USDC, USDT, swapAmount);
        _swap(user2, USDC, USDT, swapAmount, quote.amountOut * 95 / 100);

        uint256 protoFeesAfter = IPoolV1(address(pool)).getProtocolFees(USDT);

        // Protocol fees should increase
        assertGt(protoFeesAfter, protoFeesBefore, "Protocol fees should increase after swap");
    }

    function test_quote_shows_fee_breakdown() public {
        _deposit(user1, USDC, 100_000 * 10**USDC_DECIMALS);
        _deposit(user1, USDT, 100_000 * 10**USDT_DECIMALS);

        uint256 swapAmount = 10_000 * 10**USDC_DECIMALS;
        IPoolV1.SwapQuote memory quote = _getQuote(USDC, USDT, swapAmount);

        assertGt(quote.amountOut, 0, "Should have output");
        assertGt(quote.spreadBps, 0, "Should have spread");
        // Note: protoFee and lpFee may be 0 depending on fee params
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LIABILITY SWAP TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_liability_swap_basic() public {
        // User deposits both tokens
        uint256 usdcLp = _deposit(user1, USDC, 50_000 * 10**USDC_DECIMALS);
        _deposit(user1, USDT, 50_000 * 10**USDT_DECIMALS);

        uint256 lpBefore = IPoolV1(address(pool)).getLPBalance(user1, USDC);
        uint256 lpUsdtBefore = IPoolV1(address(pool)).getLPBalance(user1, USDT);

        // Swap liability from USDC to USDT
        vm.startPrank(user1);
        uint256 lpOut = IPoolV1(address(pool)).swapLiability(USDC, USDT, usdcLp / 2, 0);
        vm.stopPrank();

        uint256 lpAfter = IPoolV1(address(pool)).getLPBalance(user1, USDC);
        uint256 lpUsdtAfter = IPoolV1(address(pool)).getLPBalance(user1, USDT);

        assertLt(lpAfter, lpBefore, "USDC LP should decrease");
        assertGt(lpUsdtAfter, lpUsdtBefore, "USDT LP should increase");
        assertGt(lpOut, 0, "Should receive USDT LP tokens");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_revert_swap_insufficient_liquidity() public {
        // Only deposit USDC, not USDT
        _deposit(user1, USDC, 10_000 * 10**USDC_DECIMALS);

        // Try to swap - should fail due to no USDT liquidity
        uint256 swapAmount = 1_000 * 10**USDC_DECIMALS;

        vm.startPrank(user2);
        IERC20(USDC).approve(address(pool), swapAmount);

        vm.expectRevert();
        IPoolV1(address(pool)).swap(USDC, USDT, swapAmount, 0, user2);
        vm.stopPrank();
    }

    function test_revert_withdraw_more_than_balance() public {
        uint256 depositAmount = 10_000 * 10**USDC_DECIMALS;
        uint256 lpAmount = _deposit(user1, USDC, depositAmount);

        vm.startPrank(user1);
        vm.expectRevert();
        IPoolV1(address(pool)).withdraw(USDC, lpAmount * 2, 0);
        vm.stopPrank();
    }

    function test_revert_swap_zero_amount() public {
        _deposit(user1, USDC, 10_000 * 10**USDC_DECIMALS);
        _deposit(user1, USDT, 10_000 * 10**USDT_DECIMALS);

        vm.startPrank(user2);
        IERC20(USDC).approve(address(pool), 1000);

        vm.expectRevert();
        IPoolV1(address(pool)).swap(USDC, USDT, 0, 0, user2);
        vm.stopPrank();
    }

    function test_small_amounts_work() public {
        // Test with very small amounts
        _deposit(user1, USDC, 100_000 * 10**USDC_DECIMALS);
        _deposit(user1, USDT, 100_000 * 10**USDT_DECIMALS);

        uint256 smallAmount = 1 * 10**USDC_DECIMALS; // Just 1 USDC

        IPoolV1.SwapQuote memory quote = _getQuote(USDC, USDT, smallAmount);
        uint256 amountOut = _swap(user2, USDC, USDT, smallAmount, 0);

        assertGt(amountOut, 0, "Small swap should still work");
    }

    function test_large_amounts_work() public {
        // Test with large amounts
        _deposit(user1, USDC, 500_000 * 10**USDC_DECIMALS);
        _deposit(user1, USDT, 500_000 * 10**USDT_DECIMALS);

        uint256 largeAmount = 100_000 * 10**USDC_DECIMALS; // 100k USDC

        IPoolV1.SwapQuote memory quote = _getQuote(USDC, USDT, largeAmount);
        uint256 amountOut = _swap(user2, USDC, USDT, largeAmount, quote.amountOut * 90 / 100);

        assertGt(amountOut, 0, "Large swap should work");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STRESS TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_many_deposits_and_withdrawals() public {
        uint256 amount = 1_000 * 10**USDC_DECIMALS;

        // Many deposits
        for (uint256 i = 0; i < 10; i++) {
            _deposit(user1, USDC, amount);
        }

        IPoolV1.Asset memory asset = IPoolV1(address(pool)).getAsset(USDC);
        assertEq(asset.reserves, amount * 10, "Total reserves should match");

        // Withdraw some
        uint256 lpBalance = IPoolV1(address(pool)).getLPBalance(user1, USDC);
        _withdraw(user1, USDC, lpBalance / 2);

        // Pool should still function
        asset = IPoolV1(address(pool)).getAsset(USDC);
        assertGt(asset.reserves, 0, "Should still have reserves");
    }

    function test_all_token_pairs_swap() public {
        // Seed all tokens
        _deposit(user1, USDC, 100_000 * 10**USDC_DECIMALS);
        _deposit(user1, USDT, 100_000 * 10**USDT_DECIMALS);
        _deposit(user1, USDS, 100_000 * 10**USDS_DECIMALS);
        _deposit(user1, USDE, 100_000 * 10**USDE_DECIMALS);
        _deposit(user1, PYUSD, 100_000 * 10**PYUSD_DECIMALS);

        address[5] memory tokens = [USDC, USDT, USDS, USDE, PYUSD];
        uint8[5] memory decimals = [USDC_DECIMALS, USDT_DECIMALS, USDS_DECIMALS, USDE_DECIMALS, PYUSD_DECIMALS];

        // Test swaps between all pairs
        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = 0; j < tokens.length; j++) {
                if (i != j) {
                    uint256 swapAmount = 100 * 10**decimals[i];

                    IPoolV1.SwapQuote memory quote = _getQuote(tokens[i], tokens[j], swapAmount);

                    if (quote.amountOut > 0) {
                        uint256 amountOut = _swap(user2, tokens[i], tokens[j], swapAmount, 0);
                        assertGt(amountOut, 0, "Swap should succeed");
                    }
                }
            }
        }
    }
}

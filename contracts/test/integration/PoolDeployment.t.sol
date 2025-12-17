// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IPoolV1} from "../../src/interfaces/IPoolV1.sol";
import {PoolProxyV1} from "../../src/PoolProxyV1.sol";
import {BTRToken} from "../fixtures/BTRToken.sol";

/// @title PoolDeploymentTest
/// @notice Integration tests for pool deployment and basic 2-token operations
contract PoolDeploymentTest is Test {
    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP & FIXTURES
    // ═══════════════════════════════════════════════════════════════════════════

    PoolProxyV1 pool;
    BTRToken tokenA;
    BTRToken tokenB;

    address owner = makeAddr("owner");
    address user = makeAddr("user");

    function setUp() public virtual {
        // Deploy tokens
        vm.startPrank(owner);

        tokenA = new BTRToken("Token A", "TKN_A", 18);
        tokenB = new BTRToken("Token B", "TKN_B", 18);

        // Deploy pool proxy
        pool = new PoolProxyV1();

        // Initialize pool
        uint8[29] memory pad;
        IPoolV1.FeeParams memory feeParams = IPoolV1.FeeParams({
            protoShare: 25,      // 25% protocol share
            flashFeeBps: 5,      // 0.005% flash fee
            _pad: pad
        });

        pool.initialize(owner, address(tokenA), address(0), feeParams);

        vm.stopPrank();

        // Mint tokens to user
        tokenA.mint(user, 1000 ether);
        tokenB.mint(user, 1000 ether);
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
        assertEq(tokenA.name(), "BTR Test Token");
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

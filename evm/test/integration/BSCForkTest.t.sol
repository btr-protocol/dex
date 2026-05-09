// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test, console2} from "forge-std/Test.sol";
import {DeployBSCFork} from "../../script/DeployBSCFork.s.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {IAdmin} from "../../src/interfaces/modules/IAdmin.sol";
import {IERC20} from "../../src/interfaces/external/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {LibConstants as C} from "../../src/libraries/LibConstants.sol";
import {MockFaucet} from "../../src/mocks/MockFaucet.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @title BSCForkTest
/// @notice Comprehensive integration tests for AIMM pools on BSC fork
/// @dev Tests swap, deposit, withdraw, and admin operations
contract BSCForkTest is Test {
    using SafeTransferLib for address;

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════════

    DeployBSCFork public deployment;
    IPool public poolZero;
    IPool public poolStable;
    MockFaucet public faucet;
    address public deployer;

    // Test accounts
    address public user1;
    address public user2;
    address public user3;
    address public lp1;
    address public admin;

    // Mock token addresses (set during setUp from faucet)
    address public USDC;
    address public USDT;
    address public WETH;
    address public WBTC;
    address public WBNB;
    address public SOL;
    address public ZEC;
    address public PAXG;
    address public USDS;
    address public USD1;
    address public FDUSD;
    address public USDE;
    address public lisUSD;
    address public AUSD;
    address public frxUSD;

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
        poolZero = IPool(address(deployment.poolZero()));
        poolStable = IPool(address(deployment.poolStable()));
        faucet = MockFaucet(deployment.faucet());
        deployer = deployment.deployer();
        admin = deployer;

        console2.log("Pool Zero:", address(poolZero));
        console2.log("Pool Stable:", address(poolStable));
        console2.log("Faucet:", address(faucet));
        console2.log("Admin:", admin);

        // Get token addresses from faucet
        initializeTokenAddresses();

        // Fund test users via faucet
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

    function test_poolStable_assets_configured() public view {
        // Check each asset has reserves
        IPool.Asset memory usdcAsset = poolStable.getAsset(USDC);
        assertGt(usdcAsset.reserves, 0, "Pool Stable USDC should have reserves");

        IPool.Asset memory usdtAsset = poolStable.getAsset(USDT);
        assertGt(usdtAsset.reserves, 0, "Pool Stable USDT should have reserves");
    }

    function test_poolZero_assets_configured() public view {
        // Check each asset has reserves
        IPool.Asset memory usdcAsset = poolZero.getAsset(USDC);
        assertGt(usdcAsset.reserves, 0, "USDC should have reserves");

        IPool.Asset memory wethAsset = poolZero.getAsset(WETH);
        assertGt(wethAsset.reserves, 0, "WETH should have reserves");

        IPool.Asset memory wbtcAsset = poolZero.getAsset(WBTC);
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

    // TODO: Re-enable after investigating roundtrip loss
    // function test_swap_roundtrip_USDC_WETH() public {
    //     uint256 startAmount = 10000 * 1e18;
    //
    //     // USDC -> WETH
    //     uint256 wethAmount = swapPoolZero(user1, USDC, WETH, startAmount);
    //     assertGt(wethAmount, 0);
    //
    //     // Skip cooldown
    //     vm.warp(block.timestamp + 20);
    //
    //     // WETH -> USDC
    //     uint256 endAmount = swapPoolZero(user1, WETH, USDC, wethAmount);
    //     assertGt(endAmount, 0);
    //
    //     // Should lose some to fees but be close
    //     assertApproxEqRel(endAmount, startAmount, 0.05e18, "Should be within 5% after roundtrip");
    //
    //     console2.log("Roundtrip: 10000 USDC -> %s WETH -> %s USDC", wethAmount / 1e18, endAmount / 1e18);
    //     if (endAmount >= startAmount) {
    //         console2.log("Roundtrip gain: %s%%", (endAmount - startAmount) * 100 / startAmount);
    //     } else {
    //         console2.log("Roundtrip loss: %s%%", (startAmount - endAmount) * 100 / startAmount);
    //     }
    // }

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

    function test_stableSwap_USDS_to_USDC() public {
        uint256 amountIn = 1000 * 1e18;

        uint256 amountOut = swapPoolStable(user1, USDS, USDC, amountIn);

        assertGt(amountOut, 0);
        assertApproxEqRel(amountOut, amountIn, 0.002e18);

        console2.log("Stable swap: 1000 USDS -> %s USDC", amountOut / 1e18);
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
    // STABLE POOL DIAGNOSTIC TEST
    // ═══════════════════════════════════════════════════════════════════════════

    function test_stablePool_diagnostics() public {
        console2.log("\n=== STABLE POOL DIAGNOSTICS ===");

        // Define the tokens in Pool Stable
        address[6] memory stables = [USDC, USDT, FDUSD, USDS, USD1, USDE];
        string[6] memory symbols = ["USDC", "USDT", "FDUSD", "USDS", "USD1", "USDE"];

        // Log initial state
        console2.log("\n--- INITIAL STATE ---");
        for (uint i = 0; i < stables.length; i++) {
            IPool.Asset memory asset = poolStable.getAsset(stables[i]);
            uint256 coverage = poolStable.getCoverageRatio(stables[i]);
            uint256 price = poolStable.getMidPrice(stables[i]);

            console2.log("%s:", symbols[i]);
            console2.log("  Reserves:     %s", asset.reserves);
            console2.log("  Liabilities:  %s", asset.liabilities);
            console2.log("  Coverage:     %s%%", coverage * 100 / 1e18);
            console2.log("  Mid Price:    %s (1e18)", price);
            console2.log("  minFeeBps:    %s", asset.minFeeBps);
            console2.log("  maxFeeBps:    %s", asset.maxFeeBps);
            console2.log("  minDispersion: %s", asset.minDispersion);
            console2.log("  maxDispersion: %s", asset.maxDispersion);
            console2.log("  gamma:        %s", asset.gamma);
            console2.log("  vega:         %s", asset.vega);
        }

        // Simulate a series of swaps and log metrics
        console2.log("\n--- SWAP SIMULATION ---");

        // Swap 1: USDC -> USDT
        uint256 amountIn1 = 1000 * 1e18;
        logAndExecuteSwap(USDC, USDT, amountIn1, "USDC->USDT");

        // Swap 2: USDT -> USDC (reverse)
        vm.warp(block.timestamp + 20);
        uint256 usdtBalance = IERC20(USDT).balanceOf(user1);
        logAndExecuteSwap(USDT, USDC, usdtBalance, "USDT->USDC");

        // Swap 3: USDC -> FDUSD
        vm.warp(block.timestamp + 20);
        logAndExecuteSwap(USDC, FDUSD, 1000 * 1e18, "USDC->FDUSD");

        // Swap 4: FDUSD -> USDC (reverse)
        vm.warp(block.timestamp + 20);
        uint256 fdusdBalance = IERC20(FDUSD).balanceOf(user1);
        logAndExecuteSwap(FDUSD, USDC, fdusdBalance, "FDUSD->USDC");

        // Log final state
        console2.log("\n--- FINAL STATE ---");
        for (uint i = 0; i < stables.length; i++) {
            IPool.Asset memory asset = poolStable.getAsset(stables[i]);
            uint256 coverage = poolStable.getCoverageRatio(stables[i]);
            uint256 protocolFees = poolStable.getProtocolFees(stables[i]);

            console2.log("%s:", symbols[i]);
            console2.log("  Reserves:     %s", asset.reserves);
            console2.log("  Liabilities:  %s", asset.liabilities);
            console2.log("  Coverage:     %s%%", coverage * 100 / 1e18);
            console2.log("  Protocol Fees: %s", protocolFees);
        }
    }

    function logAndExecuteSwap(address tokenIn, address tokenOut, uint256 amountIn, string memory desc) internal {
        // Get quote before swap
        (uint256 amountOut, uint256 executionPrice, uint256 spreadBps, uint256 protoFee, uint256 lpFee, ) = getDetailedQuote(address(poolStable), tokenIn, tokenOut, amountIn);

        // Get pre-swap state
        IPool.Asset memory assetInBefore = poolStable.getAsset(tokenIn);
        IPool.Asset memory assetOutBefore = poolStable.getAsset(tokenOut);
        uint256 coverageInBefore = poolStable.getCoverageRatio(tokenIn);
        uint256 coverageOutBefore = poolStable.getCoverageRatio(tokenOut);

        // Calculate net coverage impact
        int256 netImpact = calculateNetCoverageImpact(
            assetInBefore.reserves, assetInBefore.liabilities, amountIn, executionPrice,
            assetOutBefore.reserves, assetOutBefore.liabilities, amountOut
        );

        // Log metrics
        string memory inSymbol = getTokenSymbol(tokenIn);
        string memory outSymbol = getTokenSymbol(tokenOut);

        console2.log("\n=== SWAP ===");
        console2.log("Description:");
        console2.log(desc);
        console2.log("Amount In:");
        console2.log(amountIn / 1e18);
        console2.log("Amount Out:");
        console2.log(amountOut / 1e18);
        console2.log("Execution Price (1e18):");
        console2.log(executionPrice);
        console2.log("Quoted Rate (output per 1 input):");
        console2.log((amountOut * 1e18) / amountIn);
        console2.log("Spread (bps):");
        console2.log(spreadBps);
        console2.log("Spread (percent * 1e6):");
        console2.log(uint256(spreadBps) * 100 / 1e6);
        console2.log("Proto Fee:");
        console2.log(protoFee / 1e18);
        console2.log("LP Fee:");
        console2.log(lpFee / 1e18);
        console2.log("Total Fee:");
        console2.log((protoFee + lpFee) / 1e18);
        console2.log("Total Fee (percent of input * 1e18):");
        console2.log((protoFee + lpFee) * 1e18 / amountIn);

        console2.log("\nINPUT TOKEN:");
        console2.log(inSymbol);
        console2.log("Reserves Before:");
        console2.log(uint256(assetInBefore.reserves) / 1e18);
        console2.log("Liabilities Before:");
        console2.log(uint256(assetInBefore.liabilities) / 1e18);
        console2.log("Coverage Before (% * 100):");
        console2.log(coverageInBefore * 100 / 1e18);

        console2.log("\nOUTPUT TOKEN:");
        console2.log(outSymbol);
        console2.log("Reserves Before:");
        console2.log(uint256(assetOutBefore.reserves) / 1e18);
        console2.log("Liabilities Before:");
        console2.log(uint256(assetOutBefore.liabilities) / 1e18);
        console2.log("Coverage Before (% * 100):");
        console2.log(coverageOutBefore * 100 / 1e18);

        console2.log("\nNET COVERAGE IMPACT:");
        console2.log(netImpact > 0 ? "WORSENS" : "IMPROVES");
        console2.log("Impact Value (negative = improves):");
        console2.log(uint256(netImpact > 0 ? netImpact : -netImpact) / 1e18);

        // Execute swap
        vm.startPrank(user1);
        MockERC20(tokenIn).approve(address(poolStable), amountIn);
        uint256 actualOut = poolStable.swap(tokenIn, tokenOut, amountIn, 0, user1);
        vm.stopPrank();

        // Get post-swap state
        IPool.Asset memory assetInAfter = poolStable.getAsset(tokenIn);
        IPool.Asset memory assetOutAfter = poolStable.getAsset(tokenOut);
        uint256 coverageInAfter = poolStable.getCoverageRatio(tokenIn);
        uint256 coverageOutAfter = poolStable.getCoverageRatio(tokenOut);

        console2.log("\n  POST-SWAP STATE:");
        int256 inReservesChange = int256(uint256(assetInAfter.reserves)) - int256(uint256(assetInBefore.reserves));
        int256 inLiabChange = int256(uint256(assetInAfter.liabilities)) - int256(uint256(assetInBefore.liabilities));
        int256 inCoverageChange = (int256(coverageInAfter) - int256(coverageInBefore)) * 10000 / 1e18;
        int256 outReservesChange = int256(uint256(assetOutAfter.reserves)) - int256(uint256(assetOutBefore.reserves));
        int256 outLiabChange = int256(uint256(assetOutAfter.liabilities)) - int256(uint256(assetOutBefore.liabilities));
        int256 outCoverageChange = (int256(coverageOutAfter) - int256(coverageOutBefore)) * 10000 / 1e18;

        console2.log("    ");
        console2.log(inSymbol);
        console2.log("    Reserves After:");
        console2.log(uint256(assetInAfter.reserves) / 1e18);
        console2.log("    Change:");
        console2.log(inReservesChange);
        console2.log("    Liabilities After:");
        console2.log(uint256(assetInAfter.liabilities) / 1e18);
        console2.log("    Change:");
        console2.log(inLiabChange);
        console2.log("    Coverage After:");
        console2.log(coverageInAfter * 100 / 1e18);
        console2.log("    Change (bps):");
        console2.log(inCoverageChange);
        console2.log("    ");
        console2.log(outSymbol);
        console2.log("    Reserves After:");
        console2.log(uint256(assetOutAfter.reserves) / 1e18);
        console2.log("    Change:");
        console2.log(outReservesChange);
        console2.log("    Liabilities After:");
        console2.log(uint256(assetOutAfter.liabilities) / 1e18);
        console2.log("    Change:");
        console2.log(outLiabChange);
        console2.log("    Coverage After:");
        console2.log(coverageOutAfter * 100 / 1e18);
        console2.log("    Change (bps):");
        console2.log(outCoverageChange);
    }

    function getDetailedQuote(address pool, address tokenIn, address tokenOut, uint256 amountIn) internal view returns (
        uint256 amountOut,
        uint256 executionPrice,
        uint256 spreadBps,
        uint256 protoFee,
        uint256 lpFee,
        int256 inventorySkewOut
    ) {
        IPool.SwapQuote memory quote = IPool(pool).getSwapQuote(tokenIn, tokenOut, amountIn);
        amountOut = quote.amountOut;
        spreadBps = quote.spreadBps;
        protoFee = quote.protoFee;
        lpFee = quote.lpFee;
        inventorySkewOut = quote.skewOut;

        // Calculate execution price
        if (amountOut > 0) {
            executionPrice = (amountOut * 1e18) / amountIn;
        } else {
            executionPrice = 0;
        }
    }

    function calculateNetCoverageImpact(
        uint128 reservesIn, uint128 liabilitiesIn, uint256 amountIn, uint256 priceIn,
        uint128 reservesOut, uint128 liabilitiesOut, uint256 amountOut
    ) internal pure returns (int256) {
        // Simplified coverage impact calculation
        // Input token: reserves increase by amountIn
        uint256 newReservesIn = uint256(reservesIn) + amountIn;

        // Output token: reserves decrease by amountOut
        uint256 newReservesOut = uint256(reservesOut) > amountOut ? uint256(reservesOut) - amountOut : 0;

        // Calculate imbalance before and after
        uint256 imbalanceBefore = (uint256(reservesIn) > liabilitiesIn ? uint256(reservesIn) - liabilitiesIn : liabilitiesIn - uint256(reservesIn))
                                   + (uint256(reservesOut) > liabilitiesOut ? uint256(reservesOut) - liabilitiesOut : liabilitiesOut - uint256(reservesOut));

        uint256 imbalanceAfter = (newReservesIn > liabilitiesIn ? newReservesIn - liabilitiesIn : liabilitiesIn - newReservesIn)
                                  + (newReservesOut > liabilitiesOut ? newReservesOut - liabilitiesOut : liabilitiesOut - newReservesOut);

        // Return negative if improves (reduces imbalance), positive if worsens
        return int256(imbalanceAfter) - int256(imbalanceBefore);
    }

    function getTokenSymbol(address token) internal view returns (string memory) {
        string memory symbol = MockERC20(token).symbol();

        // Handle special cases
        if (keccak256(bytes(symbol)) == keccak256(bytes("mUSDC"))) return "USDC";
        if (keccak256(bytes(symbol)) == keccak256(bytes("mUSDT"))) return "USDT";
        if (keccak256(bytes(symbol)) == keccak256(bytes("mFDUSD"))) return "FDUSD";
        if (keccak256(bytes(symbol)) == keccak256(bytes("mUSDS"))) return "USDS";
        if (keccak256(bytes(symbol)) == keccak256(bytes("mUSD1"))) return "USD1";
        if (keccak256(bytes(symbol)) == keccak256(bytes("mUSDE"))) return "USDE";

        return symbol;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPOSIT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_deposit_USDC() public {
        uint256 depositAmount = 50000 * 1e18;

        vm.startPrank(user2);
        USDC.safeApprove(address(poolZero), depositAmount);

        uint256 lpBefore = poolZero.getLPBalance(user2, USDC);
        IPool.DepositResult memory result = poolZero.deposit(USDC, depositAmount);
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

        IPool.DepositResult memory result = poolZero.deposit(WETH, depositAmount);

        assertGt(result.lpAmount, 0, "Should receive LP tokens");
        assertEq(result.actualDeposit, depositAmount);

        vm.stopPrank();

        console2.log("Deposit: %s WETH -> %s LP", depositAmount / 1e18, result.lpAmount / 1e18);
    }

    function test_deposit_multiple_assets() public {
        vm.startPrank(user2);

        // Deposit USDC
        USDC.safeApprove(address(poolZero), type(uint256).max);
        IPool.DepositResult memory r1 = poolZero.deposit(USDC, 10000 * 1e18);

        // Deposit WETH
        WETH.safeApprove(address(poolZero), type(uint256).max);
        IPool.DepositResult memory r2 = poolZero.deposit(WETH, 2 * 1e18);

        // Deposit WBTC
        WBTC.safeApprove(address(poolZero), type(uint256).max);
        IPool.DepositResult memory r3 = poolZero.deposit(WBTC, 0.5e18);

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
        IPool.DepositResult memory depositResult = poolZero.deposit(USDC, 10000 * 1e18);

        // Skip cooldown
        vm.warp(block.timestamp + 20);

        // Withdraw half
        uint256 lpToWithdraw = depositResult.lpAmount / 2;
        uint256 usdcBefore = IERC20(USDC).balanceOf(user2);

        IPool.WithdrawResult memory withdrawResult = poolZero.withdraw(USDC, lpToWithdraw, 0);

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
        IPool.DepositResult memory depositResult = poolZero.deposit(USDC, 10000 * 1e18);

        vm.warp(block.timestamp + 20);

        uint256 usdtBefore = IERC20(USDT).balanceOf(user2);
        IPool.WithdrawResult memory withdrawResult = poolZero.withdrawTo(USDC, USDT, depositResult.lpAmount, 0);
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
        IPool.DepositResult memory depositResult = poolZero.deposit(USDC, 10000 * 1e18);

        vm.warp(block.timestamp + 20);

        IPool.WithdrawResult memory withdrawResult = poolZero.withdraw(USDC, depositResult.lpAmount, 0);

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
        IPool.SwapQuote memory quote = poolZero.getSwapQuote(USDC, WETH, amountIn);
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
        IAdmin(address(poolZero)).freezeAsset(WETH);

        vm.stopPrank();

        // Try to swap - should fail
        vm.startPrank(user1);
        USDC.safeApprove(address(poolZero), 1000e18);
        vm.expectRevert();
        poolZero.swap(USDC, WETH, 1000e18, 0, user1);
        vm.stopPrank();

        // Unfreeze
        vm.prank(admin);
        IAdmin(address(poolZero)).unfreezeAsset(WETH);

        // Should work again
        vm.startPrank(user1);
        uint256 amountOut = poolZero.swap(USDC, WETH, 1000e18, 0, user1);
        assertGt(amountOut, 0);
        vm.stopPrank();

        console2.log("Admin: freeze/unfreeze test passed");
    }

    function test_admin_updateRiskConfig() public {
        // Get current risk config
        IPool.RiskConfig memory currentConfig = poolZero.getRiskConfig(USDC);
        console2.log("Current decayStartRatioBps:", currentConfig.decayStartRatioBps);

        // Request new config with different decay threshold
        uint8[16] memory riskPad;
        IPool.RiskConfig memory newConfig = IPool.RiskConfig({
            decayStartRatioBps: 9500,  // Changed from 9800 to 9500
            coverageMin: 5000,
            coverageMax: 20000,  // 200%
            decaySlope: 31709791,
            depthAmplifier: 20000,
            flags: C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT,
            _pad: riskPad
        });

        vm.prank(admin);
        IAdmin(address(poolZero)).requestUpdateRiskConfig(USDC, newConfig);

        // Warp past timelock
        vm.warp(block.timestamp + C.BASE_TIMELOCK + 1);

        // Execute
        vm.prank(admin);
        IAdmin(address(poolZero)).executeUpdateRiskConfig(USDC);

        // Verify
        IPool.RiskConfig memory updatedConfig = poolZero.getRiskConfig(USDC);
        assertEq(updatedConfig.decayStartRatioBps, 9500, "Config should be updated");

        console2.log("Admin: risk config updated from %s to %s",
            currentConfig.decayStartRatioBps, updatedConfig.decayStartRatioBps);
    }

    function test_admin_updateFeeParams() public {
        // Request new fee params
        uint8[29] memory feePad;
        IPool.FeeParams memory newFees = IPool.FeeParams({
            protoShare: 30,      // Changed from 25 to 30
            flashFeeBps: 10,     // Changed from 5 to 10
            _pad: feePad
        });

        vm.prank(admin);
        IAdmin(address(poolZero)).requestUpdateFeeParams(newFees);

        vm.warp(block.timestamp + C.LOW_TIMELOCK + 1);

        vm.prank(admin);
        IAdmin(address(poolZero)).executeUpdateFeeParams();

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
            IAdmin(address(poolZero)).requestTreasuryUpdate(treasury);
            vm.warp(block.timestamp + C.HIGH_TIMELOCK + 1);
            vm.prank(admin);
            IAdmin(address(poolZero)).executeTreasuryUpdate();

            // Collect fees
            uint256 treasuryBefore = IERC20(USDC).balanceOf(treasury);
            vm.prank(treasury);
            IAdmin(address(poolZero)).collectProtocolFees(USDC, treasury);
            uint256 treasuryAfter = IERC20(USDC).balanceOf(treasury);

            assertEq(treasuryAfter - treasuryBefore, feesBefore, "Treasury should receive fees");
            console2.log("Admin: collected %s USDC in fees", feesBefore / 1e18);
        }
    }

    function test_admin_cancelTimelock() public {
        // Request a treasury update (global operation - supported by cancelTimelock)
        address newTreasury = address(0xBEEF);

        vm.prank(admin);
        IAdmin(address(poolZero)).requestTreasuryUpdate(newTreasury);

        // Cancel before execution
        vm.prank(admin);
        IAdmin(address(poolZero)).cancelTimelock(uint8(IPool.OpType.UPDATE_TREASURY));

        // Try to execute - should fail (uses HIGH_TIMELOCK = 3 days)
        vm.warp(block.timestamp + C.HIGH_TIMELOCK + 1);
        vm.expectRevert();
        vm.prank(admin);
        IAdmin(address(poolZero)).executeTreasuryUpdate();

        console2.log("Admin: timelock cancel test passed");
    }

    function test_admin_only_owner() public {
        vm.prank(user1);
        vm.expectRevert();
        IAdmin(address(poolZero)).freezeAsset(USDC);

        console2.log("Admin: unauthorized access blocked");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // QUOTE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getSwapQuote() public {
        uint256 amountIn = 1000e18;

        IPool.SwapQuote memory quote = poolZero.getSwapQuote(USDC, WETH, amountIn);

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

        IPool.SwapQuote memory quote = poolZero.getSwapQuote(USDC, WETH, amountIn);

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

        IPool.SwapQuote memory quote = poolZero.getSwapQuote(tokenIn, tokenOut, amountIn);
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

        IPool.SwapQuote memory quote = poolStable.getSwapQuote(tokenIn, tokenOut, amountIn);
        uint256 minOut = (quote.amountOut * 98) / 100;

        amountOut = poolStable.swap(tokenIn, tokenOut, amountIn, minOut, user);

        vm.stopPrank();
    }

    function fundTestUsers() internal {
        console2.log("\n=== Funding Test Users via Faucet ===");

        address[4] memory users = [user1, user2, user3, lp1];

        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            faucet.drip();
        }

        console2.log("Funded 4 test users with $50k of each token");
    }

    function seedPoolZero() internal {
        console2.log("\n=== Seeding Pool Zero ===");

        vm.startPrank(lp1);

        // Pool Zero tokens (mUSDC, mUSDT, mWETH, mWBTC, mWBNB, mSOL, mZEC, mPAXG)
        (address[] memory tokenAddrs, ) = faucet.getTokens();

        for (uint256 i = 0; i < tokenAddrs.length; i++) {
            address token = tokenAddrs[i];
            string memory symbol = MockERC20(token).symbol();

            // Skip Pool Stable-only tokens (mUSDS, mUSD1, mUSDE, mFDUSD)
            if (keccak256(bytes(symbol)) == keccak256(bytes("mUSDS")) ||
                keccak256(bytes(symbol)) == keccak256(bytes("mUSD1")) ||
                keccak256(bytes(symbol)) == keccak256(bytes("mUSDE")) ||
                keccak256(bytes(symbol)) == keccak256(bytes("mFDUSD"))) {
                continue;
            }

            uint256 balance = IERC20(token).balanceOf(lp1);
            if (balance > 0) {
                token.safeApprove(address(poolZero), type(uint256).max);
                poolZero.deposit(token, balance);
            }
        }

        vm.stopPrank();

        console2.log("Pool Zero seeded with liquidity");
    }

    function seedPoolStable() internal {
        console2.log("\n=== Seeding Pool Stable ===");

        // Advance time past faucet cooldown to get more USDC/USDT for Pool Stable
        skip(1 days);

        // Re-fund lp1 for USDC/USDT since they were deposited to Pool Zero
        vm.prank(lp1);
        faucet.drip();

        vm.startPrank(lp1);

        (address[] memory tokenAddrs, ) = faucet.getTokens();

        for (uint256 i = 0; i < tokenAddrs.length; i++) {
            address token = tokenAddrs[i];
            string memory symbol = MockERC20(token).symbol();

            // Only stablecoins (mUSDC, mUSDT, mDAI, mTUSD, mFDUSD, mUSDD, mUSDP, mcrvUSD)
            if (!isStableSymbol(symbol)) continue;

            uint256 balance = IERC20(token).balanceOf(lp1);
            if (balance > 0) {
                token.safeApprove(address(poolStable), type(uint256).max);
                poolStable.deposit(token, balance);
            }
        }

        vm.stopPrank();

        console2.log("Pool Stable seeded with liquidity");
    }

    function isStableSymbol(string memory symbol) internal pure returns (bool) {
        bytes32 hash = keccak256(bytes(symbol));
        return hash == keccak256(bytes("mUSDC")) ||
               hash == keccak256(bytes("mUSDT")) ||
               hash == keccak256(bytes("mUSDS")) ||
               hash == keccak256(bytes("mUSD1")) ||
               hash == keccak256(bytes("mUSDE")) ||
               hash == keccak256(bytes("mFDUSD"));
    }

    function initializeTokenAddresses() internal {
        console2.log("\n=== Initializing Token Addresses from Faucet ===");

        (address[] memory tokenAddrs, ) = faucet.getTokens();

        for (uint256 i = 0; i < tokenAddrs.length; i++) {
            string memory symbol = MockERC20(tokenAddrs[i]).symbol();
            bytes32 hash = keccak256(bytes(symbol));

            if (hash == keccak256(bytes("mUSDC"))) USDC = tokenAddrs[i];
            else if (hash == keccak256(bytes("mUSDT"))) USDT = tokenAddrs[i];
            else if (hash == keccak256(bytes("mWETH"))) WETH = tokenAddrs[i];
            else if (hash == keccak256(bytes("mWBTC"))) WBTC = tokenAddrs[i];
            else if (hash == keccak256(bytes("mWBNB"))) WBNB = tokenAddrs[i];
            else if (hash == keccak256(bytes("mSOL"))) SOL = tokenAddrs[i];
            else if (hash == keccak256(bytes("mZEC"))) ZEC = tokenAddrs[i];
            else if (hash == keccak256(bytes("mPAXG"))) PAXG = tokenAddrs[i];
            else if (hash == keccak256(bytes("mFDUSD"))) FDUSD = tokenAddrs[i];
            else if (hash == keccak256(bytes("mUSDS"))) USDS = tokenAddrs[i];
            else if (hash == keccak256(bytes("mUSD1"))) USD1 = tokenAddrs[i];
            else if (hash == keccak256(bytes("mUSDE"))) USDE = tokenAddrs[i];
        }

        console2.log("Token addresses initialized:");
        console2.log("  mUSDC:", USDC);
        console2.log("  mUSDT:", USDT);
        console2.log("  mWETH:", WETH);
        console2.log("  mWBTC:", WBTC);
        console2.log("  mWBNB:", WBNB);
    }
}

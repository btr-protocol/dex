// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {StablecoinPoolFixture} from "../fixtures/StablecoinPoolFixture.sol";
import {IPoolV1} from "../../src/interfaces/IPoolV1.sol";
import {IERC20} from "../../src/interfaces/external/IERC20.sol";

/// @title PoolSimulation
/// @notice Simulation harness for hypothesis testing
/// @dev Exports pool state to CSV for analysis
contract PoolSimulation is StablecoinPoolFixture {
    // Simulation parameters
    uint256 public constant SEED_AMOUNT_6_DECIMALS = 1000e6;    // 1000 USDC/USDT/PYUSD
    uint256 public constant SEED_AMOUNT_18_DECIMALS = 1000e18;  // 1000 USDS/USDE
    uint256 public constant NUM_SWAPS = 100;
    uint256 public constant MAX_SWAP_PERCENT = 80;  // Max 80% of reserves

    // CSV output
    string constant CSV_PATH = "simulation_output.csv";
    string[] private csvLines;

    // State tracking
    struct PoolSnapshot {
        uint256 swapIndex;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        uint256 fee;
        // USDC state
        uint128 usdcReserves;
        uint128 usdcLiabilities;
        uint256 usdcCoverage;
        // USDT state
        uint128 usdtReserves;
        uint128 usdtLiabilities;
        uint256 usdtCoverage;
        // USDS state
        uint128 usdsReserves;
        uint128 usdsLiabilities;
        uint256 usdsCoverage;
        // USDE state
        uint128 usdeReserves;
        uint128 usdeLiabilities;
        uint256 usdeCoverage;
        // PYUSD state
        uint128 pyusdReserves;
        uint128 pyusdLiabilities;
        uint256 pyusdCoverage;
        // Aggregates
        uint256 totalValueLocked;
        uint256 totalProtocolFees;
    }

    // Token addresses for iteration
    address[] private tokens;
    string[] private tokenNames;

    function setUp() public override {
        // Fork mainnet first
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(rpcUrl);

        // Run base setup (deploys contracts)
        super.setUp();

        // Add all stablecoins to pool
        _addAllStablecoins();

        // Setup token arrays for iteration
        tokens = new address[](5);
        tokens[0] = USDC;
        tokens[1] = USDT;
        tokens[2] = USDS;
        tokens[3] = USDE;
        tokens[4] = PYUSD;

        tokenNames = new string[](5);
        tokenNames[0] = "USDC";
        tokenNames[1] = "USDT";
        tokenNames[2] = "USDS";
        tokenNames[3] = "USDE";
        tokenNames[4] = "PYUSD";
    }

    /// @notice Main simulation: random swaps with state tracking
    function test_simulation_random_swaps() public {
        // 1. Seed the pool
        _seedPool();

        // 2. Initialize CSV
        _initCSV();

        // 3. Take initial snapshot
        _recordSnapshot(0, address(0), address(0), 0, 0, 0);

        // 4. Run random swaps
        uint256 seed = uint256(keccak256(abi.encodePacked(block.timestamp, uint256(12345))));

        for (uint256 i = 1; i <= NUM_SWAPS; i++) {
            seed = _nextRandom(seed);

            // Pick random token pair
            uint256 fromIdx = seed % 5;
            seed = _nextRandom(seed);
            uint256 toIdx = seed % 5;

            // Ensure different tokens
            if (fromIdx == toIdx) {
                toIdx = (toIdx + 1) % 5;
            }

            address tokenIn = tokens[fromIdx];
            address tokenOut = tokens[toIdx];

            // Get max swap amount (80% of tokenOut reserves)
            IPoolV1.Asset memory assetOut = _getAsset(tokenOut);
            uint256 maxAmount = (uint256(assetOut.reserves) * MAX_SWAP_PERCENT) / 100;

            if (maxAmount == 0) {
                // Skip if no reserves
                continue;
            }

            // Random amount between 1% and 80% of reserves
            seed = _nextRandom(seed);
            uint256 swapPercent = 1 + (seed % MAX_SWAP_PERCENT);
            uint256 amountIn = (maxAmount * swapPercent) / 100;

            // Normalize to input token decimals
            uint8 decimalsIn = _getDecimals(tokenIn);
            uint8 decimalsOut = _getDecimals(tokenOut);

            if (decimalsIn < decimalsOut) {
                amountIn = amountIn / (10 ** (decimalsOut - decimalsIn));
            } else if (decimalsIn > decimalsOut) {
                amountIn = amountIn * (10 ** (decimalsIn - decimalsOut));
            }

            if (amountIn == 0) continue;

            // Execute swap
            (uint256 amountOut, uint256 fee) = _executeSimSwap(tokenIn, tokenOut, amountIn);

            // Record state
            _recordSnapshot(i, tokenIn, tokenOut, amountIn, amountOut, fee);

            // Advance time slightly for oracle updates
            vm.warp(block.timestamp + 1);
        }

        // 5. Write CSV to file
        _writeCSV();

        // 6. Print summary
        _printSummary();
    }

    /// @notice Stress test: large sequential swaps in one direction
    function test_simulation_directional_pressure() public {
        _seedPool();
        _initCSV();
        _recordSnapshot(0, address(0), address(0), 0, 0, 0);

        // All swaps: USDC -> USDT (creates imbalance)
        for (uint256 i = 1; i <= 50; i++) {
            IPoolV1.Asset memory usdtAsset = _getAsset(USDT);
            uint256 maxAmount = (uint256(usdtAsset.reserves) * 50) / 100;  // 50% max

            if (maxAmount < 1e6) break;

            uint256 amountIn = maxAmount / 10;  // 5% of USDT reserves

            (uint256 amountOut, uint256 fee) = _executeSimSwap(USDC, USDT, amountIn);
            _recordSnapshot(i, USDC, USDT, amountIn, amountOut, fee);

            vm.warp(block.timestamp + 1);
        }

        // Now reverse: USDT -> USDC
        for (uint256 i = 51; i <= 100; i++) {
            IPoolV1.Asset memory usdcAsset = _getAsset(USDC);
            uint256 maxAmount = (uint256(usdcAsset.reserves) * 50) / 100;

            if (maxAmount < 1e6) break;

            uint256 amountIn = maxAmount / 10;

            (uint256 amountOut, uint256 fee) = _executeSimSwap(USDT, USDC, amountIn);
            _recordSnapshot(i, USDT, USDC, amountIn, amountOut, fee);

            vm.warp(block.timestamp + 1);
        }

        _writeCSV();
        _printSummary();
    }

    /// @notice Test coverage ratio behavior under stress
    function test_simulation_coverage_stress() public {
        _seedPool();
        _initCSV();
        _recordSnapshot(0, address(0), address(0), 0, 0, 0);

        // Drain USDT reserves progressively
        for (uint256 i = 1; i <= 20; i++) {
            IPoolV1.Asset memory usdtAsset = _getAsset(USDT);

            // Swap 30% of remaining USDT reserves each time
            uint256 targetOut = (uint256(usdtAsset.reserves) * 30) / 100;
            if (targetOut < 1e6) break;

            // Calculate approximate USDC needed
            uint256 amountIn = targetOut;  // ~1:1 for stables

            (uint256 amountOut, uint256 fee) = _executeSimSwap(USDC, USDT, amountIn);
            _recordSnapshot(i, USDC, USDT, amountIn, amountOut, fee);

            vm.warp(block.timestamp + 1);

            // Log coverage ratio
            IPoolV1.Asset memory newUsdtAsset = _getAsset(USDT);
            uint256 coverage = newUsdtAsset.liabilities > 0
                ? (uint256(newUsdtAsset.reserves) * 1e18) / uint256(newUsdtAsset.liabilities)
                : type(uint256).max;

            console2.log("Swap %d - USDT coverage: %d%%", i, coverage / 1e16);
        }

        _writeCSV();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _seedPool() private {
        // Users are already funded with 1M each via _fundTestUsers() in setUp()
        // Deposit initial liquidity (1000 of each)
        _deposit(user1, USDC, SEED_AMOUNT_6_DECIMALS);
        _deposit(user1, USDT, SEED_AMOUNT_6_DECIMALS);
        _deposit(user1, USDS, SEED_AMOUNT_18_DECIMALS);
        _deposit(user1, USDE, SEED_AMOUNT_18_DECIMALS);
        _deposit(user1, PYUSD, SEED_AMOUNT_6_DECIMALS);

        console2.log("Pool seeded with 1000 of each stablecoin");
    }

    function _executeSimSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) private returns (uint256 amountOut, uint256 fee) {
        // Get quote first
        IPoolV1.SwapQuote memory quote = _getQuote(tokenIn, tokenOut, amountIn);

        // Execute swap
        amountOut = _swap(user1, tokenIn, tokenOut, amountIn, 0);
        fee = quote.protoFee + quote.lpFee;
    }

    function _getAsset(address token) private view returns (IPoolV1.Asset memory) {
        return IPoolV1(address(pool)).getAsset(token);
    }

    function _getDecimals(address token) private view returns (uint8) {
        return _getAsset(token).decimals;
    }

    function _nextRandom(uint256 seed) private pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(seed)));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CSV GENERATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _initCSV() private {
        // CSV header
        string memory header = string(abi.encodePacked(
            "swap_index,",
            "token_in,token_out,amount_in,amount_out,fee,",
            "usdc_reserves,usdc_liabilities,usdc_coverage,",
            "usdt_reserves,usdt_liabilities,usdt_coverage,",
            "usds_reserves,usds_liabilities,usds_coverage,",
            "usde_reserves,usde_liabilities,usde_coverage,",
            "pyusd_reserves,pyusd_liabilities,pyusd_coverage,",
            "total_tvl,total_protocol_fees"
        ));
        csvLines.push(header);
    }

    function _recordSnapshot(
        uint256 swapIndex,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    ) private {
        PoolSnapshot memory snap;
        snap.swapIndex = swapIndex;
        snap.tokenIn = tokenIn;
        snap.tokenOut = tokenOut;
        snap.amountIn = amountIn;
        snap.amountOut = amountOut;
        snap.fee = fee;

        // Get all asset states
        IPoolV1.Asset memory usdc = _getAsset(USDC);
        snap.usdcReserves = usdc.reserves;
        snap.usdcLiabilities = usdc.liabilities;
        snap.usdcCoverage = usdc.liabilities > 0
            ? (uint256(usdc.reserves) * 1e18) / uint256(usdc.liabilities)
            : type(uint256).max;

        IPoolV1.Asset memory usdt = _getAsset(USDT);
        snap.usdtReserves = usdt.reserves;
        snap.usdtLiabilities = usdt.liabilities;
        snap.usdtCoverage = usdt.liabilities > 0
            ? (uint256(usdt.reserves) * 1e18) / uint256(usdt.liabilities)
            : type(uint256).max;

        IPoolV1.Asset memory usds = _getAsset(USDS);
        snap.usdsReserves = usds.reserves;
        snap.usdsLiabilities = usds.liabilities;
        snap.usdsCoverage = usds.liabilities > 0
            ? (uint256(usds.reserves) * 1e18) / uint256(usds.liabilities)
            : type(uint256).max;

        IPoolV1.Asset memory usde = _getAsset(USDE);
        snap.usdeReserves = usde.reserves;
        snap.usdeLiabilities = usde.liabilities;
        snap.usdeCoverage = usde.liabilities > 0
            ? (uint256(usde.reserves) * 1e18) / uint256(usde.liabilities)
            : type(uint256).max;

        IPoolV1.Asset memory pyusd = _getAsset(PYUSD);
        snap.pyusdReserves = pyusd.reserves;
        snap.pyusdLiabilities = pyusd.liabilities;
        snap.pyusdCoverage = pyusd.liabilities > 0
            ? (uint256(pyusd.reserves) * 1e18) / uint256(pyusd.liabilities)
            : type(uint256).max;

        // Calculate TVL (normalize all to 6 decimals for comparison)
        snap.totalValueLocked =
            uint256(usdc.reserves) +
            uint256(usdt.reserves) +
            uint256(usds.reserves) / 1e12 +
            uint256(usde.reserves) / 1e12 +
            uint256(pyusd.reserves);

        // Get protocol fees
        snap.totalProtocolFees =
            IPoolV1(address(pool)).getProtocolFees(USDC) +
            IPoolV1(address(pool)).getProtocolFees(USDT) +
            IPoolV1(address(pool)).getProtocolFees(USDS) / 1e12 +
            IPoolV1(address(pool)).getProtocolFees(USDE) / 1e12 +
            IPoolV1(address(pool)).getProtocolFees(PYUSD);

        // Format CSV line
        string memory line = _formatSnapshotCSV(snap);
        csvLines.push(line);
    }

    function _formatSnapshotCSV(PoolSnapshot memory snap) private view returns (string memory) {
        // Get token names
        string memory tokenInName = snap.tokenIn == address(0) ? "INIT" : _getTokenName(snap.tokenIn);
        string memory tokenOutName = snap.tokenOut == address(0) ? "INIT" : _getTokenName(snap.tokenOut);

        // Build CSV line (split to avoid stack too deep)
        string memory part1 = string(abi.encodePacked(
            vm.toString(snap.swapIndex), ",",
            tokenInName, ",",
            tokenOutName, ",",
            vm.toString(snap.amountIn), ",",
            vm.toString(snap.amountOut), ",",
            vm.toString(snap.fee), ","
        ));

        string memory part2 = string(abi.encodePacked(
            vm.toString(uint256(snap.usdcReserves)), ",",
            vm.toString(uint256(snap.usdcLiabilities)), ",",
            _formatCoverage(snap.usdcCoverage), ",",
            vm.toString(uint256(snap.usdtReserves)), ",",
            vm.toString(uint256(snap.usdtLiabilities)), ",",
            _formatCoverage(snap.usdtCoverage), ","
        ));

        string memory part3 = string(abi.encodePacked(
            vm.toString(uint256(snap.usdsReserves)), ",",
            vm.toString(uint256(snap.usdsLiabilities)), ",",
            _formatCoverage(snap.usdsCoverage), ",",
            vm.toString(uint256(snap.usdeReserves)), ",",
            vm.toString(uint256(snap.usdeLiabilities)), ",",
            _formatCoverage(snap.usdeCoverage), ","
        ));

        string memory part4 = string(abi.encodePacked(
            vm.toString(uint256(snap.pyusdReserves)), ",",
            vm.toString(uint256(snap.pyusdLiabilities)), ",",
            _formatCoverage(snap.pyusdCoverage), ",",
            vm.toString(snap.totalValueLocked), ",",
            vm.toString(snap.totalProtocolFees)
        ));

        return string(abi.encodePacked(part1, part2, part3, part4));
    }

    function _formatCoverage(uint256 coverage) private pure returns (string memory) {
        if (coverage == type(uint256).max) {
            return "INF";
        }
        // Return as percentage with 2 decimals (coverage is in 1e18)
        return vm.toString(coverage / 1e14);  // Gives us basis points * 100
    }

    function _getTokenName(address token) private view returns (string memory) {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == token) {
                return tokenNames[i];
            }
        }
        return "UNKNOWN";
    }

    function _writeCSV() private {
        // Concatenate all lines
        string memory fullCSV = "";
        for (uint256 i = 0; i < csvLines.length; i++) {
            fullCSV = string(abi.encodePacked(fullCSV, csvLines[i], "\n"));
        }

        // Write to file
        vm.writeFile(CSV_PATH, fullCSV);
        console2.log("CSV written to:", CSV_PATH);
        console2.log("Total rows:", csvLines.length);
    }

    function _printSummary() private view {
        console2.log("\n=== SIMULATION SUMMARY ===");

        IPoolV1.Asset memory usdc = _getAsset(USDC);
        IPoolV1.Asset memory usdt = _getAsset(USDT);
        IPoolV1.Asset memory usds = _getAsset(USDS);
        IPoolV1.Asset memory usde = _getAsset(USDE);
        IPoolV1.Asset memory pyusd = _getAsset(PYUSD);

        console2.log("\nFinal Reserves (in token units):");
        console2.log("  USDC:", uint256(usdc.reserves) / 1e6);
        console2.log("  USDT:", uint256(usdt.reserves) / 1e6);
        console2.log("  USDS:", uint256(usds.reserves) / 1e18);
        console2.log("  USDE:", uint256(usde.reserves) / 1e18);
        console2.log("  PYUSD:", uint256(pyusd.reserves) / 1e6);

        console2.log("\nFinal Coverage Ratios:");
        console2.log("  USDC:", _coveragePercent(usdc), "%");
        console2.log("  USDT:", _coveragePercent(usdt), "%");
        console2.log("  USDS:", _coveragePercent(usds), "%");
        console2.log("  USDE:", _coveragePercent(usde), "%");
        console2.log("  PYUSD:", _coveragePercent(pyusd), "%");

        console2.log("\nProtocol Fees Collected (in token units):");
        console2.log("  USDC:", IPoolV1(address(pool)).getProtocolFees(USDC) / 1e6);
        console2.log("  USDT:", IPoolV1(address(pool)).getProtocolFees(USDT) / 1e6);
        console2.log("  USDS:", IPoolV1(address(pool)).getProtocolFees(USDS) / 1e18);
        console2.log("  USDE:", IPoolV1(address(pool)).getProtocolFees(USDE) / 1e18);
        console2.log("  PYUSD:", IPoolV1(address(pool)).getProtocolFees(PYUSD) / 1e6);
    }

    function _coveragePercent(IPoolV1.Asset memory asset) private pure returns (uint256) {
        if (asset.liabilities == 0) return 100;
        return (uint256(asset.reserves) * 100) / uint256(asset.liabilities);
    }
}

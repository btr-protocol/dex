// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOracle} from "./IOracle.sol";
import {IInternalOracle} from "./IInternalOracle.sol";

import {LibLiquiditySegments as SegLib} from "../libraries/LibLiquiditySegments.sol";

/// @title IBAMM
/// @notice Interface for the BTR AMM (Bayesian True Range AMM) protocol
/// @dev Defines all external functions and events for the AMM
interface IBAMM {
    // ========== CONFIGURATION STRUCTS ==========

    /// @notice Per-asset fee configuration (all 6 fee types consolidated)
    /// @dev 1 unit = 0.0001% = 0.01 bps, precision = 100,000 (BPS_PRECISION)
    /// @dev Max value: 65535 = 6.5535% (uint16 max, always cast to uint256 for arithmetic)
    /// @dev Total: 12 bytes (perfectly packed)
    struct FeeConfig {
        uint16 minFeeBps;           // Min swap fee (e.g., 100 = 0.01% = 1 bps)
        uint16 maxFeeBps;           // Max swap fee (e.g., 50000 = 5% = 500 bps)
        uint16 depositFeeBps;       // Deposit fee (default 0)
        uint16 withdrawalFeeBps;    // Withdrawal fee (default 0)
        uint16 flashFeeBps;         // Flash loan fee (default 0, target 50 = 0.005% = 0.5bps)
        uint16 protocolFeeBps;      // Protocol fee split (e.g., 1000 = 1% of swap fees to treasury)
    }

    /// @notice Dynamic fee calculation configuration (per-asset)
    /// @dev Used for tri-factor swap fee calculation (coverage × volatility × deviation)
    /// @dev See FEES.md for complete tri-factor model specification
    struct DynamicFeeConfig {
        // Coverage factor params (per-asset reserves/liabilities ratio)
        uint16 minCovMult;          // Min coverage multiplier when under-collateralized (×100, e.g., 20 = 0.2x)
        uint16 maxCovMult;          // Max coverage multiplier when over-collateralized (×100, e.g., 10000 = 100x)
        uint256 maxCovUnder;        // Max under-coverage deviation to scale (WAD, e.g., 0.5e18 = 50%)
        uint256 maxCovOver;         // Max over-coverage deviation to scale (WAD, e.g., 0.5e18 = 50%)

        // Volatility factor params
        uint16 volBeta;             // Volatility shock sensitivity (×100, e.g., 100 = 1x pass-through)
        uint16 maxVolR;             // Max shock ratio (×100, e.g., 500 = 5x)
        uint16 maxVolMult;          // Max volatility multiplier (×100, e.g., 500 = 5x)
        uint16 volEpsilon;          // Min baseline volatility for safety (1e6 base, e.g., 1000 = 0.001%)

        // Deviation factor params (price divergence)
        uint16 maxDevD1;            // Max spot-vs-fast deviation (bps, e.g., 500 = 5%)
        uint16 maxDevD2;            // Max fast-vs-slow deviation (bps, e.g., 200 = 2%)
        uint16 devAlpha;            // Deviation multiplier weight (×100, e.g., 50 = 0.5x weight on oracle drift)
        uint16 maxDevMult;          // Max deviation multiplier (×100, e.g., 300 = 3x)

        // Base fee params
        uint16 baseK;               // Base fee slope multiplier (×100, e.g., 30 = 0.3% per 1% vol)
        uint16 minBaseFee;          // Min base fee (bps, 100k precision, e.g., 100 = 1 bps)

        // Total multiplier bounds
        uint16 minMult;             // Min total multiplier (×100, e.g., 10 = 0.1x)
        uint16 maxMult;             // Max total multiplier (×100, e.g., 10000 = 100x)
    }

    /// @notice Oracle configuration (per-asset)
    /// @dev feedId computed dynamically: keccak256(abi.encodePacked(token, baseToken))
    struct OracleConfig {
        address mainOracle;         // Main oracle (address(this)=internal, else=external IOracle)
        address fallbackOracle;     // Fallback oracle (address(0)=disabled, address(this)=internal)
        bytes extension;            // Internal oracle init: abi.encode(uint64 price, uint32 fastVolEMA, uint32 slowVolEMA, uint16 maxTWAPChange, uint32 fastWindow, uint32 slowWindow)
    }

    /// @notice Risk configuration (separate mapping: riskConfigs[token])
    /// @dev Circuit breakers + liability decay params (3 slots)
    struct RiskConfig {
        uint128 minLiquidity;          // Min reserves required
        uint64 reservePrice;           // Reserve price floor in b64 (Circuit Breaker #1, 0=disabled)
        bytes32 refFeed;               // Reference oracle feedId for beta deviation check (0=disabled)
        uint16 maxBetaDeviationBps;    // Max beta deviation: |(fast/slow)/(refFast/refSlow) - 1| (adaptive depeg detection)
        uint16 maxFastDeviationBps;    // Max fast-vs-spot deviation (Circuit Breaker #2, 0=disabled)
        uint16 maxSlowDeviationBps;    // Max slow-vs-fast deviation (Circuit Breaker #3, 0=disabled)
        uint16 decayStartRatioBps;     // Coverage threshold to start decay (e.g., 9800 = 98%, 0=disabled)
        uint16 decayAmplification;     // Decay curve exponent × 10000 (e.g., 10000 = linear, 20000 = quadratic)
        uint32 decaySlope;             // Decay rate: liabilities decrease by (slope × elapsed) per second
        uint16 flags;                  // Bit-packed: bit0=frozen, bit1=swapEnabled, bit2=liabilitySwapEnabled, bit3=decayEnabled, bit4=flashEnabled, bit5=feeOnTransfer
    }

    /// @notice Liquidity profile parameters (for Makima spline configuration)
    /// @dev Slopes must be pre-computed off-chain using Makima algorithm
    struct LiquidtyConfig {
        uint8[] weights;            // Liquidity weights (must sum to 255)
        int8[] endOffsets;          // TWAP offsets as % of breadth (-100 to +100)
        int32[] slopes;             // Pre-computed Makima slopes (int32 fixed-point, scale=1e9)
        uint32 baseBreadth;         // Base breadth (bps, 1M precision, 0.0001% base), breadth when vol=0
        uint32 maxBreadth;          // Max breadth in bps (1M precision, 0.0001% base)
        uint32 volKappa;            // Volatility sensitivity (1e6 precision)
    }

    // ========== ASSET STRUCTS (HOT PATH OPTIMIZED) ==========

    /// @notice Asset hot path data (2 slots = 64 bytes, accessed every swap/deposit/withdraw)
    /// @dev Optimized for minimal SLOADs in critical paths
    /// @dev Stored in mapping: assets[token]
    /// @dev Oracle addresses stored separately in oracleConfigs[token]
    struct Asset {
        // SLOT 0: LP state (32 bytes)
        uint128 reserves;              // Physical tokens in pool
        uint128 liabilities;           // Total LP claims (Wombat-style)

        // SLOT 1: Fees + metadata (14 bytes used, 18 bytes spare)
        FeeConfig fees;                // All 6 fee types (12 bytes)
        uint8 decimals;                // Token decimals (1 byte)
        uint8 segmentCount;            // Active Makima segments cached from profile (1 byte)
        // 18 bytes spare for future use
    }

    /// @notice LP state (separate mapping: lpStates[token])
    /// @dev 3 slots = 96 bytes (includes decay state)
    struct LPState {
        uint128 totalScaledSupply;     // Sum of scaled LP balances (1e12 precision)
        uint128 liquidityIndex;        // Rebasing multiplier (starts 1e18, needs precision)
        uint64 decayStartTime;         // Liability decay start timestamp (0 = inactive)
        uint32 coverageAtStart;        // Coverage ratio when decay started (bps)
        uint32 lastUpdateTime;         // Last decay update timestamp
    }

    /// @notice Liquidity profile for Makima cubic spline bonding curve
    /// @dev Separate mapping: liquidityProfiles[token]
    /// @dev Breadth scales with volatility: breadth = min(baseBreadth + vol×κ, maxBreadth)
    struct LiquidityProfile {
        uint32 baseBreadth;            // Base breadth when vol=0 (bps, 1M precision)
        uint32 maxBreadth;             // Max breadth cap (bps, 1M precision)
        uint32 volKappa;               // Volatility sensitivity (1e6 precision)
        SegLib.PackedSegments segments; // Packed segment data (weights, offsets, slopes)
    }

    /// @notice Fee components for transparency
    /// @dev For two-leg routes, totalFeeBps is the weighted average of leg1FeeBps and leg2FeeBps
    struct FeeComponents {
        uint256 baseFee;                    // Base component
        uint256 volatilityMultiplier;       // Volatility component
        uint256 inventoryMultiplier;        // Inventory (coverage) component
        uint256 divergenceMultiplier;       // Divergence component
        uint256 totalFeeBps;                // Effective fee (single-leg or weighted avg)
        uint256 leg1FeeBps;                 // Fee for leg1 (A→base), 0 if direct base exit
        uint256 leg2FeeBps;                 // Fee for leg2 (base→B), 0 if not triangulated
    }

    // ========== STORAGE LAYOUT ==========

    /// @notice Main storage structure for BAMM - ULTRA-LEAN
    /// @custom:storage-location erc7201:bamm.storage
    /// @dev Pausable handled by Solady's Pausable mixin (no storage needed)
    struct BAMMStorage {
        // SLOT 0: Base token
        address baseToken;              // 20 bytes

        // SLOT 1: WETH address for native token wrapping
        address weth;                   // 20 bytes (WETH contract for native ETH support)

        // Arrays and mappings (each gets independent slots)
        address[] registeredAssets;

        // Hot path: Asset struct (2 slots per asset)
        mapping(address => Asset) assets;

        // Cold storage: Separate configs (accessed infrequently)
        mapping(address => LPState) lpStates;
        mapping(address => LiquidityProfile) liquidityProfiles;
        mapping(address => RiskConfig) riskConfigs;
        mapping(address => DynamicFeeConfig) dynamicFeeConfigs; // Tri-factor fee calculation params per asset
        mapping(address => OracleConfig) oracleConfigs;  // Oracle addresses per asset
        mapping(address => address) hooks;  // Hook contract per asset

        // LP balances and protocol fees
        mapping(address => mapping(address => uint256)) scaledBalances;
        mapping(address => uint256) protocolFees;
        mapping(address => bool) blacklisted;

        // Internal oracle feed data by feedId (keccak256(abi.encodePacked(token, baseToken)))
        mapping(bytes32 => IInternalOracle.InternalFeedData) internalFeeds;
    }

    // ========== EVENTS ==========

    // Pool events
    event Swapped(address indexed sender, address indexed receiver, address indexed tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, uint256 feeBps);
    event SwappedTwoLeg(address indexed sender, address indexed receiver, address indexed tokenIn, address base, address tokenOut, uint256 amountIn, uint256 amountOut, uint256 leg1FeeBps, uint256 leg2FeeBps);
    event BatchSwapped(address indexed sender, address indexed receiver, address[] path, uint256[] amounts);
    event LiabilitySwapped(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 lpAmountIn, uint256 lpAmountOut, uint256 haircut);
    event Deposited(address indexed sender, address indexed token, uint256 amount, uint256 lpTokens);
    event Withdrawn(address indexed sender, address indexed token, uint256 lpTokens, uint256 amount, uint256 feeBps);
    event ProtocolFeesCollected(address indexed treasury, address[] tokens, uint256[] amounts);

    // Asset events
    event AssetAdded(address indexed token, uint128 minLiquidity);
    event AssetFrozen(address indexed token, string reason);
    event AssetUnfrozen(address indexed token);
    event BaseAssetUpdated(address indexed oldBase, address indexed newBase);
    event FeeConfigUpdated(address indexed token, FeeConfig fees);
    event OracleConfigUpdated(address indexed token, address indexed mainOracle, address indexed fallbackOracle);
    event RiskConfigUpdated(address indexed token, RiskConfig risk);

    // Oracle events
    event OracleFeedUpdated(bytes32 indexed feedId, IOracle.FeedData data, address indexed updater);
    event LiquidityProfileUpdated(address indexed token, uint8 segments);
    event CircuitBreakerTriggered(address indexed token, int256 deviationBps, uint256 timestamp);

    // Owner events
    event PoolPaused();
    event PoolUnpaused();
    event RoleGrantPending(address indexed account, bytes32 indexed role, address indexed replacing);
    event RoleAccepted(address indexed account, bytes32 indexed role);
    event RoleRevoked(address indexed account, bytes32 indexed role);

    // Blacklist events
    event AddressBlacklisted(address indexed account);
    event AddressRemovedFromBlacklist(address indexed account);

    // Hook events
    event HooksUpdated(address indexed token, address indexed hookAddress);

    // Flash loan events (enable/disable only, fee changes emit FeeConfigUpdated)
    event FlashLoansEnabled(address indexed token);
    event FlashLoansDisabled(address indexed token);

    // Liability decay events
    event LiabilityDecayStarted(address indexed token, uint256 liabilityAtStart, uint256 coverageAtStart, uint256 timestamp);
    event LiabilityDecayStopped(address indexed token, uint256 finalLiability, uint256 finalCoverage, uint256 timestamp);
    event LiabilityDecayApplied(address indexed token, uint256 oldLiability, uint256 newLiability, uint256 coverage, uint256 elapsed);

    // ========== BATCH SWAP STRUCTS ==========

    /// @notice Single swap step in a batch swap sequence
    /// @dev amountIn of 0 means use full output from previous step (chaining)
    struct SwapStep {
        address tokenIn;        // Input token address
        address tokenOut;       // Output token address
        uint256 amountIn;       // Input amount (0 = use previous output)
        uint256 minAmountOut;   // Minimum output for slippage protection
    }

    // ========== USER FUNCTIONS ==========

    /// @notice Swap one token for another
    /// @param tokenIn Token to swap from
    /// @param tokenOut Token to swap to
    /// @param amountIn Amount of tokenIn to swap
    /// @param minAmountOut Minimum acceptable amount of tokenOut
    /// @param receiver Address to receive the swapped tokens
    /// @return amountOut Actual amount of tokenOut received
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) external payable returns (uint256 amountOut);

    /// @notice Execute multiple swaps in sequence with optimized gas usage
    /// @dev Supports multi-hop swaps (e.g., USDC → WETH → DAI)
    /// @dev All swaps executed atomically with single settle at end
    /// @dev If step.amountIn is 0, uses full output from previous step
    /// @param steps Array of swap steps to execute in sequence
    /// @param receiver Address to receive final output tokens
    /// @return amounts Array of output amounts for each swap step
    function batchSwap(
        SwapStep[] calldata steps,
        address receiver
    ) external payable returns (uint256[] memory amounts);

    /// @notice Swap LP liability between assets (rebalancing without haircut)
    /// @param tokenIn Asset to reduce liability from
    /// @param tokenOut Asset to add liability to
    /// @param lpAmountIn LP tokens to swap
    /// @param minLpAmountOut Minimum LP tokens to receive
    /// @return lpAmountOut LP tokens received (after haircut if any)
    function swapLiability(
        address tokenIn,
        address tokenOut,
        uint256 lpAmountIn,
        uint256 minLpAmountOut
    ) external returns (uint256 lpAmountOut);

    /// @notice Deposit single asset and receive LP tokens
    /// @param token Token to deposit
    /// @param amount Amount to deposit
    /// @param minLpTokens Minimum LP tokens to receive
    /// @return lpTokens Amount of LP tokens minted
    function deposit(
        address token,
        uint256 amount,
        uint256 minLpTokens
    ) external payable returns (uint256 lpTokens);

    /// @notice Withdraw single asset by burning LP tokens
    /// @param token Token to withdraw
    /// @param lpTokens Amount of LP tokens to burn
    /// @param minAmountOut Minimum amount of tokens to receive
    /// @return amountOut Amount of tokens withdrawn
    function withdraw(
        address token,
        uint256 lpTokens,
        uint256 minAmountOut
    ) external returns (uint256 amountOut);

    // ========== VIEW FUNCTIONS ==========

    /// @notice Calculate swap fee for a potential trade
    /// @return Fee components breakdown
    function calculateSwapFee(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (FeeComponents memory);

    /// @notice Get quote for a swap
    /// @return amountOut Expected output amount
    /// @return feeBps Fee in basis points
    function getSwapQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut, uint256 feeBps);

    /// @notice Get current LP token value in underlying
    /// @param token Asset address
    /// @param lpTokens Amount of LP tokens
    /// @return underlyingAmount Value in underlying tokens
    function getLPValue(
        address token,
        uint256 lpTokens
    ) external view returns (uint256 underlyingAmount);

    /// @notice Get total value locked in base token terms
    /// @return tvl Total value locked
    function lpStates(address token) external view returns (LPState memory);
    function getTotalValue() external view returns (uint256 tvl);

    /// @notice Get oracle data for any asset (public for external contracts)
    /// @dev Abstracts feed ID resolution and fallback logic
    /// @dev Works with both internal and external oracles
    /// @param token Asset address
    /// @return fastEMA Fast price EMA in b64 format
    /// @return slowEMA Slow price EMA in b64 format
    /// @return fastVolEMA Fast volatility EMA (1e6 base: 1_000_000 = 1%)
    /// @return slowVolEMA Slow volatility EMA (1e6 base: 1_000_000 = 1%)
    /// @return updatedAt Last oracle update timestamp
    function getFeedData(address token) external view returns (
        uint64 fastEMA,
        uint64 slowEMA,
        uint32 fastVolEMA,
        uint32 slowVolEMA,
        uint32 updatedAt
    );

    /// @notice Get asset state for frontend (prices, reserves, liabilities)
    /// @dev Returns packed data for efficient multicall aggregation
    /// @param token Asset address
    /// @return fastEMA Fast price EMA in b64 format (decode: price_1e18 = M.decodePriceTo1e18(fastEMA))
    /// @return slowEMA Slow price EMA in b64 format (decode: price_1e18 = M.decodePriceTo1e18(slowEMA))
    /// @return reserves Reserves in token decimals
    /// @return liabilities Liabilities in token decimals
    /// @return reservesValue Reserves value in accounting base (1e18)
    /// @return liabilitiesValue Liabilities value in accounting base (1e18)
    function getAssetState(address token) external view returns (
        uint64 fastEMA,
        uint64 slowEMA,
        uint128 reserves,
        uint128 liabilities,
        uint256 reservesValue,
        uint256 liabilitiesValue
    );

    /// @notice Get LP state for a token
    /// @param token Asset address
    /// @return LP state (totalScaledSupply, liquidityIndex, decayStartTime)
    function getLPState(address token) external view returns (LPState memory);

    // ========== OWNER FUNCTIONS ==========

    /// @notice Add new asset to the pool
    /// @param token Token address
    /// @param fees Fee configuration (deposit, withdrawal, min, max, flash, protocol)
    /// @param oracle Oracle configuration (main, fallback, extension)
    /// @param risk Risk configuration (minLiquidity, reservePrice, refFeed, deviations, decay params, flags)
    /// @param profile Liquidity profile (weights, offsets, slopes, baseBreadth, maxBreadth, volKappa)
    /// @dev For internal oracle (mainOracle == address(this)), extension must contain:
    ///      abi.encode(uint64 price, uint32 fastVolEMA, uint32 slowVolEMA, uint16 maxTWAPChange, uint32 fastWindow, uint32 slowWindow)
    /// @dev feedId always computed as keccak256(abi.encodePacked(token, baseToken))
    function addAsset(
        address token,
        FeeConfig calldata fees,
        OracleConfig calldata oracle,
        RiskConfig calldata risk,
        LiquidtyConfig calldata profile
    ) external;

    /// @notice Pause entire pool
    function pausePool() external;

    /// @notice Unpause pool
    function unpausePool() external;

    /// @notice Emergency freeze specific asset (owner or guardian)
    /// @param token Token to freeze
    /// @param reason Reason for freezing
    function freezeAsset(address token, string calldata reason) external;

    /// @notice Unfreeze asset (owner or guardian)
    /// @param token Token to unfreeze
    function unfreezeAsset(address token) external;

    /// @notice Update fee configuration
    /// @param token Asset address
    /// @param fees New fee configuration (all 6 fee types)
    function updateFeeConfig(address token, FeeConfig calldata fees) external;

    /// @notice Update oracle configuration
    /// @param token Asset address
    /// @param oracle New oracle configuration (main, fallback, extension for init)
    function updateOracleConfig(address token, OracleConfig calldata oracle) external;

    /// @notice Update risk configuration
    /// @param token Asset address
    /// @param risk New risk configuration (minLiquidity, reservePrice, refFeed, deviations, decay params, flags)
    function updateRiskConfig(address token, RiskConfig calldata risk) external;

    /// @notice Enable flash loans for an asset (sets flag)
    /// @param token Token address
    function enableFlashLoans(address token) external;

    /// @notice Disable flash loans for an asset (clears flag)
    /// @param token Token address
    function disableFlashLoans(address token) external;

    /// @notice Enable liability decay for an asset (sets flag)
    /// @param token Token address
    function enableDecay(address token) external;

    /// @notice Disable liability decay for an asset (clears flag)
    /// @param token Token address
    function disableDecay(address token) external;

    /// @notice Enable liability swaps for an asset (sets flag)
    /// @param token Token address
    function enableLiabilitySwap(address token) external;

    /// @notice Disable liability swaps for an asset (clears flag)
    /// @param token Token address
    function disableLiabilitySwap(address token) external;

    /// @notice Update hook contract for an asset
    /// @param token Token address
    /// @param hookAddress New hook contract address (address(0) = disabled)
    function updateHooks(
        address token,
        address hookAddress
    ) external;

    /// @notice Get hook contract for an asset
    /// @param token Token address
    /// @return hookAddress Current hook contract address
    function getHooks(address token) external view returns (address hookAddress);


    // ========== GUARDIAN FUNCTIONS ==========

    /// @notice Update oracle data for an asset (internal oracle only)
    /// @param token Token address
    /// @param newPrice New spot price in base token terms (b64 encoded - decodes to 1e18 internally)
    /// @param newVolEMA New volatility measurement (base 1e6: 1_000_000 = 1%)
    /// @dev Updates both fast and slow EMAs internally
    function updateOracle(
        address token,
        uint64 newPrice,
        uint32 newVolEMA
    ) external;

    /// @notice Update liquidity profile for an asset
    /// @param token Token address
    /// @param profile New liquidity profile configuration
    function updateLiquidityProfile(
        address token,
        LiquidtyConfig calldata profile
    ) external;

    /// @notice Trigger circuit breaker to freeze an asset
    /// @dev Guardian performs ALL deviation analysis off-chain before calling
    /// @dev This function only freezes the asset - no on-chain validation
    /// @param token Token to freeze
    /// @return triggered Whether circuit breaker was triggered (always true if referenceAsset configured)
    function checkCircuitBreaker(address token) external returns (bool triggered);

    /// @notice Add address to blacklist (guardian)
    /// @param account Address to blacklist
    function blacklistAddress(address account) external;

    /// @notice Remove address from blacklist (owner or guardian)
    /// @param account Address to remove from blacklist
    function removeFromBlacklist(address account) external;

    /// @notice Check if address is blacklisted
    /// @param account Address to check
    /// @return true if blacklisted
    function isBlacklisted(address account) external view returns (bool);

    // ========== TREASURY FUNCTIONS ==========

    /// @notice Collect accrued protocol fees
    /// @dev Only callable by treasury role
    /// @param tokens Array of token addresses to collect fees from
    function collectProtocolFees(address[] calldata tokens) external;
}
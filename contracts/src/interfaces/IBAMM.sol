// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IBAMM
/// @notice Interface for the BTR AMM (Bayesian True Range AMM) protocol
/// @dev Defines all external functions and events for the AMM
interface IBAMM {
    // ========== CONFIGURATION STRUCTS ==========

    /// @notice Liquidity profile parameters (for updates only)
    struct LiquidityProfileParams {
        uint8[16] segmentWeights;   // Liquidity weights for each segment
        int8[17] twapOffsets;       // Price offset points base 100
        uint64 minBreadth;          // Min breadth at volatility=0
        uint64 maxBreadth;          // Max breadth at volatility=100_000_000
    }

    /// @notice Liquidity configuration (ALM model - no target weights)
    struct LiquidityConfig {
        uint128 minLiquidity;       // Minimum required liquidity
        uint8 segmentCount;         // Number of segments (2-16)
        uint8[16] segmentWeights;   // Liquidity weights for each segment
        int8[17] twapOffsets;       // Price offset points base 100
        uint64 minBreadth;          // Min breadth at volatility=0
        uint64 maxBreadth;          // Max breadth at volatility=100_000_000
    }

    /// @notice Oracle configuration
    struct OracleConfig {
        address mainOracle;         // Main oracle (address(this)=internal, else=external IOracle)
        address fallbackOracle;     // Fallback oracle (address(0)=disabled, address(this)=internal)
        uint16 maxTWAPChange;       // Max price change per update in bps (e.g., 1000 = 10%)
        uint32 fastWindow;          // Fast TWAP window in seconds (e.g., 6 hours = 21600)
        uint32 slowWindow;          // Slow TWAP window in seconds (e.g., 7 days = 604800)
        bytes extension;            // Internal oracle init: abi.encode(uint64 currentPrice, uint32 fastVol, uint32 slowVol)
    }

    /// @notice Fee configuration (per-asset)
    struct FeeConfig {
        uint16 minFeeBps;           // Minimum swap fee in bps (e.g., 1 = 0.01%)
        uint16 maxFeeBps;           // Maximum swap fee in bps (e.g., 500 = 5%)
        uint16 protocolFeeBps;      // Protocol fee in bps (e.g., 1000 = 10% of swap fees)
        uint16 depositFeeBps;       // Deposit fee in bps (default 0, for LP arbitrage mitigation)
        uint16 withdrawalFeeBps;    // Withdrawal fee in bps (default 0, for LP arbitrage mitigation)
    }

    /// @notice Circuit breaker configuration
    struct CircuitBreakerConfig {
        address referenceAsset;     // Reference asset to compare against (address(0) = disabled)
        uint16 maxDeviationBps;     // Max deviation in bps (e.g., 100 = 1% for stables, 300 = 3% for LSTs)
    }

    // ========== STRUCTS ==========

    /// @notice Core state for each asset (OPTIMIZED: 9 slots with liability tracking)
    /// @dev Oracle modes: internal-only (both=pool), external-only (both=external), hybrid (mix)
    /// @dev Packing strategy groups fields by size to minimize storage slots
    /// @dev Coverage ratio = (reserves * price) / (liabilities * price) = reserves / liabilities
    struct Asset {
        // SLOT 1: uint128 + uint128 = 32 bytes
        uint128 reserves;              // Physical tokens in pool (assets)
        uint128 liabilities;           // Total deposited amount (LP claims in token units, Wombat-style)

        // SLOT 2: uint256 = 32 bytes
        uint256 priceAccumulator;      // Σ(price_i × Δt_i) - cumulative price-seconds in b64 format

        // SLOT 3: uint256 = 32 bytes
        uint256 fastAccumSnapshot;     // Accumulator value at last fast snapshot

        // SLOT 4: uint256 = 32 bytes
        uint256 slowAccumSnapshot;     // Accumulator value at last slow snapshot

        // SLOT 5: uint64 + 6×uint32 = 32 bytes
        uint64 currentPrice;           // Current spot price in b64 format (updated each oracle call)
        uint32 fastSnapshotTime;       // Timestamp when fast snapshot was taken
        uint32 slowSnapshotTime;       // Timestamp when slow snapshot was taken
        uint32 fastWindow;             // Fast TWAP window in seconds (e.g., 6 hours = 21600)
        uint32 slowWindow;             // Slow TWAP window in seconds (e.g., 7 days = 604800)
        uint32 fastVolatility;         // Fast volatility EMA (1e6 base, smoothing parameter)
        uint32 slowVolatility;         // Slow volatility EMA (1e6 base, smoothing parameter, determines base fee)

        // SLOT 6: address + uint32 + uint8 + uint8 + bool = 27 bytes
        address mainOracle;            // Main oracle (address(this)=internal, else=external IOracle)
        uint32 lastOracleUpdate;       // Timestamp of last oracle update
        uint8 decimals;                // Token decimals (6, 8, 18, etc.)
        uint8 segmentCount;            // Active segments (2-16)
        bool isFrozen;                 // If true, only withdrawals allowed

        // SLOT 7: address + 6×uint16 = 32 bytes
        address fallbackOracle;        // Fallback oracle (address(0)=disabled, address(this)=internal)
        uint16 minFeeBps;              // Minimum swap fee for this asset (basis points)
        uint16 maxFeeBps;              // Maximum swap fee for this asset (basis points)
        uint16 protocolFeeBps;         // Protocol fee as % of swap fees (basis points, e.g., 1000 = 10%)
        uint16 depositFeeBps;          // Deposit fee in bps (default 0, for LP arbitrage mitigation)
        uint16 withdrawalFeeBps;       // Withdrawal fee in bps (default 0, for LP arbitrage mitigation)
        uint16 maxTWAPChange;          // Max price change per update in bps (e.g., 1000 = 10%)

        // SLOT 8: address = 20 bytes
        address hooks;                 // Hook contract implementing IBAMMHooks interface

        // SLOT 9: uint128 = 16 bytes
        uint128 minLiquidity;          // Minimum liquidity that must remain in pool
    }

    /// @notice Liquidity profile for piecewise bonding curve
    /// @dev N segments require N weights and N+1 price points
    /// @dev Price points are defined as EMA offsets (base 100: -100 to +100)
    /// @dev Breadth (distribution spread) scales with volatility
    struct LiquidityProfile {
        uint8[16] segmentWeights;     // Weight per segment/vector (sum=255)
        int8[17] twapOffsets;          // Price offset points, base 100 (0 = EMA price)
        uint64 minBreadth;            // Min breadth at volatility=0 (1e8 precision, e.g., 5000 = 0.005%)
        uint64 maxBreadth;            // Max breadth at volatility=100_000_000 (1e8 precision, e.g., 1000000 = 1%)
    }

    /// @notice LP token state for rebasing
    struct LPState {
        uint128 totalScaledSupply;    // Sum of scaled balances
        uint128 liquidityIndex;       // Rebasing multiplier (starts 1e18)
    }

    /// @notice Circuit breaker configuration (read by off-chain keeper)
    /// @dev ALL deviation checking is performed off-chain by keeper
    /// @dev Stablecoins: Keeper compares oracle prices directly (USDC vs DAI should be ~1:1)
    /// @dev Correlated assets: Keeper compares relative weekly price changes independently
    ///      Example: If WETH +5% over week and wstETH +2%, deviation = 3% (triggers at 3%+ for LSTs)
    /// @dev Volatile assets: Keeper uses same relative change methodology with higher thresholds
    struct CircuitBreaker {
        address referenceAsset;       // Reference asset to compare against (address(0) = disabled)
        uint16 maxDeviation;          // Max deviation in bps (100=1% stables, 300=3% LSTs, 3000=30% volatile)
    }

    /// @notice Fee components for transparency
    /// @dev For two-leg routes, totalFeeBps is the notional-weighted average across both legs
    struct FeeComponents {
        uint256 baseFee;
        uint256 volatilityMultiplier;
        uint256 inventoryMultiplier;
        uint256 divergenceMultiplier;
        uint256 exitInventoryDivergence;   // Exit-leg inventory divergence multiplier (hub routing)
        uint256 totalFeeBps;                // User-visible effective fee (single-leg or weighted avg)
        // Per-leg breakdown (populated for two-leg hub routes, 0 for single-leg)
        uint256 leg1FeeBps;                 // Fee for first leg (A→base)
        uint256 leg2FeeBps;                 // Fee for second leg (base→B)
        uint256 leg1Notional;               // Notional value of first leg
        uint256 leg2Notional;               // Notional value of second leg
    }

    // ========== EVENTS ==========

    event Swap(
        address indexed user,
        address indexed receiver,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeBps
    );

    event BatchSwap(
        address indexed user,
        address indexed receiver,
        address[] path,
        uint256[] amounts
    );

    event Deposit(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 lpTokensMinted
    );

    event Withdraw(
        address indexed user,
        address indexed token,
        uint256 lpTokensBurned,
        uint256 amountOut,
        uint256 withdrawalFeeBps
    );

    event OracleUpdate(
        address indexed token,
        uint64 fastTWAP,
        uint64 slowTWAP,
        uint32 fastVolatility,
        uint32 slowVolatility,
        address indexed keeper
    );

    event AssetFrozen(address indexed token, string reason);
    event AssetUnfrozen(address indexed token);
    event PoolPaused();
    event PoolUnpaused();
    event BaseAssetUpdated(address indexed oldBase, address indexed newBase);

    event AssetAdded(
        address indexed token,
        uint128 minLiquidity
    );

    event LiquidityProfileUpdated(
        address indexed token,
        uint8 segmentCount
    );

    event CircuitBreakerTriggered(
        address indexed token,
        int256 divergenceBps,
        uint256 timestamp
    );

    event MinLiquidityUpdated(
        address indexed token,
        uint128 oldMinLiquidity,
        uint128 newMinLiquidity
    );

    event OracleUpdated(
        address indexed token,
        address indexed mainOracle,
        address indexed fallbackOracle
    );

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
    ) external returns (uint256 amountOut);

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
    ) external returns (uint256[] memory amounts);

    /// @notice Deposit single asset and receive LP tokens
    /// @param token Token to deposit
    /// @param amount Amount to deposit
    /// @param minLpTokens Minimum LP tokens to receive
    /// @return lpTokens Amount of LP tokens minted
    function deposit(
        address token,
        uint256 amount,
        uint256 minLpTokens
    ) external returns (uint256 lpTokens);

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

    /// @notice Get LP state for a token
    /// @param token Token address
    /// @return LP state (totalScaledSupply and liquidityIndex)
    function lpStates(address token) external view returns (LPState memory);

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
    function getTotalValue() external view returns (uint256 tvl);

    // ========== ADMIN FUNCTIONS ==========

    /// @notice Add new asset to the pool
    /// @param token Token address
    /// @param liquidityConfig Liquidity and allocation configuration
    /// @param oracleConfig Oracle and TWAP window configuration
    /// @param feeConfig Fee bounds and protocol fee configuration
    /// @param circuitBreaker Circuit breaker configuration
    /// @dev For internal oracle (mainOracle == address(this)), extension must contain:
    ///      abi.encode(uint64 currentPrice, uint32 fastVol, uint32 slowVol)
    /// @dev For external oracle, extension is ignored and oracle is read on-chain (reverts if fails)
    function addAsset(
        address token,
        LiquidityConfig calldata liquidityConfig,
        OracleConfig calldata oracleConfig,
        FeeConfig calldata feeConfig,
        CircuitBreakerConfig calldata circuitBreaker
    ) external;

    /// @notice Update base denomination token
    /// @param newBaseAsset New base token address
    function updateBaseAsset(address newBaseAsset) external;

    /// @notice Pause entire pool
    function pausePool() external;

    /// @notice Unpause pool
    function unpausePool() external;

    /// @notice Emergency freeze specific asset (admin or guardian)
    /// @param token Token to freeze
    /// @param reason Reason for freezing
    function freezeAsset(address token, string calldata reason) external;

    /// @notice Unfreeze asset (admin or guardian)
    /// @param token Token to unfreeze
    function unfreezeAsset(address token) external;

    /// @notice Configure circuit breaker for an asset
    /// @param token Token to configure
    /// @param referenceAsset Reference asset to compare against (address(0) = disable check)
    /// @param maxDeviation Max deviation from reference in bps (e.g., 100 = 1%)
    function updateCircuitBreaker(
        address token,
        address referenceAsset,
        uint16 maxDeviation
    ) external;

    /// @notice Update minimum liquidity requirement for an asset
    /// @param token Token address
    /// @param newMinLiquidity New minimum liquidity amount
    function updateMinLiquidity(
        address token,
        uint128 newMinLiquidity
    ) external;

    /// @notice Update oracle configuration for an asset
    /// @param token Token address
    /// @param mainOracle Main oracle (address(this)=internal, else=external IOracle contract)
    /// @param fallbackOracle Fallback oracle (address(0)=disabled, address(this)=internal)
    function updateOracleConfig(
        address token,
        address mainOracle,
        address fallbackOracle
    ) external;

    /// @notice Update fee bounds for an asset
    /// @param token Token address
    /// @param minFeeBps New minimum fee in basis points
    /// @param maxFeeBps New maximum fee in basis points
    function updateAssetFeeBounds(
        address token,
        uint16 minFeeBps,
        uint16 maxFeeBps
    ) external;

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

    /// @notice Update volatility EMA weights
    /// @param fastWeight Weight for fast volatility (0-100, e.g., 90 = 90% old, 10% new)
    /// @param slowWeight Weight for slow volatility (0-100, e.g., 95 = 95% old, 5% new)
    /// @dev Price TWAPs use accumulator pattern (Uniswap V3 style), these weights only affect volatility smoothing
    /// @dev Conversion from half-life to weight: w = 100 * 0.5^(1/h)
    ///      Examples: h=7 → w≈90, h=14 → w≈95, h=10 → w≈93
    function updateVolatilityWeights(uint8 fastWeight, uint8 slowWeight) external;

    /// @notice Get current volatility EMA weights
    /// @return fastWeight Weight for fast volatility
    /// @return slowWeight Weight for slow volatility
    function getVolatilityWeights() external view returns (uint8 fastWeight, uint8 slowWeight);

    // ========== GUARDIAN FUNCTIONS ==========

    /// @notice Update oracle data for an asset (internal oracle only)
    /// @param token Token address
    /// @param newPrice New spot price in base token terms (B64 encoded - decodes to 1e18 internally)
    /// @param newVolatility New volatility measurement (base 1e6: 1_000_000 = 1%)
    /// @dev Updates both fast and slow EMAs internally
    function updateOracle(
        address token,
        uint64 newPrice,
        uint32 newVolatility
    ) external;

    /// @notice Update liquidity profile for an asset
    /// @param token Token address
    /// @param profile New liquidity profile configuration
    function updateLiquidityProfile(
        address token,
        LiquidityProfileParams calldata profile
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

    /// @notice Remove address from blacklist (admin or guardian)
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
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IErrors} from "./IErrors.sol";
import {ICoreV1} from "./modules/ICoreV1.sol";
import {IAdminV1} from "./modules/IAdminV1.sol";
import {IFlashV1} from "./modules/IFlashV1.sol";
import {ILendV1} from "./modules/ILendV1.sol";
import {IStakingV1} from "./modules/IStakingV1.sol";
import {IDistributorV1} from "./modules/IDistributorV1.sol";
import {IOracleV1} from "./IOracleV1.sol";
import {IRescueV1} from "./modules/IRescueV1.sol";

/// @title IPoolV1
/// @notice Adaptive Inventory Market Maker - Complete interface
/// @dev Consolidates structs, events, errors, and all module function signatures
interface IPoolV1 is IErrors, ICoreV1, IAdminV1, IFlashV1, ILendV1, IStakingV1, IDistributorV1, IOracleV1, IRescueV1 {
    // ========== STRUCTS ==========

    struct Asset {
        // Slot 1: Core financial state (256 bits)
        uint128 reserves;
        uint128 liabilities;

        // Slot 2: Liquidity parameters (256 bits)
        uint128 minLiquidity;
        uint64 liquidityIndex;
        uint32 lastUpdate;
        uint32 minDispersion;     // Minimum liquidity dispersion (0.0001% units)

        // Slot 3: Anchor tree + fee bounds (256 bits) - OPTIMIZED PACKING
        address anchor;              // Parent asset in pricing tree (160 bits)
        uint16 minFeeBps;            // Minimum asset fee (32 bits total for fees)
        uint16 maxFeeBps;            // Maximum asset fee
        uint32 maxDispersion;        // Maximum liquidity dispersion (32 bits)
        uint8 anchorDepth;           // Distance from root in tree (8 bits)
        uint8 decimals;              // Token decimals (8 bits)
        uint8[2] _pad1;              // Padding to 256 bits

        // Slot 4: Pricing sensitivities (256 bits)
        uint16 gamma;                // Inventory sensitivity: scales deviation → price offset (basis 10000, e.g., 5000 = 0.5x)
        uint16 vega;                 // Volatility sensitivity: scales volatility → dispersion (basis 10000)
        uint16 lambda;               // Deviation sensitivity: scales deviation → fee surcharge (basis 10000)
        uint16 haircutSuppressor;    // Withdrawal haircut suppressor: higher = gentler curve (basis 10000, e.g., 40000 = 4x)
        uint64 reservationPrice;     // Price floor vs anchor (B64 format) - swaps revert if price drops below
        uint8[16] _pad2;             // Reserved for future use
    }

    struct RiskConfig {
        uint16 decayStartRatioBps;     // Coverage threshold to start decay (0.0001% units, e.g., 980000 = 98%)
        uint16 coverageFloor;          // Critical coverage floor for inventory skew (0.0001% units, e.g., 500000 = 50%)
        uint32 decaySlope;             // Linear decay % per year (WAD units per second)
        uint16 depthAmplifier;         // Depth curve amplifier: higher = more depth at low coverage (0=default, else 0.0001% units)
        uint16 flags;                  // Feature flags (bit 0: swap, bit 1: flash, bit 2: liability swap)
        uint8[18] _pad;
    }

    struct LiquidityProfile {
        uint8[16] weights;      // First zero weight marks end of profile
        int8[17]  knots;        // Price offset knots as % of dispersion range around TWAP (knot=-50, dispersion=1% → -0.5% from TWAP)
    }

    struct OracleConfig {
        address primary;
        address secondary;
        bytes32 feedId;
        uint16 modeFlags;
        uint8 accDecimals;      // Accumulator decimals for internal oracle (6=stables, 12=ETH, 18=BTC)
        uint8[13] _pad;
    }

    struct FeeParams {
        uint8 protoShare;               // Protocol share of spread (percentage 0-100, e.g., 25 = 25%)
        uint16 flashFeeBps;             // Flash loan fee (0.0001% units)
        uint8[29] _pad;
    }

    struct SwapQuote {
        uint256 amountOut;
        uint256 amountIn;
        uint16 spreadBps;             // Bid-ask spread (0.0001% units)
        uint256 protoFee;             // Protocol fee portion
        uint256 lpFee;                // LP fee portion
        int8 skewIn;                  // Input asset inventory skew
        int8 skewOut;                 // Output asset inventory skew
        address[] routeHops;          // Full routing path for multi-hop swaps
        uint256[] hopAmounts;         // Amount at each hop (for oracle updates)
    }

    struct DepositResult {
        uint256 lpAmount;
        uint256 actualDeposit;
    }

    struct WithdrawResult {
        uint256 amountOut;
        uint256 lpBurned;
    }

    /// @notice Staking configuration parameters
    struct StakingConfig {
        uint48 stakeLockDuration;   // Default 14 days (2 weeks)
        uint48 transferCooldown;    // Cooldown after claim (default 14 days)
        uint16 minClaimPower;       // w_min in basis points (5000 = 50%)
        uint16 matchingRatio;       // BTR:LP matching ratio (500 = 5:1)
        bool stakingPaused;         // Emergency pause flag

        // Voting power formula: V = (L * lpBase / 10000) + (min(boosted, boostCap * G) * lpBoosted / 10000) + (G * govMultiplier / 10000)
        uint16 lpBaseMultiplier;    // Base LP multiplier in basis points (5000 = 0.5x = L/2)
        uint16 lpBoostedMultiplier; // Boosted LP multiplier in basis points (5000 = 0.5x)
        uint16 govMultiplier;       // Gov token multiplier in basis points (10000 = 1x = 1G)
        uint16 boostCap;            // Max LP that can be boosted per $1 BTR (50000 = 5x)
    }

    /// @notice Internal oracle accumulator data (per asset)
    /// @dev Stores TWAP accumulator state for pool-internal price tracking
    /// @dev Accumulators use B64 with configurable decimals for optimal range per asset class:
    ///      - Stables: accDecimals=6 (plenty of range for $1 prices)
    ///      - ETH-like: accDecimals=12 (medium range for ~$3k prices)
    ///      - BTC-like: accDecimals=18 (full range for ~$100k prices)
    struct FeedAccumulator {
        uint64 priceAccB64;         // Global price accumulator (B64, uses accDecimals)
        uint64 fastSnapB64;         // Fast TWAP snapshot accumulator (B64, uses accDecimals)
        uint64 slowSnapB64;         // Slow TWAP snapshot accumulator (B64, uses accDecimals)
        uint32 fastSnapshotTime;    // When fast snapshot was taken
        uint32 slowSnapshotTime;    // When slow snapshot was taken
        uint64 lastPriceB64;        // Last recorded spot price (B64, uses token decimals)
        int32 fastOffset;           // Fast TWAP offset from spot (0.0001% units)
        int32 slowOffset;           // Slow TWAP offset from spot (0.0001% units)
        uint32 lastUpdate;          // Last update timestamp
        uint32 fastVolEMA;          // Fast volatility EMA (1e6 base)
        uint32 slowVolEMA;          // Slow volatility EMA (1e6 base)
        uint16 ttl;                 // Time-to-live (seconds)
        uint8 accDecimals;          // Accumulator encoding decimals (set at init, not token decimals)
        uint8 confidence;           // Confidence level (0-100)
    }

    /// @notice Routing path through anchor tree
    /// @dev Computed via LCA algorithm for each swap
    /// @dev Only hops array is needed - lcaIndex and isDirectAnchor never read
    struct RoutePath {
        address[] hops;             // Full path: [tokenIn, ..., LCA, ..., tokenOut]
    }

    /// @notice Timelock operation types
    enum OpType {
        NONE,
        TRANSFER_OWNERSHIP,
        UPDATE_MODULE,
        MIGRATE_BASE_TOKEN,
        UPDATE_ORACLE,
        UPDATE_STAKING,
        UPDATE_DISTRIBUTION,
        ADD_ASSET,
        UPDATE_RISK,
        UPDATE_FEES,
        UPDATE_BRIDGE,
        UPDATE_TREASURY
    }


    /// @notice Oracle storage for internal TWAP tracking
    /// @dev Separate ERC-7201 namespace from PoolStorage
    struct OracleStorage {
        mapping(address token => FeedAccumulator) accumulators;
    }

    /// @notice Flow guard storage for JIT protection
    /// @dev Separate ERC-7201 namespace - tracks deposit/stake timestamps per user
    /// @dev Protects against same-block or short-timeframe deposit→withdraw and stake→unstake attacks
    struct FlowGuardStorage {
        /// @notice Last deposit timestamp per user per asset (for deposit→withdraw cooldown)
        mapping(address user => mapping(address asset => uint32)) lastDepositTime;
        /// @notice Last gov stake timestamp per user (for stakeGov→unstakeGov cooldown)
        mapping(address user => uint32) lastGovStakeTime;
        /// @notice Last LP stake timestamp per user per LP token (for stakeLP→unstakeLP cooldown)
        mapping(address user => mapping(address lpToken => uint32)) lastLPStakeTime;
    }

    /// @notice ERC-7201 namespaced storage for AIMM
    /// @dev All modules access this same storage layout via ERC-7201 pattern
    struct PoolStorage {
        address owner;
        address baseToken;
        address wnative;
        address bridge;    // Authorized crosschain bridge contract
        address treasury;  // Protocol treasury (only address that can collect protocol fees)
        bool initialized;
        // Note: reentrancyGuard removed - now using transient storage (EIP-1153) in BaseV1.sol

        mapping(address => IPoolV1.Asset) assets;
        mapping(address => IPoolV1.OracleConfig) oracleConfigs;
        mapping(address => IPoolV1.RiskConfig) riskConfigs;
        mapping(address => IPoolV1.LiquidityProfile) profiles;
        mapping(address => address) hooks;
        mapping(address => uint32) hookFlags;
        mapping(address => mapping(address => uint256)) lpBalances;
        mapping(address => uint256) protocolFees;
        mapping(bytes4 => address) modules; // Diamond-lite selector registry

        IPoolV1.FeeParams feeParams;

        // Flow guard cooldown (JIT protection)
        uint16 flowCooldownSeconds;  // Cooldown between deposit→withdraw and stake→unstake (default 15s)

        // Timelock governance (ultra-compact)
        mapping(bytes32 => uint96) pendingOps;   // Packed: [48b executeAt][48b grace]
        mapping(bytes32 => bytes) pendingData;   // Operation data

        // ═══════════════════════════════════════════════════════════════════════════
        // STAKING
        // ═══════════════════════════════════════════════════════════════════════════

        // Governance token (instance-specific; BTR in protocol-curated pool)
        address govToken;           // Governance token ERC20 address
        address sGovToken;          // Staked governance token ERC20 address

        // Staking configuration (shared between Staking and Distributor)
        StakingConfig stakingConfig;

        // LP staking balances (shared between Staking and Distributor for rewards)
        mapping(address user => mapping(address lpToken => uint256)) lpStaked;
        mapping(address lpToken => uint256) totalLPStaked;

        // ═══════════════════════════════════════════════════════════════════════════
        // ANCHOR TREE
        // ═══════════════════════════════════════════════════════════════════════════

        // Note: No route caching - recomputing paths is cheaper for shallow trees
    }

    // ========== EVENTS ==========

    event PoolInitialized(address indexed owner, address indexed baseToken, address indexed wnative);

    // ========== ERRORS ==========
    // All common errors inherited from IErrors - see IErrors.sol for details

    // ========== INITIALIZATION ==========

    function initialize(address owner, address baseToken, address wnative) external;

    // ========== VIEW FUNCTIONS ==========

    function owner() external view returns (address);
    function baseToken() external view returns (address);
    function wnative() external view returns (address);
    function getAsset(address token) external view returns (Asset memory);
    function getFeedConfig(address token) external view returns (OracleConfig memory);
    function getRiskConfig(address token) external view returns (RiskConfig memory);
    function getLiquidityProfile(address token) external view returns (LiquidityProfile memory);
    function getLPBalance(address user, address token) external view returns (uint256);
    function getProtocolFees(address token) external view returns (uint256);
    function getCoverageRatio(address token) external view returns (uint256);
    function getMidPrice(address token) external returns (uint256 midPrice);
}


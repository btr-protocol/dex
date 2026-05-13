// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IOracle} from "./IOracle.sol";

/// @title IPool -Adaptive Inventory Market Maker (aggregate, canonical surface)
/// @dev Phase 42H.B.3c -IFlash + IDistributor removed from inheritance; both are now
///      standalone singletons with pool-keyed APIs (see /interfaces/IFlash.sol +
///      /interfaces/IDistributor.sol).
/// @dev Cohort-3 Finding 3 -Pool module events + view sigs folded into this root
///      `IPool` as the single canonical declaration. Wave-5 (Cohort-4 N6): dead
///      module aliases (`interfaces/modules/{IPool,ILiquidity,ICore}.sol`) removed.
///      `interfaces/modules/IExchange.sol` retained -still consumed by Router.
interface IPool is IOracle {
    struct Asset {
        uint128 reserves;
        uint128 liabilities;
        uint128 minLiquidity;
        uint64 liquidityIndex;
        uint32 lastUpdate;
        uint32 minDispersion;
        address anchor;
        uint16 minFeeBps;
        uint16 maxFeeBps;
        uint32 maxDispersion;
        uint8 anchorDepth;
        uint8 decimals;
        uint8[2] _pad1;
        uint16 gamma;
        uint16 vega;
        uint16 lambda;
        uint16 haircutSuppressor;
        uint64 reservationPrice;
        uint8[16] _pad2;
    }

    struct RiskConfig {
        uint16 decayStartRatioBps;
        uint16 coverageMin;
        uint16 coverageMax;
        uint32 decaySlope;
        uint16 depthAmplifier;
        uint16 flags;
        uint8[16] _pad;
    }

    struct LiquidityProfile {
        uint8[16] weights;
        int8[17]  knots;
    }

    struct OracleConfig {
        address primary;
        address secondary;
        bytes32 feedId;
        uint16 modeFlags;
        uint8 accDecimals;
        uint8[13] _pad;
    }

    struct FeeParams {
        uint8 protoShare;
        uint16 flashFeeBps;
        uint8[29] _pad;
    }

    struct DepositResult { uint256 lpAmount; uint256 actualDeposit; }
    struct WithdrawResult { uint256 amountOut; uint256 lpBurned; }

    struct StakingConfig {
        uint48 stakeLockDuration;
        uint48 transferCooldown;
        uint16 minClaimPower;
        uint16 matchingRatio;
        bool stakingPaused;
        uint16 lpBaseMultiplier;
        uint16 lpBoostedMultiplier;
        uint16 govMultiplier;
        uint16 boostCap;
    }

    /// @dev accDecimals: 6=stables, 12=ETH-like, 18=BTC-like
    struct FeedAccumulator {
        uint64 priceAccB64;
        uint64 fastSnapB64;
        uint64 slowSnapB64;
        uint32 fastSnapshotTime;
        uint32 slowSnapshotTime;
        uint64 lastPriceB64;
        int32 fastOffset;
        int32 slowOffset;
        uint32 lastUpdate;
        uint32 fastVolEMA;
        uint32 slowVolEMA;
        uint16 ttl;
        uint8 accDecimals;
        uint8 confidence;
    }

    struct RoutePath { address[] hops; }

    enum OpType {
        NONE,
        TRANSFER_OWNERSHIP,
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

    /// @dev Phase 42H.B.3d -ERC-7201 indirection dropped. Pool storage is now plain
    ///      state vars at slot 0+. PoolStorage struct moved into Pool.sol as a
    ///      single instance variable for library compat (Pricing/AnchorTree pass-by-ref).
    /// @dev Dead-state from earlier phases removed: govToken/sGovToken/stakingConfig/
    ///      lpStaked/totalLPStaked/modules/pendingOps/pendingData/owner.
    struct PoolStorage {
        address baseToken;
        address wnative;
        address bridge;
        address treasury;
        bool initialized;
        mapping(address => IPool.Asset) assets;
        mapping(address => IPool.OracleConfig) oracleConfigs;
        mapping(address => IPool.RiskConfig) riskConfigs;
        mapping(address => IPool.LiquidityProfile) profiles;
        mapping(address => address) hooks;
        mapping(address => uint32) hookFlags;
        mapping(address => mapping(address => uint256)) lpBalances;
        mapping(address => uint256) protocolFees;
        IPool.FeeParams feeParams;
        uint16 flowCooldownSeconds;
        // Oracle accumulators (was: OracleStorage @ ORACLE_STORAGE_LOC).
        mapping(address token => FeedAccumulator) accumulators;
        // Flow-guard cooldown timestamps (was: FlowGuardStorage @ FLOW_GUARD_STORAGE_LOC).
        mapping(address user => mapping(address asset => uint32)) lastDepositTime;
        mapping(address user => mapping(address lpToken => uint32)) lastLPStakeTime;
        // Phase 42J.4 (F4) -TWAP poisoning defense. One accumulator update per
        // token per block; subsequent in-block pushes early-return as no-op.
        mapping(address token => uint256 blockNum) lastUpdateBlock;
    }

    event PoolInitialized(address indexed owner, address indexed baseToken, address indexed wnative);

    function initialize(address baseToken, address wnative, FeeParams calldata feeParams) external;

    // ── Phase 42H.B.3a: restricted setters gated by `admin` singleton ──
    function adminFreezeAsset(address token) external;
    function adminUnfreezeAsset(address token) external;
    function adminInitAsset(
        address token,
        OracleConfig calldata oracleCfg,
        RiskConfig calldata riskCfg,
        LiquidityProfile calldata profile,
        uint16 minFeeBps,
        uint8 decimals,
        uint64 initialPrice,
        uint32 initialFastVolEMA,
        uint32 initialSlowVolEMA,
        uint32 minDispersion,
        uint32 maxDispersion,
        uint16 gamma,
        uint16 vega,
        uint16 lambda
    ) external;
    function adminCollectProtocolFees(address token, address recipient) external returns (uint256);
    function adminSetFlowCooldown(uint16 cooldownSeconds) external;
    function adminSetAnchor(address token, address anchor) external;
    function adminSetAssetParams(
        address token,
        uint128 minLiquidity,
        uint16 minFeeBps,
        uint16 maxFeeBps,
        uint16 gamma,
        uint16 vega,
        uint16 lambda,
        uint16 haircutSuppressor,
        uint64 reservationPrice
    ) external;
    function adminSetRiskConfig(address token, RiskConfig calldata cfg) external;
    function adminSetOracleConfig(address token, OracleConfig calldata cfg) external;
    function adminSetFeeParams(FeeParams calldata params) external;
    function adminSetBridge(address newBridge) external;
    function adminSetTreasury(address newTreasury) external;
    function adminSetBaseToken(address newBase) external;

    // ── Phase 42H.B.3b: restricted setter gated by `staking` singleton ──
    function stakingAdjustLpBalance(address user, address token, int256 delta) external;

    // ── Phase 42H.B.3c: restricted setters gated by `flash` singleton ──
    function flashSend(address token, uint256 amount, address to) external;
    function flashAccount(address token, uint256 fee, uint256 protoFee) external;

    // ── views consumed by Staking + Flash singletons ──
    function getAsset(address token) external view returns (Asset memory);
    function getLPBalance(address user, address token) external view returns (uint256);
    function getRiskFlags(address token) external view returns (uint16);
    function getFeeParams() external view returns (FeeParams memory);
    function getHookForFlag(address token, uint32 flag) external view returns (address);

    // ─── Exchange types & events (canonical -was IPoolModule) ────────────────
    struct SwapQuote {
        uint256 amountOut;
        uint256 amountIn;
        uint16 spreadBps;
        uint256 protoFee;
        uint256 lpFee;
        int8 skewIn;
        int8 skewOut;
        address[] routeHops;
        uint256[] hopAmounts;
        uint64[] hopPrices;
    }

    event Swapped(
        address indexed sender,
        address indexed recipient,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint16 spreadBps,
        uint256 protoFee,
        uint256 lpFee
    );

    event BatchSwapped(
        address indexed sender,
        address indexed recipient,
        uint256 inputCount,
        uint256 outputCount,
        uint256 totalBaseValue
    );

    // ─── Liquidity events (canonical) ────────────────────────────────────────
    event Deposited(address indexed sender, address indexed token, uint256 amount, uint256 lpAmount);
    event Withdrawn(address indexed sender, address indexed token, uint256 amount, uint256 lpAmount);
    event LiabilitySwapped(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 lpAmountIn,
        uint256 lpAmountOut,
        uint256 haircut
    );
    event Donated(address indexed sender, address indexed token, uint256 amount);

    // ─── Exchange functions ──────────────────────────────────────────────────
    function owner() external view returns (address);
    function baseToken() external view returns (address);
    function wnative() external view returns (address);
    function getCoverageRatio(address token) external view returns (uint256);

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external payable returns (uint256 amountOut);

    /// @notice Batch swap (≤8 in, ≤8 out)
    function batchSwap(bytes calldata inputs, bytes calldata outputs, address recipient)
        external payable returns (uint256[] memory amountsOut);

    function getSwapQuote(address tokenIn, address tokenOut, uint256 amountIn)
        external view returns (SwapQuote memory quote);

    function getProtocolFees(address token) external view returns (uint256);
    /// @notice Pure view of last cached price (no oracle dispatch).
    function midPrice(address token) external view returns (uint256);
    /// @notice Refresh-then-read; mutates accumulators (keeper-callable).
    function pokeMidPrice(address token) external returns (uint256);

    // ─── Liquidity functions ─────────────────────────────────────────────────
    function deposit(address token, uint256 amount)
        external payable returns (DepositResult memory result);

    function withdraw(address token, uint256 lpAmount, uint256 minAmountOut)
        external returns (WithdrawResult memory result);

    /// @notice Withdraw LP for different asset (swaps via internal quote)
    function withdrawTo(address tokenFrom, address tokenTo, uint256 lpAmount, uint256 minAmountOut)
        external returns (WithdrawResult memory result);

    /// @notice Swap LP between assets (changes liability exposure)
    function swapLiability(address tokenIn, address tokenOut, uint256 lpAmountIn, uint256 minLpAmountOut)
        external returns (uint256 lpAmountOut);

    /// @notice Donate reserves w/o LP mint (raises liquidity index)
    function donate(address token, uint256 amount) external payable;

    /// @notice LP preview: returns (amountOut, haircut) for `lp` shares of `token`.
    function previewWithdraw(address token, uint256 lp) external view returns (uint256 amountOut, uint256 haircut);
}

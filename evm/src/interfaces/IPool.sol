// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IExchange} from "./modules/IExchange.sol";
import {ILiquidity} from "./modules/ILiquidity.sol";
import {IAdmin} from "./modules/IAdmin.sol";
import {IFlash} from "./modules/IFlash.sol";
import {IStaking} from "./modules/IStaking.sol";
import {IDistributor} from "./modules/IDistributor.sol";
import {IOracle} from "./IOracle.sol";

/// @title IPool — Adaptive Inventory Market Maker (aggregate)
interface IPool is IExchange, ILiquidity, IAdmin, IFlash, IStaking, IDistributor, IOracle {
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

    struct OracleStorage {
        mapping(address token => FeedAccumulator) accumulators;
    }

    struct FlowGuardStorage {
        mapping(address user => mapping(address asset => uint32)) lastDepositTime;
        mapping(address user => uint32) lastGovStakeTime;
        mapping(address user => mapping(address lpToken => uint32)) lastLPStakeTime;
    }

    /// @dev ERC-7201 namespaced storage shared across modules
    struct PoolStorage {
        address owner;
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
        mapping(bytes4 => address) modules;
        IPool.FeeParams feeParams;
        uint16 flowCooldownSeconds;
        mapping(bytes32 => uint96) pendingOps;
        mapping(bytes32 => bytes) pendingData;
        address govToken;
        address sGovToken;
        StakingConfig stakingConfig;
        mapping(address user => mapping(address lpToken => uint256)) lpStaked;
        mapping(address lpToken => uint256) totalLPStaked;
        /// @dev Path α — peripheral AccessControl singleton. When non-zero, owner() reads
        ///      delegate to IAccessControl(ac).owner() enabling atomic multisig rotation
        ///      across alm + dex. Zero = legacy per-pool $.owner path. Append-only (ERC-7201).
        address ac;
    }

    event PoolInitialized(address indexed owner, address indexed baseToken, address indexed wnative);

    function initialize(address owner, address baseToken, address wnative) external;
}

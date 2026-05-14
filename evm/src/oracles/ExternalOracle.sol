// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IOracle} from "../interfaces/IOracle.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as C} from "../libraries/Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";

/// @title ExternalOracle
/// @notice Push-based external oracle with dual TWAP (fast/slow) and volatility tracking
contract ExternalOracle is IOracle {
    /// @notice Shared singleton AccessControl -single source of truth for owner.
    address public immutable AC;
    // ─── constants ───
    uint32 public constant MAX_VOLATILITY = 100 * uint32(SC.PBPS);
    /// @dev Phase 42D A4-5 DISCARD (by-design): event-only enforcement. The on-chain code does
    ///      NOT check deviation against this threshold; deviation checks are done off-chain by the
    ///      oracle pusher pre-push. The constant is a UX hint emitted via `FeedAdded.maxDeviation`
    ///      so integrators understand what the off-chain pusher's policy is. Integrators MUST NOT
    ///      treat this as an on-chain safety guarantee -only as a published policy.
    uint16 public constant MAX_DEV_THRESHOLD = 65_000; // 6.5% in SC.BPS precision (off-chain hint)
    uint16 public constant DEFAULT_TTL = 3600;

    // ─── storage ───
    mapping(address => bool) public oracles;
    mapping(bytes32 => FeedData) private feeds;
    bytes32[] public feedIds;

    // ─── events ───
    event FeedAdded(
        bytes32 indexed feedId,
        address indexed base,
        address indexed quote,
        uint64 fastEMA,
        uint64 slowEMA,
        uint32 fastVolEMA,
        uint32 slowVolEMA,
        uint16 maxDeviation
    );
    event FeedUpdated(bytes32 indexed feedId, uint16 maxDeviation, uint16 ttl);
    event Pushed(
        bytes32 indexed feedId,
        uint64 fastEMA,
        uint64 slowEMA,
        uint32 fastVolEMA,
        uint32 slowVolEMA,
        address indexed pusher
    );
    event BatchPushed(bytes32[] feedIds, address indexed pusher);
    event OracleGranted(address indexed oracle);
    event OracleRevoked(address indexed oracle);

    // ─── modifiers ───
    modifier onlyOracle() {
        if (!oracles[msg.sender]) revert Ownable.Unauthorized();
        _;
    }

    /// @notice AC-singleton ownership gate. Mirrors Distributor.sol:40 pattern.
    modifier onlyAdmin() {
        if (msg.sender != AccessControl(AC).owner()) revert Ownable.Unauthorized();
        _;
    }

    constructor(address ac_, address oracle_) {
        if (ac_ == address(0) || oracle_ == address(0)) revert Err.ZeroValue();
        AC = ac_;
        oracles[oracle_] = true;
        emit OracleGranted(oracle_);
    }

    // ─── owner ───
    function addFeed(
        address base,
        address quote,
        uint64 fastEMA,
        uint64 slowEMA,
        uint32 fastVolEMA,
        uint32 slowVolEMA,
        uint16 maxDeviation,
        uint16 ttl
    ) external onlyAdmin {
        if (base == address(0) || quote == address(0)) revert Err.ZeroValue();
        _validate(fastEMA, slowEMA, fastVolEMA, slowVolEMA);
        if (maxDeviation > MAX_DEV_THRESHOLD || ttl == 0) revert Err.InvalidInput();

        bytes32 feedId = keccak256(abi.encodePacked(base, quote));
        if (feeds[feedId].updatedAt != 0) revert Err.FeedAlreadyExists(feedId);

        feeds[feedId] = FeedData({
            lastPriceB64: fastEMA,
            fastOffset: 0,
            slowOffset: 0,
            fastVolEMA: fastVolEMA,
            slowVolEMA: slowVolEMA,
            updatedAt: uint32(block.timestamp),
            ttl: ttl,
            confidence: 100
        });
        feedIds.push(feedId);
        emit FeedAdded(feedId, base, quote, fastEMA, slowEMA, fastVolEMA, slowVolEMA, maxDeviation);
    }

    function updateFeed(bytes32 feedId, uint16 maxDeviation, uint16 ttl) external onlyAdmin {
        if (feeds[feedId].updatedAt == 0) revert Err.FeedNotFound(feedId);
        if (maxDeviation > MAX_DEV_THRESHOLD || ttl == 0) revert Err.InvalidInput();
        feeds[feedId].ttl = ttl;
        // NB: maxDeviation event-only; deviation checks done off-chain pre-push
        emit FeedUpdated(feedId, maxDeviation, ttl);
    }

    function grantOracle(address oracle) external onlyAdmin {
        if (oracle == address(0)) revert Err.ZeroValue();
        oracles[oracle] = true;
        emit OracleGranted(oracle);
    }

    function revokeOracle(address oracle) external onlyAdmin {
        oracles[oracle] = false;
        emit OracleRevoked(oracle);
    }

    // ─── oracle ───
    /// @dev F-A3-R14-1 (R14 LOW, DESIGN-DISCARDED): on-chain `maxDeviation` is event-only
    ///      (see `updateFeed`); deviation enforcement is delegated to the off-chain oracle key
    ///      pipeline pre-push. An oracle-key compromise can therefore push arbitrary EMAs
    ///      subject only to `_validate` (non-zero, vol < MAX_VOLATILITY). Mitigation lives
    ///      in oracle-key governance + off-chain monitoring + revokeOracle. Adding an on-chain
    ///      bound would change the push-based design + couple oracle latency to the latest
    ///      committed snapshot, which conflicts with the multi-source aggregation contract.
    function pushFeed(
        bytes32 feedId,
        uint64 newFastEMA,
        uint64 newSlowEMA,
        uint32 newFastVolEMA,
        uint32 newSlowVolEMA
    ) external onlyOracle {
        _pushInternal(feedId, newFastEMA, newSlowEMA, newFastVolEMA, newSlowVolEMA);
        emit Pushed(feedId, newFastEMA, newSlowEMA, newFastVolEMA, newSlowVolEMA, msg.sender);
    }

    function batchPush(
        bytes32[] calldata _feedIds,
        uint64[] calldata fastEMAs,
        uint64[] calldata slowEMAs,
        uint32[] calldata fastVolEMAs,
        uint32[] calldata slowVolEMAs
    ) external onlyOracle {
        uint256 length = _feedIds.length;
        if (
            length == 0 ||
            fastEMAs.length != length ||
            slowEMAs.length != length ||
            fastVolEMAs.length != length ||
            slowVolEMAs.length != length
        ) revert Err.InvalidInput();

        for (uint256 i; i < length;) {
            _pushInternal(_feedIds[i], fastEMAs[i], slowEMAs[i], fastVolEMAs[i], slowVolEMAs[i]);
            unchecked { ++i; }
        }
        emit BatchPushed(_feedIds, msg.sender);
    }

    // ─── internal ───
    function _validate(uint64 fastEMA, uint64 slowEMA, uint32 fastVol, uint32 slowVol) internal pure {
        if (fastEMA == 0 || slowEMA == 0) revert Err.ZeroValue();
        if (fastVol > MAX_VOLATILITY || slowVol > MAX_VOLATILITY) {
            revert Err.ThresholdViolation(fastVol > slowVol ? fastVol : slowVol, MAX_VOLATILITY);
        }
    }

    function _pushInternal(
        bytes32 feedId,
        uint64 newFastEMA,
        uint64 newSlowEMA,
        uint32 newFastVolEMA,
        uint32 newSlowVolEMA
    ) internal {
        FeedData storage feed = feeds[feedId];
        if (feed.updatedAt == 0) revert Err.FeedNotFound(feedId);
        _validate(newFastEMA, newSlowEMA, newFastVolEMA, newSlowVolEMA);

        feed.lastPriceB64 = newFastEMA;
        feed.fastOffset = 0;
        if (newSlowEMA >= newFastEMA) {
            uint256 delta = uint256(newSlowEMA - newFastEMA);
            feed.slowOffset = int16(uint16(delta > type(uint16).max ? type(uint16).max : delta));
        } else {
            uint256 delta = uint256(newFastEMA - newSlowEMA);
            feed.slowOffset = -int16(uint16(delta > type(uint16).max ? type(uint16).max : delta));
        }
        feed.fastVolEMA = newFastVolEMA;
        feed.slowVolEMA = newSlowVolEMA;
        feed.updatedAt = uint32(block.timestamp);
        feed.confidence = 100;
    }

    // ─── IOracle ───
    function getFeed(bytes32 feedId) external view override returns (FeedData memory data) {
        data = feeds[feedId];
        if (data.updatedAt == 0) revert Err.FeedNotFound(feedId);
    }

    function isFeedFresh(bytes32 feedId, uint32 maxAge) external view override returns (bool) {
        FeedData storage f = feeds[feedId];
        if (f.updatedAt == 0) return false;
        unchecked { return block.timestamp - f.updatedAt <= maxAge; }
    }

    function isFeedFresh(bytes32 feedId) external view override returns (bool) {
        FeedData storage f = feeds[feedId];
        if (f.updatedAt == 0) return false;
        unchecked { return block.timestamp - f.updatedAt <= f.ttl; }
    }

    function getFastEMA(bytes32 feedId) external view override returns (uint64) {
        FeedData storage f = feeds[feedId];
        if (f.updatedAt == 0) revert Err.FeedNotFound(feedId);
        return f.lastPriceB64;
    }

    // ─── views ───
    function getFeedIds() external view returns (bytes32[] memory) { return feedIds; }
    function getFeedCount() external view returns (uint256) { return feedIds.length; }
    function hasFeed(bytes32 feedId) external view returns (bool) { return feeds[feedId].updatedAt != 0; }
    function isOracle(address account) external view returns (bool) { return oracles[account]; }
}

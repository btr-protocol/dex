// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOracleV1} from "../interfaces/IOracleV1.sol";
import {IErrors} from "../interfaces/IErrors.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";

/// @title ExternalOracle
/// @notice Push-based external oracle with dual TWAP (fast/slow) and volatility tracking
/// @dev Implements IOracle interface with single-slot FeedData storage
contract ExternalOracle is IOracleV1 {
    // ========== ERRORS ==========
    // Common errors inherited from IErrors:
    // - ZeroPrice(), VolatilityTooHigh(), InvalidDeviation()

    error Unauthorized();
    error FeedNotFound(bytes32 feedId);
    error FeedAlreadyExists(bytes32 feedId);

    // ========== CONSTANTS ==========

    /// @notice Maximum allowed volatility (100% = 100_000_000 in 1e6 base)
    uint32 public constant MAX_VOLATILITY = 100_000_000;

    /// @notice Maximum deviation threshold (6.5% = 65_000 in 0.0001% precision)
    uint16 public constant MAX_DEV_THRESHOLD = 65_000;

    /// @notice Deviation precision (0.0001% units: 10_000 = 1%)
    uint256 public constant DEV_PRECISION = 1_000_000;

    /// @notice Default TTL for feeds (1 hour)
    uint16 public constant DEFAULT_TTL = 3600;

    // ========== STORAGE ==========

    address public owner;
    mapping(address => bool) public oracles;

    /// @notice Feed data by feedId (1 slot per feed)
    mapping(bytes32 => FeedData) private feeds;

    /// @notice Registered feed IDs
    bytes32[] public feedIds;

    // ========== EVENTS ==========

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

    // ========== MODIFIERS ==========

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyOracle() {
        if (!oracles[msg.sender]) revert Unauthorized();
        _;
    }

    // ========== CONSTRUCTOR ==========

    constructor(address _owner, address _oracle) {
        if (_owner == address(0) || _oracle == address(0)) revert Unauthorized();
        owner = _owner;
        oracles[_oracle] = true;
        emit OracleGranted(_oracle);
    }

    // ========== OWNER FUNCTIONS ==========

    /// @notice Add a new feed
    /// @param base Asset being priced
    /// @param quote Quote currency
    /// @param fastEMA Initial fast price EMA (b64)
    /// @param slowEMA Initial slow price EMA (b64)
    /// @param fastVolEMA Initial fast volatility EMA (1e6 base)
    /// @param slowVolEMA Initial slow volatility EMA (1e6 base)
    /// @param maxDeviation Deviation threshold (0.0001% precision: 10_000 = 1%)
    /// @param ttl Time-to-live in seconds
    function addFeed(
        address base,
        address quote,
        uint64 fastEMA,
        uint64 slowEMA,
        uint32 fastVolEMA,
        uint32 slowVolEMA,
        uint16 maxDeviation,
        uint16 ttl
    ) external onlyOwner {
        if (base == address(0) || quote == address(0)) revert Unauthorized();
        if (fastEMA == 0 || slowEMA == 0) revert IErrors.ZeroValue();
        if (fastVolEMA > MAX_VOLATILITY || slowVolEMA > MAX_VOLATILITY) {
            revert IErrors.ThresholdViolation(fastVolEMA > slowVolEMA ? fastVolEMA : slowVolEMA, MAX_VOLATILITY);
        }
        if (maxDeviation > MAX_DEV_THRESHOLD) revert IErrors.InvalidInput();
        if (ttl == 0) revert Unauthorized();

        bytes32 feedId = keccak256(abi.encodePacked(base, quote));
        if (feeds[feedId].updatedAt != 0) revert FeedAlreadyExists(feedId);

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

        emit FeedAdded(
            feedId,
            base,
            quote,
            fastEMA,
            slowEMA,
            fastVolEMA,
            slowVolEMA,
            maxDeviation
        );
    }

    /// @notice Update feed configuration
    /// @param feedId Feed identifier
    /// @param maxDeviation New deviation threshold
    /// @param ttl New time-to-live
    function updateFeed(
        bytes32 feedId,
        uint16 maxDeviation,
        uint16 ttl
    ) external onlyOwner {
        if (feeds[feedId].updatedAt == 0) revert FeedNotFound(feedId);
        if (maxDeviation > MAX_DEV_THRESHOLD) revert IErrors.InvalidInput();
        if (ttl == 0) revert Unauthorized();

        feeds[feedId].ttl = ttl;
        // Note: maxDeviation not stored in FeedData (removed from struct)
        // Deviation checks can be done off-chain before push

        emit FeedUpdated(feedId, maxDeviation, ttl);
    }

    /// @notice Grant oracle role
    /// @param oracle Address to grant role
    function grantOracle(address oracle) external onlyOwner {
        if (oracle == address(0)) revert Unauthorized();
        oracles[oracle] = true;
        emit OracleGranted(oracle);
    }

    /// @notice Revoke oracle role
    /// @param oracle Address to revoke role
    function revokeOracle(address oracle) external onlyOwner {
        oracles[oracle] = false;
        emit OracleRevoked(oracle);
    }

    /// @notice Transfer ownership
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert Unauthorized();
        owner = newOwner;
    }

    // ========== ORACLE FUNCTIONS ==========

    /// @notice Push single feed update
    /// @param feedId Feed identifier
    /// @param newFastEMA New fast price EMA (b64)
    /// @param newSlowEMA New slow price EMA (b64)
    /// @param newFastVolEMA New fast volatility EMA (1e6 base)
    /// @param newSlowVolEMA New slow volatility EMA (1e6 base)
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

    /// @notice Batch push updates
    /// @param _feedIds Array of feed identifiers
    /// @param fastEMAs Array of fast price EMAs (b64)
    /// @param slowEMAs Array of slow price EMAs (b64)
    /// @param fastVolEMAs Array of fast volatility EMAs (1e6 base)
    /// @param slowVolEMAs Array of slow volatility EMAs (1e6 base)
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
        ) revert Unauthorized();

        for (uint256 i = 0; i < length; i++) {
            _pushInternal(
                _feedIds[i],
                fastEMAs[i],
                slowEMAs[i],
                fastVolEMAs[i],
                slowVolEMAs[i]
            );
        }

        emit BatchPushed(_feedIds, msg.sender);
    }

    // ========== INTERNAL ==========

    /// @notice Internal push logic
    function _pushInternal(
        bytes32 feedId,
        uint64 newFastEMA,
        uint64 newSlowEMA,
        uint32 newFastVolEMA,
        uint32 newSlowVolEMA
    ) internal {
        FeedData storage feed = feeds[feedId];
        if (feed.updatedAt == 0) revert FeedNotFound(feedId);
        if (newFastEMA == 0 || newSlowEMA == 0) revert IErrors.ZeroValue();
        if (newFastVolEMA > MAX_VOLATILITY || newSlowVolEMA > MAX_VOLATILITY) {
            revert IErrors.ThresholdViolation(newFastVolEMA > newSlowVolEMA ? newFastVolEMA : newSlowVolEMA, MAX_VOLATILITY);
        }

        // Update lastPrice to newFastEMA, compute new offsets
        feed.lastPriceB64 = newFastEMA;
        feed.fastOffset = 0; // Fast EMA is now the reference

        // Compute slow offset relative to new fast EMA
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

    // ========== IORAL INTERFACE ==========

    /// @inheritdoc IOracleV1
    function getFeed(bytes32 feedId) external view override returns (FeedData memory data) {
        data = feeds[feedId];
        if (data.updatedAt == 0) revert FeedNotFound(feedId);
    }

    /// @inheritdoc IOracleV1
    function isFeedFresh(bytes32 feedId, uint32 maxAge) external view override returns (bool) {
        FeedData storage f = feeds[feedId];
        if (f.updatedAt == 0) return false;
        unchecked {
            return block.timestamp - f.updatedAt <= maxAge;
        }
    }

    /// @inheritdoc IOracleV1
    function isFeedFresh(bytes32 feedId) external view override returns (bool) {
        FeedData storage f = feeds[feedId];
        if (f.updatedAt == 0) return false;
        unchecked {
            return block.timestamp - f.updatedAt <= f.ttl;
        }
    }

    /// @inheritdoc IOracleV1
    function getFastEMA(bytes32 feedId) external view override returns (uint64 fastEMA) {
        FeedData storage f = feeds[feedId];
        if (f.updatedAt == 0) revert FeedNotFound(feedId);
        return f.lastPriceB64; // Fast EMA is the reference price
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Get all registered feed IDs
    function getFeedIds() external view returns (bytes32[] memory) {
        return feedIds;
    }

    /// @notice Get feed count
    function getFeedCount() external view returns (uint256) {
        return feedIds.length;
    }

    /// @notice Check if feed exists
    function hasFeed(bytes32 feedId) external view returns (bool) {
        return feeds[feedId].updatedAt != 0;
    }

    /// @notice Check if address has oracle role
    function isOracle(address account) external view returns (bool) {
        return oracles[account];
    }
}

// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IOracle} from "../interfaces/IOracle.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Oracle} from "../libraries/Oracle.sol";
import {Maths as M} from "../libraries/Maths.sol";

/// @title ExternalOracle
/// @notice Push-based external oracle. Each push carries a FRESH mark (lastPriceB64 = quote source)
///         plus σ and a 1σ CI (confidence). An on-chain rate-clamped, time-decayed EMA (emaPriceB64)
///         is maintained as a Pyth/Chainlink-parity SERVABLE reference (getEma) — never the quote
///         source. See `Oracle.updateEma` for the clamp/decay guarantee + trust split.
contract ExternalOracle is IOracle {
    /// @notice Shared singleton AccessControl -single source of truth for owner.
    address public immutable AC;
    // ─── constants ───
    uint32 public constant MAX_VOLATILITY = 100 * uint32(SC.PBPS);
    /// @dev F-A3-R14-1 DISCARD (by-design): `maxDeviation` is event-only. The on-chain code does NOT
    ///      check a push's deviation against it; deviation enforcement is delegated to the off-chain
    ///      oracle-key pipeline pre-push. Emitted via `FeedAdded.maxDeviation` as a published policy
    ///      hint — integrators MUST NOT treat it as an on-chain guarantee. On-chain, a compromised key
    ///      can push any mark subject only to `_validate` (non-zero, σ ≤ MAX_VOLATILITY); the EMA's
    ///      per-push displacement is bounded by the rate clamp, and mark trust rests on key gov +
    ///      off-chain monitoring + `revokeOracle`.
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
        uint64 price,
        uint32 sigma,
        uint16 confidence,
        uint32 tau,
        uint16 maxDeviation
    );
    event FeedUpdated(bytes32 indexed feedId, uint16 maxDeviation, uint16 ttl);
    event Pushed(
        bytes32 indexed feedId,
        uint64 price,
        uint64 ema,
        uint32 sigma,
        uint16 confidence,
        address indexed pusher
    );
    event BatchPushed(bytes32[] feedIds, address indexed pusher);
    event OracleGranted(address indexed oracle);
    event OracleRevoked(address indexed oracle);

    // ─── modifiers ───
    modifier onlyOracle() {
        if (!oracles[msg.sender]) revert Err.NotAuth();
        _;
    }

    /// @notice AC-singleton ownership gate. Mirrors Distributor.sol:40 pattern.
    modifier onlyAdmin() {
        if (msg.sender != AccessControl(AC).owner()) revert Err.NotAuth();
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
        uint64 price,
        uint32 sigma,
        uint16 confidence,
        uint32 tau,
        uint16 maxDeviation,
        uint16 ttl
    ) external onlyAdmin {
        if (base == address(0) || quote == address(0)) revert Err.ZeroValue();
        _validate(price, sigma);
        if (maxDeviation > MAX_DEV_THRESHOLD || ttl == 0) revert Err.InvalidInput();

        bytes32 feedId = keccak256(abi.encodePacked(base, quote));
        if (feeds[feedId].updatedAt != 0) revert Err.FeedAlreadyExists(feedId);

        // Seed lastPrice = ema = price (no displacement on the first read).
        feeds[feedId] = FeedData({
            lastPriceB64: price,
            emaPriceB64: price,
            sigma: sigma,
            updatedAt: uint32(block.timestamp),
            ttl: ttl,
            confidence: confidence,
            tau: tau
        });
        feedIds.push(feedId);
        emit FeedAdded(feedId, base, quote, price, sigma, confidence, tau, maxDeviation);
    }

    function updateFeed(bytes32 feedId, uint16 maxDeviation, uint16 ttl) external onlyAdmin {
        if (feeds[feedId].updatedAt == 0) revert Err.FeedNotFound(feedId);
        if (maxDeviation > MAX_DEV_THRESHOLD || ttl == 0) revert Err.InvalidInput();
        feeds[feedId].ttl = ttl;
        // NB: maxDeviation event-only; deviation checks done off-chain pre-push (see MAX_DEV_THRESHOLD).
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
    function pushFeed(bytes32 feedId, uint64 newPriceB64, uint32 newSigma, uint16 newConfidence)
        external onlyOracle
    {
        uint64 ema = _pushInternal(feedId, newPriceB64, newSigma, newConfidence);
        emit Pushed(feedId, newPriceB64, ema, newSigma, newConfidence, msg.sender);
    }

    function batchPush(
        bytes32[] calldata _feedIds,
        uint64[] calldata prices,
        uint32[] calldata sigmas,
        uint16[] calldata confidences
    ) external onlyOracle {
        uint256 length = _feedIds.length;
        if (
            length == 0 ||
            prices.length != length ||
            sigmas.length != length ||
            confidences.length != length
        ) revert Err.InvalidInput();

        for (uint256 i; i < length;) {
            _pushInternal(_feedIds[i], prices[i], sigmas[i], confidences[i]);
            unchecked { ++i; }
        }
        emit BatchPushed(_feedIds, msg.sender);
    }

    // ─── internal ───
    function _validate(uint64 price, uint32 sigma) internal pure {
        if (price == 0 || M.b64To1e18(price) == 0) revert Err.ZeroValue();
        // confidence is left unbounded on purpose: the EMA's MAX_BAND_BPS cap makes a huge CI harmless
        // (it only widens the clamp band to its cap), and the swap-side MAX_CONFIDENCE_HALT_BPS gate
        // fail-closes trading past a sane CI — so validation stays minimal.
        if (sigma > MAX_VOLATILITY) revert Err.ThresholdViolation(sigma, MAX_VOLATILITY);
    }

    function _pushInternal(bytes32 feedId, uint64 newPriceB64, uint32 newSigma, uint16 newConfidence)
        internal returns (uint64 ema)
    {
        FeedData storage feed = feeds[feedId];
        uint32 prevAt = feed.updatedAt;
        if (prevAt == 0) revert Err.FeedNotFound(feedId);
        _validate(newPriceB64, newSigma);

        // Decay the reference EMA toward the (rate-clamped) new mark, then commit the fresh mark.
        uint256 dt;
        unchecked { dt = block.timestamp - prevAt; } // Δt==0 same block ⇒ α=0 (ema frozen)
        ema = Oracle.updateEma(feed.emaPriceB64, newPriceB64, dt, feed.tau, newConfidence);

        // FeedData packs into exactly one slot: whole-struct assignment ⇒ single SSTORE
        // (vs 5 field writes), and ttl/tau reads reuse the already-warm SLOAD.
        feeds[feedId] = FeedData({
            lastPriceB64: newPriceB64,
            emaPriceB64: ema,
            sigma: newSigma,
            updatedAt: uint32(block.timestamp),
            ttl: feed.ttl,
            confidence: newConfidence,
            tau: feed.tau
        });
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

    /// @notice Servable reference price (rate-clamped time-decayed EMA), 1σ-parity with Pyth/Chainlink.
    function getEma(bytes32 feedId) external view override returns (uint64) {
        FeedData storage f = feeds[feedId];
        if (f.updatedAt == 0) revert Err.FeedNotFound(feedId);
        return f.emaPriceB64;
    }

    // ─── views ───
    function getFeedIds() external view returns (bytes32[] memory) { return feedIds; }
    function getFeedCount() external view returns (uint256) { return feedIds.length; }
    function hasFeed(bytes32 feedId) external view returns (bool) { return feeds[feedId].updatedAt != 0; }
    function isOracle(address account) external view returns (bool) { return oracles[account]; }
}

// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IOracle} from "../interfaces/IOracle.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Constants as C} from "../libraries/Constants.sol";
import {Oracle} from "../libraries/Oracle.sol";
import {Maths as M} from "../libraries/Maths.sol";

/// @title ExternalOracle
/// @notice Push-based external oracle. Keeper pushes mark + Parkinson σ sample + mark CI; chain
///         maintains rate-clamped price EMA and σ-EMA. Quote = `lastPriceB64`; pricing σ = `sigmaEma`.
/// @dev Pusher is any `grantOracle` address — testnet EOA, mainnet Gnosis Safe (2-of-3). No threshold
///      logic on-chain; multisig is `msg.sender` after `execTransaction`.
contract ExternalOracle is IOracle {
    address public immutable AC;
    uint32 public constant MAX_VOLATILITY = C.MAX_SIGMA_PBPS;
    uint16 public constant MAX_DEV_THRESHOLD = 65_000;
    uint16 public constant DEFAULT_TTL = 3600;

    mapping(address => bool) public oracles;
    mapping(bytes32 => FeedData) private feeds;
    bytes32[] public feedIds;

    event FeedAdded(
        bytes32 indexed feedId,
        address indexed base,
        address indexed quote,
        uint64 price,
        uint32 sigmaSample,
        uint16 confidence,
        uint16 tau,
        uint16 tauSigma,
        uint16 maxDeviation
    );
    event FeedUpdated(bytes32 indexed feedId, uint16 maxDeviation, uint16 ttl);
    event Pushed(
        bytes32 indexed feedId,
        uint64 price,
        uint64 ema,
        uint32 sigmaSample,
        uint32 sigmaEma,
        uint16 confidence,
        address indexed pusher
    );
    event BatchPushed(uint256 count, address indexed pusher);
    event OracleGranted(address indexed oracle);
    event OracleRevoked(address indexed oracle);

    modifier onlyOracle() {
        if (!oracles[msg.sender]) revert Err.NotAuth();
        _;
    }

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

    function addFeed(
        address base,
        address quote,
        uint64 price,
        uint32 sigmaSample,
        uint16 confidence,
        uint16 tau,
        uint16 tauSigma,
        uint16 maxDeviation,
        uint16 ttl
    ) external onlyAdmin {
        if (base == address(0) || quote == address(0)) revert Err.ZeroValue();
        _validate(price, sigmaSample);
        if (maxDeviation > MAX_DEV_THRESHOLD || ttl == 0) revert Err.InvalidInput();
        if (tauSigma == 0) tauSigma = tau;

        bytes32 feedId = keccak256(abi.encodePacked(base, quote));
        if (feeds[feedId].updatedAt != 0) revert Err.FeedAlreadyExists(feedId);

        feeds[feedId] = FeedData({
            lastPriceB64: price,
            emaPriceB64: price,
            sigmaEma: sigmaSample,
            updatedAt: uint32(block.timestamp),
            ttl: ttl,
            confidence: confidence,
            tau: tau,
            tauSigma: tauSigma
        });
        feedIds.push(feedId);
        emit FeedAdded(feedId, base, quote, price, sigmaSample, confidence, tau, tauSigma, maxDeviation);
    }

    function updateFeed(bytes32 feedId, uint16 maxDeviation, uint16 ttl) external onlyAdmin {
        if (feeds[feedId].updatedAt == 0) revert Err.FeedNotFound(feedId);
        if (maxDeviation > MAX_DEV_THRESHOLD || ttl == 0) revert Err.InvalidInput();
        feeds[feedId].ttl = ttl;
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

    function pushFeed(bytes32 feedId, uint64 newPriceB64, uint32 sigmaSample, uint16 newConfidence)
        external onlyOracle
    {
        (uint64 ema, uint32 sigmaEma) = _pushInternal(feedId, newPriceB64, sigmaSample, newConfidence);
        emit Pushed(feedId, newPriceB64, ema, sigmaSample, sigmaEma, newConfidence, msg.sender);
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
            bytes32 id;
            uint256 p;
            uint256 s;
            uint256 c;
            assembly ("memory-safe") {
                let w := shl(5, i)
                id := calldataload(add(_feedIds.offset, w))
                p := calldataload(add(prices.offset, w))
                s := calldataload(add(sigmas.offset, w))
                c := calldataload(add(confidences.offset, w))
            }
            _pushInternal(id, uint64(p), uint32(s), uint16(c));
            unchecked { ++i; }
        }
        emit BatchPushed(length, msg.sender);
    }

    function _validate(uint64 price, uint32 sigmaSample) internal pure returns (uint256 mark1e18) {
        if ((mark1e18 = M.b64To1e18(price)) == 0) revert Err.ZeroValue();
        if (sigmaSample > MAX_VOLATILITY) revert Err.ThresholdViolation(sigmaSample, MAX_VOLATILITY);
    }

    /// @dev One SLOAD + one SSTORE. Slot layout (low→high bits):
    ///      lastPriceB64[0:64) | emaPriceB64[64:128) | sigmaEma[128:160) | updatedAt[160:192)
    ///      | ttl[192:208) | confidence[208:224) | tau[224:240) | tauSigma[240:256).
    function _pushInternal(bytes32 feedId, uint64 newPriceB64, uint32 sigmaSample, uint16 newConfidence)
        internal returns (uint64 ema, uint32 sigmaEma)
    {
        FeedData storage feed = feeds[feedId];
        uint256 slot;
        uint256 word;
        assembly ("memory-safe") {
            slot := feed.slot
            word := sload(slot)
        }
        uint32 prevAt = uint32((word >> 160) & 0xFFFFFFFF);
        if (prevAt == 0) revert Err.FeedNotFound(feedId);

        uint64 prevMarkB64 = uint64(word);
        uint256 prevMark1e18 = M.b64To1e18(prevMarkB64);
        uint256 mark1e18 = _validate(newPriceB64, sigmaSample);

        uint256 dt;
        unchecked { dt = block.timestamp - prevAt; }

        uint16 tau = uint16((word >> 224) & 0xFFFF);
        uint16 tauSigma = uint16((word >> 240) & 0xFFFF);
        uint32 prevSigmaEma = uint32((word >> 128) & 0xFFFFFFFF);

        ema = Oracle.updateEmaMark1e18(uint64((word >> 64) & 0xFFFFFFFFFFFFFFFF), mark1e18, dt, tau, newConfidence);
        sigmaEma = Oracle.updateSigmaEma(prevSigmaEma, sigmaSample, prevMark1e18, mark1e18, dt, tauSigma);

        uint16 ttl = uint16((word >> 192) & 0xFFFF);
        uint256 newWord = uint256(newPriceB64) | (uint256(ema) << 64) | (uint256(sigmaEma) << 128)
            | (uint256(uint32(block.timestamp)) << 160) | (uint256(ttl) << 192) | (uint256(newConfidence) << 208)
            | (uint256(tau) << 224) | (uint256(tauSigma) << 240);
        assembly ("memory-safe") { sstore(slot, newWord) }
    }

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

    function getEma(bytes32 feedId) external view override returns (uint64) {
        FeedData storage f = feeds[feedId];
        if (f.updatedAt == 0) revert Err.FeedNotFound(feedId);
        return f.emaPriceB64;
    }

    function getFeedIds() external view returns (bytes32[] memory) { return feedIds; }
    function getFeedCount() external view returns (uint256) { return feedIds.length; }
    function hasFeed(bytes32 feedId) external view returns (bool) { return feeds[feedId].updatedAt != 0; }
    function isOracle(address account) external view returns (bool) { return oracles[account]; }
}

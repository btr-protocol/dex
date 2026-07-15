// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IOracle} from "../interfaces/IOracle.sol";
import {IUniSpot} from "../interfaces/IUniSpot.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Maths as M} from "../libraries/Maths.sol";
import {SqrtPrice} from "../incumbents/univ4/SqrtPrice.sol";

/// @title UniPoolOracle — pull-based IOracle that reads spot from a Uni-style pool.
/// @notice No keeper push: `getFeed` samples `slot0().sqrtPriceX96` each call and stamps
///         `updatedAt = block.timestamp` so BTR freshness gates always pass.
/// @dev feedId = keccak256(abi.encodePacked(base, quote)) — same as ExternalOracle.
contract UniPoolOracle is IOracle {
    address public immutable AC;

    struct PoolFeed {
        address pool;
        bool invert; // true → quote/base = token0/token1 (base is token1)
        uint32 sigmaEma; // fixed PBPS σ for pricing
        uint16 confidence; // mark CI bps
        uint16 ttl;
        bool exists;
    }

    mapping(bytes32 => PoolFeed) private feeds;
    bytes32[] public feedIds;

    event FeedAdded(bytes32 indexed feedId, address indexed pool, bool invert, uint32 sigmaEma, uint16 confidence);

    modifier onlyAdmin() {
        if (msg.sender != AccessControl(AC).owner()) revert Err.NotAuth();
        _;
    }

    constructor(address ac_) {
        if (ac_ == address(0)) revert Err.ZeroValue();
        AC = ac_;
    }

    /// @notice Register a Uni spot pool as the mark source for `base/quote`.
    function addFeed(
        address base,
        address quote,
        address pool,
        uint32 sigmaEma,
        uint16 confidence,
        uint16 ttl
    ) external onlyAdmin returns (bytes32 feedId) {
        if (base == address(0) || quote == address(0) || pool == address(0)) revert Err.ZeroValue();
        if (ttl == 0) revert Err.InvalidInput();

        feedId = keccak256(abi.encodePacked(base, quote));
        if (feeds[feedId].exists) revert Err.FeedAlreadyExists(feedId);

        address t0 = IUniSpot(pool).token0();
        address t1 = IUniSpot(pool).token1();
        bool invert;
        if (base == t0 && quote == t1) {
            invert = false; // want token1/token0 = raw
        } else if (base == t1 && quote == t0) {
            invert = true; // want token0/token1 = 1/raw
        } else {
            revert Err.InvalidInput();
        }

        feeds[feedId] = PoolFeed({
            pool: pool,
            invert: invert,
            sigmaEma: sigmaEma,
            confidence: confidence,
            ttl: ttl,
            exists: true
        });
        feedIds.push(feedId);
        emit FeedAdded(feedId, pool, invert, sigmaEma, confidence);
    }

    /// @inheritdoc IOracle
    function getFeed(bytes32 feedId) external view returns (FeedData memory data) {
        PoolFeed memory f = feeds[feedId];
        if (!f.exists) revert Err.FeedNotFound(feedId);

        (uint160 sqrtPriceX96,,) = IUniSpot(f.pool).slot0();
        uint256 price1e18 = SqrtPrice.decode(sqrtPriceX96);
        if (f.invert) {
            if (price1e18 == 0) revert Err.ZeroValue();
            price1e18 = (1e18 * 1e18) / price1e18;
        }
        if (price1e18 == 0) revert Err.ZeroValue();

        uint64 priceB64 = M.encodeB64(price1e18, 18);
        data = FeedData({
            lastPriceB64: priceB64,
            sigmaEma: f.sigmaEma,
            updatedAt: uint32(block.timestamp),
            ttl: f.ttl,
            confidence: f.confidence,
            flags: 0,
            tauSigma: 0,
            maxDeviation: 0,
            sourceTs: 0
        });
    }

    function isFeedFresh(bytes32 feedId, uint32) external view returns (bool) {
        return feeds[feedId].exists;
    }

    function isFeedFresh(bytes32 feedId) external view returns (bool) {
        return feeds[feedId].exists;
    }

    function getFeedIds() external view returns (bytes32[] memory) {
        return feedIds;
    }

    function hasFeed(bytes32 feedId) external view returns (bool) {
        return feeds[feedId].exists;
    }

    function getPool(bytes32 feedId) external view returns (address) {
        return feeds[feedId].pool;
    }
}

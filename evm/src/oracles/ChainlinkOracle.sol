// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IOracle} from "../interfaces/IOracle.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Err} from "@btr-shared/Errors.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";

/// @dev Minimal Chainlink push-feed interface (AggregatorV3Interface subset).
interface IAggregatorV3 {
  function decimals() external view returns (uint8);
  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
}

/// @title ChainlinkOracle - pull-based IOracle over a Chainlink push aggregator.
/// @notice The INDEPENDENT reference oracle for a pool's `refPrimary` depeg band. `latestRoundData()`
///         is a SYNCHRONOUS read (atomic in the swap tx, unlike a pull oracle that needs a fresh
///         update tx first), so a compromised BTR/NX signer quorum cannot walk the mark past
///         `refBandBps` of Chainlink's price without halting swaps. Chainlink's DON IS the independent
///         signer set — there is no second NX quorum to operate. feedId = keccak256(base, quote).
/// @dev getFeed stamps `updatedAt` from the CHAINLINK round (true data age), so `Oracle.gate`'s TTL
///      fail-closes on a stale round. Not flash-manipulable, so production-suitable (cf. UniPoolOracle).
contract ChainlinkOracle is IOracle {
  address public immutable AC;
  /// @notice L2 sequencer-uptime feed (L-7). Chainlink convention: answer 0 = up, 1 = down;
  ///         startedAt = timestamp of the latest status change. address(0) = disabled (L1 chain).
  address public immutable SEQ_FEED;
  /// @notice Post-restart grace (s): after the sequencer comes back up, reads keep failing closed
  ///         until GRACE has elapsed (users need time to top up positions before prices act).
  uint32 public immutable GRACE;

  struct Feed {
    address agg; // Chainlink aggregator
    uint8 aggDecimals; // aggregator.decimals(), cached at addFeed
    uint16 ttl; // max round age (s) before Oracle.gate reverts StaleData
    bool exists;
  }

  mapping(bytes32 => Feed) private feeds;
  bytes32[] public feedIds;

  event FeedAdded(
    bytes32 indexed feedId, address indexed base, address indexed quote, address agg, uint16 ttl
  );

  modifier onlyAdmin() {
    if (msg.sender != AccessControl(AC).owner()) revert Err.NotOwner();
    _;
  }

  constructor(address ac_, address seqFeed_, uint32 grace_) {
    if (ac_ == address(0)) revert Err.ZeroValue();
    if (ac_.code.length == 0) revert Err.NotCode();
    // A configured sequencer feed must be a contract with a non-zero grace (grace=0 would let the
    // first post-restart round price instantly against liquidatable users).
    if (seqFeed_ != address(0) && (grace_ == 0 || seqFeed_.code.length == 0)) {
      revert Err.InvalidInput();
    }
    AC = ac_;
    SEQ_FEED = seqFeed_;
    GRACE = grace_;
  }

  /// @dev L-7 sequencer gate: up iff answer == 0, the round is initialized (startedAt != 0 —
  ///      Chainlink convention: startedAt 0 = uninitialized round, treat as DOWN) AND the restart
  ///      is older than GRACE. Disabled (always up) when SEQ_FEED is unset. Fail-closed consumers:
  ///      getFeed reverts, isFeedFresh reads false.
  function _seqUp() private view returns (bool) {
    if (SEQ_FEED == address(0)) return true;
    (, int256 answer, uint256 startedAt,,) = IAggregatorV3(SEQ_FEED).latestRoundData();
    return answer == 0 && startedAt != 0 && block.timestamp - startedAt > GRACE;
  }

  /// @notice Register a Chainlink aggregator as the reference for `base/quote`.
  function addFeed(address base, address quote, address agg, uint16 ttl)
    external
    onlyAdmin
    returns (bytes32 feedId)
  {
    if (base == address(0) || quote == address(0) || agg == address(0)) {
      revert Err.ZeroValue();
    }
    if (ttl == 0) revert Err.InvalidInput();
    uint8 d = IAggregatorV3(agg).decimals();
    // 10**(18-d) below would underflow for d>18; every Chainlink feed is <= 18 decimals.
    if (d > 18) revert Err.InvalidInput();
    feedId = keccak256(abi.encodePacked(base, quote));
    if (feeds[feedId].exists) revert Err.FeedAlreadyExists(feedId);
    feeds[feedId] = Feed({agg: agg, aggDecimals: d, ttl: ttl, exists: true});
    feedIds.push(feedId);
    emit FeedAdded(feedId, base, quote, agg, ttl);
  }

  function getFeed(bytes32 feedId) external view returns (FeedData memory data) {
    if (!_seqUp()) revert Err.StaleData(0, GRACE);
    Feed memory f = feeds[feedId];
    if (!f.exists) revert Err.FeedNotFound(feedId);
    (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
      IAggregatorV3(f.agg).latestRoundData();
    // Chainlink liveness: strictly-positive answer + a complete, non-stale round. On any failure
    // revert so the caller's Oracle.gate fail-closes (a paused/broken reference must halt, not pass).
    if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId) revert Err.StaleData(0, f.ttl);
    uint256 price1e18 = uint256(answer) * (10 ** (18 - f.aggDecimals));
    data = FeedData({
      lastPriceB64: M.encodeB64(price1e18, 18),
      sigma: 0,
      updatedAt: uint32(updatedAt),
      ttl: f.ttl,
      confidence: 0,
      flags: 0,
      maxDeviation: 0,
      sourceTs: 0
    });
  }

  function isFeedFresh(bytes32 feedId, uint32 maxAge) public view returns (bool) {
    if (!_seqUp()) return false;
    Feed memory f = feeds[feedId];
    if (!f.exists) return false;
    (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
      IAggregatorV3(f.agg).latestRoundData();
    if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId) return false;
    return block.timestamp <= updatedAt + maxAge;
  }

  function isFeedFresh(bytes32 feedId) external view returns (bool) {
    return isFeedFresh(feedId, feeds[feedId].ttl);
  }

  function getFeedIds() external view returns (bytes32[] memory) {
    return feedIds;
  }
}

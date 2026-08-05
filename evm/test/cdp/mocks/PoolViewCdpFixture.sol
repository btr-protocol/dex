// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {IPool} from "../../../src/interfaces/IPool.sol";
import {ICdpPoolView} from "../../../src/interfaces/ICdpPoolView.sol";
import {Constants as C} from "../../../src/libraries/Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {PoolView} from "../../../src/libraries/PoolView.sol";
import {PoolDecay} from "../../../src/libraries/PoolDecay.sol";

contract ControllableOracle is IOracle {
  mapping(bytes32 => FeedData) internal feeds;

  function feedIdFor(address token) public pure returns (bytes32) {
    return bytes32(uint256(uint160(token)));
  }

  function setMark(address token, uint64 priceB64) external {
    setFeedFull(feedIdFor(token), priceB64, uint32(SC.ONE_PCT_PBPS), 0, type(uint16).max, 0, 0, 0);
  }

  function setFeedFull(
    bytes32 id,
    uint64 priceB64,
    uint32 sigma,
    uint16 confidence,
    uint16 ttl,
    uint16 flags,
    uint32 updatedAt,
    uint48 sourceTs
  ) public {
    feeds[id] = FeedData({
      lastPriceB64: priceB64,
      sigma: sigma,
      updatedAt: updatedAt == 0 ? uint32(block.timestamp) : updatedAt,
      ttl: ttl,
      confidence: confidence,
      flags: flags,
      maxDeviation: 0,
      sourceTs: sourceTs
    });
  }

  function setSameBlockSigned(bytes32 id, uint64 priceB64) external {
    uint32 nowTs = uint32(block.timestamp);
    setFeedFull(
      id,
      priceB64,
      uint32(SC.ONE_PCT_PBPS),
      0,
      type(uint16).max,
      0,
      nowTs,
      uint48(uint256(nowTs) * 1000)
    );
  }

  function pause(bytes32 id) external {
    feeds[id].flags |= C.FEED_PAUSED_BIT;
  }

  function getFeed(bytes32 id) external view returns (FeedData memory) {
    return feeds[id];
  }

  function isFeedFresh(bytes32 id, uint32 maxAge) external view returns (bool) {
    FeedData storage f = feeds[id];
    if (f.updatedAt == 0) return false;
    unchecked {
      return block.timestamp - f.updatedAt <= maxAge;
    }
  }

  function isFeedFresh(bytes32 id) external view returns (bool) {
    FeedData storage f = feeds[id];
    if (f.updatedAt == 0) return false;
    unchecked {
      return block.timestamp - f.updatedAt <= f.ttl;
    }
  }
}

/// @dev Real PoolView + PoolDecay over in-contract PoolStorage.
contract PoolViewCdpFixture is ICdpPoolView {
  IPool.PoolStorage internal $;
  address public immutable asset;

  address public hookTarget;
  uint32 public hookFlags;
  address public oraclePrimary;
  bytes32 public oracleFeedId;
  uint8 public oracleMode = C.ORACLE_MODE_INTERNAL;

  constructor(address asset_) {
    asset = asset_;
  }

  function seedLeg(
    uint128 reserves,
    uint128 liabilities,
    uint96 index,
    uint8 decimals,
    uint16 decayStartBps,
    uint32 decaySlope,
    uint16 riskFlags,
    uint32 lastUpdate,
    uint16 haircutSuppressor
  ) external {
    IPool.Asset storage a = $.assets[asset];
    a.reserves = reserves;
    a.liabilities = liabilities;
    a.liquidityIndex = index;
    a.decimals = decimals;
    a.lastUpdate = lastUpdate;
    a.minLiquidity = 0;
    a.haircutSuppressor = haircutSuppressor;

    IPool.RiskConfig storage rc = $.riskConfigs[asset];
    rc.decayStartRatioBps = decayStartBps;
    rc.decaySlope = decaySlope;
    rc.flags = riskFlags;
  }

  function setHook(address target, uint32 flags) external {
    hookTarget = target;
    hookFlags = flags;
  }

  function setOracle(address primary, bytes32 feedId, uint8 mode) external {
    oraclePrimary = primary;
    oracleFeedId = feedId;
    oracleMode = mode;
  }

  function pendingDecayAmt() external view returns (uint128) {
    return PoolView.pendingDecay($, asset);
  }

  function applyPendingDecay() external {
    PoolDecay.applyDecay($.assets[asset], $.riskConfigs[asset], asset);
  }

  /// @dev Test helper (not on ICdpPoolView): stored-index preview for stale-vs-fresh asserts.
  function previewWithdraw(address token, uint256 lp)
    external
    view
    returns (uint256 amountOut, uint256 haircut)
  {
    return PoolView.previewWithdraw($, token, lp);
  }

  function previewWithdrawFresh(address token, uint256 lp)
    external
    view
    returns (uint256 amountOut, uint256 haircut)
  {
    return PoolView.previewWithdrawFresh($, token, lp);
  }

  function getAssetHook(address) external view returns (address target, uint32 flags) {
    return (hookTarget, hookFlags);
  }

  function getRiskFlags(address) external view returns (uint16) {
    return $.riskConfigs[asset].flags;
  }

  function liquidityIndex(address) external view returns (uint256) {
    return $.assets[asset].liquidityIndex;
  }

  function maxRedeem(address, address) external pure returns (uint256) {
    return type(uint256).max;
  }

  function markFeed(address)
    external
    view
    returns (address primary, bytes32 feedId, uint8 mode)
  {
    return (oraclePrimary, oracleFeedId, oracleMode);
  }

  function assetDecimals(address) external view returns (uint8) {
    return $.assets[asset].decimals;
  }
}

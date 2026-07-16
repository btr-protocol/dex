// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IOracle} from "../interfaces/IOracle.sol";

/// @title TransientCache
/// @notice Tx-scoped oracle cache via transient storage (EIP-1153). ~2.1k gas/hit.
library TransientCache {
  uint256 private constant NAMESPACE_SALT = uint256(keccak256("pool.cache")) >> 192 << 192;
  uint256 private constant TYPE_ORACLE_FEED = 1 << 168;

  function _slot(uint256 typeMask, address token) private pure returns (bytes32 slot) {
    unchecked {
      slot = bytes32(NAMESPACE_SALT | typeMask | uint256(uint160(token)));
    }
  }

  function cacheOracleFeed(address token, IOracle.FeedData memory data) internal {
    bytes32 slot = _slot(TYPE_ORACLE_FEED, token);
    uint256 packed = _packFeedData(data);
    if (packed == 0) return;
    assembly { tstore(slot, packed) }
  }

  function tryLoadOracleFeed(address token)
    internal
    view
    returns (bool found, IOracle.FeedData memory data)
  {
    bytes32 slot = _slot(TYPE_ORACLE_FEED, token);
    uint256 packed;
    assembly { packed := tload(slot) }
    if (packed == 0) return (false, data);
    data = _unpackFeedData(packed);
    return (true, data);
  }

  // Layout: sourceTs(48)@208|lastPrice(64)@144|sigmaEma(32)|updatedAt(32)|ttl(16)|confidence(16)|flags(16)|tauSigma(16)|maxDev(16)
  function _packFeedData(IOracle.FeedData memory d) private pure returns (uint256 packed) {
    packed |= uint256(d.sourceTs) << 208; // keep cache == fresh so pool-internal readers see true data-age
    packed |= uint256(d.lastPriceB64) << 144;
    packed |= uint256(d.sigmaEma) << 112;
    packed |= uint256(d.updatedAt) << 80;
    packed |= uint256(d.ttl) << 64;
    packed |= uint256(d.confidence) << 48;
    packed |= uint256(d.flags) << 32; // preserve paused bit through the tx cache (fail-closed consistency)
    packed |= uint256(d.tauSigma) << 16;
    packed |= uint256(d.maxDeviation);
  }

  function _unpackFeedData(uint256 packed) private pure returns (IOracle.FeedData memory d) {
    d.sourceTs = uint48(packed >> 208);
    d.maxDeviation = uint16(packed & 0xFFFF);
    packed >>= 16;
    d.tauSigma = uint16(packed & 0xFFFF);
    packed >>= 16;
    d.flags = uint16(packed & 0xFFFF);
    packed >>= 16;
    d.confidence = uint16(packed & 0xFFFF);
    packed >>= 16;
    d.ttl = uint16(packed & 0xFFFF);
    packed >>= 16;
    d.updatedAt = uint32(packed & 0xFFFFFFFF);
    packed >>= 32;
    d.sigmaEma = uint32(packed & 0xFFFFFFFF);
    packed >>= 32;
    d.lastPriceB64 = uint64(packed & 0xFFFFFFFFFFFFFFFF);
  }
}

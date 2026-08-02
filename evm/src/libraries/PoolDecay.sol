// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {Constants as C} from "./Constants.sol";

/// @title PoolDecay - liability decay math + storage update for Pool.
library PoolDecay {
  /// @notice Apply liability decay in-place, reusing a caller-loaded RiskConfig (avoids re-SLOAD).
  ///         Full no-op when decay is disabled (no SSTORE).
  /// @param token Event key only. Decay is the one index move with no other log, so an indexer
  ///        cannot otherwise tell a decayed leg from a written-down one.
  function applyDecay(IPool.Asset storage asset, IPool.RiskConfig storage rc, address token)
    internal
  {
    if ((rc.flags & C.DECAY_ENABLED_BIT) == 0 || rc.decaySlope == 0) return;

    uint32 dt = uint32(block.timestamp) - asset.lastUpdate;
    if (dt == 0) return;

    uint128 oldLiab = asset.liabilities;
    uint128 decayAmount =
      calculateDecay(oldLiab, asset.reserves, rc.decayStartRatioBps, rc.decaySlope, dt);

    if (decayAmount > 0) {
      uint128 newLiab = oldLiab - decayAmount;
      // Socialize the write-down via the liquidity index (value = lp·index/WAD). No floor: flooring
      // at 1 pushed the index ABOVE the proportional value, so outstanding shares could claim more
      // than `liabilities` (breaks totalSupply·index/WAD ≤ liabilities). A scaled-to-0 index is the
      // truthful terminal state: every share is worth 0 and the leg stops taking deposits.
      uint256 newIdx = (uint256(asset.liquidityIndex) * uint256(newLiab)) / uint256(oldLiab);
      asset.liquidityIndex = uint64(newIdx);
      asset.liabilities = newLiab;
      emit IPool.IndexUpdated(token, newIdx, asset.reserves, newLiab, C.INDEX_REASON_DECAY);
    }
    asset.lastUpdate = uint32(block.timestamp);
  }

  /// @notice Coverage-gated linear amortization. Cap = liabilities − reserves.
  function calculateDecay(
    uint128 liabilities,
    uint128 reserves,
    uint16 decayStartRatioBps,
    uint32 decaySlope,
    uint32 dt
  ) internal pure returns (uint128) {
    if (dt == 0 || decaySlope == 0 || liabilities == 0) return 0;
    uint256 coverage = (uint256(reserves) * 1e18) / uint256(liabilities);
    // decayStartRatioBps is BPS (1e4 = 100%) → WAD threshold = bps·1e18/1e4.
    uint256 threshold = (uint256(decayStartRatioBps) * 1e18) / 10_000;
    if (coverage >= threshold) return 0;
    uint256 rawDecay = (uint256(liabilities) * uint256(decaySlope) * uint256(dt)) / 1e18;
    uint256 maxDecay = liabilities > reserves ? liabilities - reserves : 0;
    return uint128(rawDecay > maxDecay ? maxDecay : rawDecay);
  }
}

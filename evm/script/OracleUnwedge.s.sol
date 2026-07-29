// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {ExternalOracle} from "../src/oracles/ExternalOracle.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";

/// @title OracleUnwedge — un-deadlock ExternalOracle feeds whose per-push band collapsed to the
///        bare `maxDeviation` floor.
/// @notice A feed seeded by `addFeed` with `sigmaSample = 0` has NO volatility-adaptive band: the
///         band is `maxDeviation + Z·σ·√(dt/interval)` and σ only rises on a SUCCESSFUL push. Once
///         the market drifts past the bare floor, every push reverts `ThresholdViolation` — the feed
///         needs a push to gain σ and needs σ to accept the push. The signed blob is atomic, so ONE
///         wedged record reverts the whole batch and takes every healthy feed in it down too.
/// @dev NO REDEPLOY. Widening `maxDeviation` is the entire fix, and it is reversible instantly once
///      the keeper has landed one real push (which sets σ and sourceTs, after which the adaptive
///      band carries the feed on its own).
/// @dev TWO ORACLE BUILDS EXIST and they differ exactly here, so the script probes rather than
///      assumes:
///        · DEPLOYED (Sepolia today): `updateFeed` accepts ANY maxDeviation ≤ MAX_DEV_THRESHOLD,
///          instantly, owner-only. Widen = one tx per feed, zero delay.
///        · LOCAL SOURCE (post tighten-only asymmetry fix): `updateFeed` is tighten-or-equal and
///          loosening routes through `requestFeedWiden` → `SC.govDelay(BASE_TIMELOCK)` →
///          `executeFeedWiden` (15 min on Sepolia, 2 DAYS on mainnet).
///      `_hasWidenPath()` picks the right one. Nothing else in the script changes.
/// @dev WIDEN TARGET = 10 × the feed's CURRENT floor, i.e. exactly the per-push ceiling the SAME
///      feed would already grant itself once σ is populated (the σ term is capped at
///      `DEV_BAND_MAX_X` = 9 × maxDeviation). The widen therefore hands the signer set NO authority
///      it does not already hold on a healthy feed — it only stops withholding it from a cold one.
///      Capped at `MAX_DEV_THRESHOLD`. `ttl` is never touched.
/// @dev ⚠ The wide floor IS the per-push drain bound. Run `retighten()` as soon as the keeper has
///      landed one push on every widened feed. Do not leave the fleet wide overnight.
///
/// Env: `ORACLE` (ExternalOracle). Broadcaster key MUST be the AccessControl owner.
/// Runbook, per oracle (`--broadcast` only on the team lead's call):
///   forge script script/OracleUnwedge.s.sol:OracleUnwedge --sig "preview()"   --rpc-url sepolia
///   forge script script/OracleUnwedge.s.sol:OracleUnwedge --sig "widen()"     --rpc-url sepolia
///   (on the deployed build this lands immediately; on the new build it queues — then, after the
///    delay, `--sig "executeWiden()"`)
///   (keeper lands one real push per feed → σ + sourceTs populated)
///   forge script script/OracleUnwedge.s.sol:OracleUnwedge --sig "retighten()" --rpc-url sepolia
contract OracleUnwedge is Script {
  ExternalOracle internal oracle = ExternalOracle(vm.envAddress("ORACLE"));

  /// @dev Mirrors ExternalOracle.DEV_BAND_MAX_X (private there): band ceiling = (1+9)·maxDeviation.
  uint16 internal constant BAND_MAX_MULT = 10;

  /// Dry-run: every feed with no adaptive band (σ == 0), and the widen that would be applied.
  function preview() external view {
    bytes32[] memory ids = oracle.getFeedIds();
    console2.log("oracle", address(oracle));
    console2.log("feeds", ids.length);
    console2.log("timelocked widen path present:", _hasWidenPath());
    console2.log("govDelay(BASE) seconds", SC.govDelay(SC.BASE_TIMELOCK));
    uint256 wedged;
    for (uint256 i; i < ids.length; ++i) {
      IOracle.FeedData memory f = oracle.getFeed(ids[i]);
      if (f.sigma != 0) continue;
      ++wedged;
      console2.log("  idx", i);
      console2.logBytes32(ids[i]);
      console2.log("    maxDeviation", f.maxDeviation, "->", _target(f.maxDeviation));
      console2.log("    ttl", f.ttl);
      console2.log("    mark age (s)", block.timestamp - f.updatedAt);
    }
    console2.log("wedge-prone feeds (sigma==0)", wedged);
  }

  /// Widen every σ==0 feed. Instant on the deployed build; queues a timelock on the new one.
  /// @dev `SKIP_IDXS` (comma-separated feedIds indices) HOLDS a leg wedged on purpose. A wedged feed
  ///      is fail-closed — every pool that bands against it reverts — so this is the cheapest gate
  ///      for a leg that must not become swappable yet. Used for the fx legs until their
  ///      `minFeePbps >= 2θ` violation is repaired: unwedging them is exactly what would make them
  ///      quote, and they must not quote at a 4 bp fee against a 10 bp permitted mark drift.
  function widen() external {
    bytes32[] memory ids = oracle.getFeedIds();
    bool timelocked = _hasWidenPath();
    uint256[] memory skip = vm.envOr("SKIP_IDXS", ",", new uint256[](0));
    vm.startBroadcast();
    for (uint256 i; i < ids.length; ++i) {
      IOracle.FeedData memory f = oracle.getFeed(ids[i]);
      uint16 target = _target(f.maxDeviation);
      if (f.sigma != 0 || target <= f.maxDeviation) continue;
      if (_contains(skip, i)) {
        console2.log("HELD WEDGED (SKIP_IDXS) idx", i);
        continue;
      }
      if (timelocked) {
        if (oracle.pendingWiden(ids[i]) >> 160 != 0) continue; // one pending per feed
        oracle.requestFeedWiden(ids[i], target, f.ttl);
        console2.log("widen QUEUED idx", i, "->", target);
      } else {
        oracle.updateFeed(ids[i], target, f.ttl);
        console2.log("widen APPLIED idx", i, "->", target);
      }
    }
    vm.stopBroadcast();
  }

  /// Apply every matured widen (new build only; a no-op on the deployed one). A feed tightened
  /// during the delay voids its own payload by design — that leg is skipped, never force-applied.
  function executeWiden() external {
    require(_hasWidenPath(), "deployed build has no timelocked widen: widen() already applied");
    bytes32[] memory ids = oracle.getFeedIds();
    vm.startBroadcast();
    for (uint256 i; i < ids.length; ++i) {
      if (oracle.pendingWiden(ids[i]) >> 160 == 0) continue;
      oracle.executeFeedWiden(ids[i]);
      console2.log("widen executed idx", i);
    }
    vm.stopBroadcast();
  }

  /// Restore the original floors. Only touches feeds that BOTH sit at a widened ceiling AND have
  /// since taken a real push (σ != 0) — a still-wedged feed keeps its wide band rather than being
  /// re-deadlocked by this script. `updateFeed` tightens instantly on BOTH builds.
  function retighten() external {
    bytes32[] memory ids = oracle.getFeedIds();
    vm.startBroadcast();
    for (uint256 i; i < ids.length; ++i) {
      IOracle.FeedData memory f = oracle.getFeed(ids[i]);
      if (f.sigma == 0) continue;
      uint16 orig = f.maxDeviation / BAND_MAX_MULT;
      if (orig == 0 || f.maxDeviation % BAND_MAX_MULT != 0) continue; // not a widened floor
      oracle.updateFeed(ids[i], orig, f.ttl);
      console2.log("retightened idx", i, "->", orig);
    }
    vm.stopBroadcast();
  }

  function _contains(uint256[] memory xs, uint256 x) internal pure returns (bool) {
    for (uint256 i; i < xs.length; ++i) {
      if (xs[i] == x) return true;
    }
    return false;
  }

  function _target(uint16 maxDev) internal view returns (uint16) {
    uint256 t = uint256(maxDev) * BAND_MAX_MULT;
    uint256 cap = oracle.MAX_DEV_THRESHOLD();
    return uint16(t > cap ? cap : t);
  }

  /// @dev True when the target carries the timelocked widen path (`pendingWiden` present). A build
  ///      without it reverts the staticcall on an unknown selector.
  function _hasWidenPath() internal view returns (bool ok) {
    (ok,) = address(oracle).staticcall(abi.encodeWithSignature("pendingWiden(bytes32)", bytes32(0)));
  }
}

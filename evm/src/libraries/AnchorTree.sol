// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @title AnchorTree -depth-1 star topology (validation, routing).
/// @dev Every non-base asset anchors DIRECTLY to the base numeraire (a star, not a deep tree). This is
///      how PoolAdmin seeds assets by construction, and it is the ENFORCED ceiling: a cross-spoke swap
///      is always spoke→base→spoke (2 EDGE legs), never an interior mid-priced leg. Every leg carries
///      full spline impact + reserve accounting, so A→B has one price regardless of decomposition (no
///      route path-dependence — the deep-tree impl mid-priced interior legs, making the same trade cost
///      differently per decomposition and admitting cycle-arb).
///  @dev WHY flat is CORRECT here, not merely simpler (expert-panel verdict, 2026-07): a deep "relative
///      spline" for a correlated cluster (cbBTC/WBTC/BTCB, the 6 stables) only pays off if the RELATIVE
///      rate carries information. It does not: NX-Rates maps every BTC-wrapper to the SAME BTC-USDT mark
///      (keepers/alm.toml), so cbBTC/WBTC ≡ 1.0 — and there is no on-chain rate to build a real one. A
///      tight 1.0-centered spline would concentrate MAX capital exactly at the depeg failure price
///      (bridge/custody solvency: BitGo/Coinbase/Binance) = short-vol on the one axis that matters. Flat
///      instead prices EACH wrapper vs base on its own reserves, so per-spoke coverage-skew auto-widens
///      on a depeg (a natural circuit-breaker), and the 2× base-leg width is a feature, not a cost.
///  @dev ponytail ceiling — deep is DEFERRED behind a provenance gate, not built: a depth-2 anchor is
///      admissible ONLY behind a native monotone protocol-owned on-chain rate for the interior edge
///      (LST `stEthPerToken`, ERC4626 `convertToAssets`) — a yield-accrual leg where a relative spline
///      genuinely wins and is not depeg-blind. The current book has ZERO such assets, so MAX_DEPTH stays
///      1 (validateAnchor rejects deeper) and the interior-settle / LCA machinery is intentionally
///      UNWRITTEN. The anchor-pointer model is already in storage, so enabling deep later = config + one
///      rate() source + interior reserve-settle against a live test vector, NOT a re-architecture.
library AnchorTree {
    uint8 public constant MAX_DEPTH = 1; // base = 0, every spoke = 1 (direct-to-base star)

    /// @notice Validate anchor: base anchors to nothing; every other asset anchors to base (depth 1).
    function validateAnchor(IPool.PoolStorage storage $, address asset, address anchor)
        internal view returns (uint8 depth)
    {
        if (asset == anchor) revert Err.InvalidAnchor(asset, anchor);
        if (anchor == address(0)) {
            if (asset != $.baseToken) revert Err.InvalidAnchor(asset, anchor);
            return 0;
        }
        // Non-null anchor ⇒ must be the base (a depth-0 asset); depth = 0 + 1 = 1. Anything deeper is
        // rejected, so the tree can only ever be a star and no cycle is possible.
        if (anchor != $.baseToken) revert Err.DepthExceeded(asset, 2);
        if ($.assets[anchor].decimals == 0) revert Err.AssetNotInTree(anchor);
        return 1;
    }

    /// @notice Route between two tree assets. Depth-1 ⇒ exactly two shapes: a spoke↔base direct leg, or
    ///         a spoke→base→spoke sibling hop. Both legs are edges (full impact + reserve accounting).
    function findRoutingPath(IPool.PoolStorage storage $, address tokenIn, address tokenOut)
        internal view returns (IPool.RoutePath memory path)
    {
        IPool.Asset storage aIn = $.assets[tokenIn];
        IPool.Asset storage aOut = $.assets[tokenOut];
        if (aIn.decimals == 0) revert Err.AssetNotInTree(tokenIn);
        if (aOut.decimals == 0) revert Err.AssetNotInTree(tokenOut);
        address anchorIn = aIn.anchor;
        address anchorOut = aOut.anchor;

        // Direct: one endpoint is the other's anchor (spoke↔base).
        if (anchorIn == tokenOut || anchorOut == tokenIn) {
            path.hops = new address[](2);
            path.hops[0] = tokenIn;
            path.hops[1] = tokenOut;
            return path;
        }
        // Sibling: both spokes share the base anchor (spoke→base→spoke).
        if (anchorIn == anchorOut && anchorIn != address(0)) {
            path.hops = new address[](3);
            path.hops[0] = tokenIn;
            path.hops[1] = anchorIn; // = base
            path.hops[2] = tokenOut;
            return path;
        }
        // In a depth-1 star every valid pair is direct or sibling; anything else is a malformed tree.
        revert Err.InvalidPath();
    }

    function isRoot(IPool.PoolStorage storage $, address asset) internal view returns (bool) {
        return asset == $.baseToken && $.assets[asset].anchor == address(0);
    }
}

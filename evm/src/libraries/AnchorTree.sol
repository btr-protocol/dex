// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @title AnchorTree -depth-1 star topology (validation, routing).
/// @dev Every non-base asset anchors DIRECTLY to the base numeraire (a star, not a deep tree). This is
///      how PoolAdmin seeds assets by construction, and it is now the ENFORCED ceiling: a cross-spoke
///      swap is always spoke→base→spoke (2 EDGE legs), never an interior mid-priced leg. That removes
///      the route path-dependence a deep tree admits (the same economic trade priced via different
///      decompositions gave different amounts, and interior legs charged mid-only with no spline impact
///      / no reserve move) — with depth 1 there ARE no interior legs, so every leg carries full impact
///      and reserve accounting, and A→B has one price regardless of decomposition.
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

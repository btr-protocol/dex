// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @title AnchorTree -anchor-based pricing tree (validation, routing).
library AnchorTree {
    uint8 public constant MAX_DEPTH = 4;        // root = 0
    uint8 public constant MAX_PATH_LENGTH = 6;  // 2 * MAX_DEPTH

    // TODO(Wave-6): migrate to shared Err lib (parity w/ ALM Cohort-3 finding 6 migration).
    error InvalidAnchor(address asset, address anchor);
    error DepthExceeded(address asset, uint8 depth);
    error CycleDetected(address asset);
    error AssetNotInTree(address asset);
    error InvalidPath();

    /// @notice Validate anchor: no cycles, depth <= MAX_DEPTH.
    function validateAnchor(IPool.PoolStorage storage $, address asset, address anchor)
        internal view returns (uint8 depth)
    {
        if (asset == anchor) revert InvalidAnchor(asset, anchor);
        if (anchor == address(0)) {
            if (asset != $.baseToken) revert InvalidAnchor(asset, anchor);
            return 0;
        }
        IPool.Asset storage anchorAsset = $.assets[anchor];
        if (anchorAsset.decimals == 0) revert AssetNotInTree(anchor);
        depth = anchorAsset.anchorDepth + 1;
        if (depth > MAX_DEPTH) revert DepthExceeded(asset, depth);

        // Cycle check via walk-to-root.
        address current = anchor;
        uint8 steps = 0;
        while (current != address(0)) {
            if (current == asset) revert CycleDetected(asset);
            current = $.assets[current].anchor;
            if (++steps > MAX_DEPTH + 1) revert CycleDetected(asset);
        }
    }

    /// @notice Find routing path between two assets via LCA.
    function findRoutingPath(IPool.PoolStorage storage $, address tokenIn, address tokenOut)
        internal view returns (IPool.RoutePath memory path)
    {
        IPool.Asset storage aIn = $.assets[tokenIn];
        IPool.Asset storage aOut = $.assets[tokenOut];
        address anchorIn = aIn.anchor;
        address anchorOut = aOut.anchor;
        if (aIn.decimals == 0) revert AssetNotInTree(tokenIn);
        if (aOut.decimals == 0) revert AssetNotInTree(tokenOut);

        // Direct anchor (child↔parent).
        if (anchorIn == tokenOut || anchorOut == tokenIn) {
            path.hops = new address[](2);
            path.hops[0] = tokenIn;
            path.hops[1] = tokenOut;
            return path;
        }
        // Sibling (common parent).
        if (anchorIn == anchorOut && anchorIn != address(0)) {
            path.hops = new address[](3);
            path.hops[0] = tokenIn;
            path.hops[1] = anchorIn;
            path.hops[2] = tokenOut;
            return path;
        }
        // General: LCA via path walking.
        address[] memory pathIn = walkToRoot($, tokenIn);
        address[] memory pathOut = walkToRoot($, tokenOut);
        address lca = findLCA(pathIn, pathOut);
        path = _constructPath(lca, pathIn, pathOut);
    }

    function walkToRoot(IPool.PoolStorage storage $, address asset)
        internal view returns (address[] memory path)
    {
        path = new address[](MAX_DEPTH + 1);
        uint256 length = 0;
        address current = asset;
        while (true) {
            path[length++] = current;
            address anchor = $.assets[current].anchor;
            if (anchor == address(0)) break;
            current = anchor;
            if (length > MAX_DEPTH) revert InvalidPath();
        }
        assembly { mstore(path, length) }
    }

    function findLCA(address[] memory pathA, address[] memory pathB)
        internal pure returns (address lca)
    {
        if (pathA[pathA.length - 1] != pathB[pathB.length - 1]) revert Err.InvalidInput();
        lca = pathA[pathA.length - 1];
        uint256 i = pathA.length - 1;
        uint256 j = pathB.length - 1;
        while (i > 0 && j > 0) {
            if (pathA[i - 1] != pathB[j - 1]) break;
            i--; j--;
            lca = pathA[i];
        }
    }

    function isRoot(IPool.PoolStorage storage $, address asset) internal view returns (bool) {
        return asset == $.baseToken && $.assets[asset].anchor == address(0);
    }

    function _constructPath(address lca, address[] memory pathIn, address[] memory pathOut)
        private pure returns (IPool.RoutePath memory path)
    {
        uint256 lcaIn = type(uint256).max;
        uint256 lcaOut = type(uint256).max;
        for (uint256 i = 0; i < pathIn.length; i++) if (pathIn[i] == lca) { lcaIn = i; break; }
        for (uint256 i = 0; i < pathOut.length; i++) if (pathOut[i] == lca) { lcaOut = i; break; }
        if (lcaIn == type(uint256).max || lcaOut == type(uint256).max) revert Err.InvalidState();

        // tokenIn → ... → LCA → ... → tokenOut
        path.hops = new address[](lcaIn + 1 + lcaOut);
        for (uint256 i = 0; i <= lcaIn; i++) path.hops[i] = pathIn[i];
        for (uint256 i = 1; i <= lcaOut; i++) path.hops[lcaIn + i] = pathOut[lcaOut - i];
    }
}

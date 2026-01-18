// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IPoolV1} from "../interfaces/IPoolV1.sol";
import {IErrors} from "../interfaces/IErrors.sol";

/// @title LibAnchorTree
/// @notice Library for anchor-based pricing tree operations
/// @dev Implements routing, validation, and tree management for anchor-based AMM
library LibAnchorTree {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    uint8 public constant MAX_DEPTH = 4;       // Maximum tree depth (root = 0), very unlikely to exceed 3
    uint8 public constant MAX_PATH_LENGTH = 6; // Max hops in path (2 * MAX_DEPTH)

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error InvalidAnchor(address asset, address anchor);
    error DepthExceeded(address asset, uint8 depth);
    error CycleDetected(address asset);
    error AssetNotInTree(address asset);
    error InvalidPath();

    // ═══════════════════════════════════════════════════════════════════════════
    // TREE VALIDATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Validate anchor assignment doesn't create cycles or exceed depth
    /// @param $ Pool storage
    /// @param asset Asset to validate
    /// @param anchor Proposed anchor
    /// @return depth The depth of the asset after anchoring
    function validateAnchor(
        IPoolV1.PoolStorage storage $,
        address asset,
        address anchor
    ) internal view returns (uint8 depth) {
        if (asset == anchor) revert InvalidAnchor(asset, anchor);

        // Root case
        if (anchor == address(0)) {
            // Only base token can be root
            if (asset != $.baseToken) revert InvalidAnchor(asset, anchor);
            return 0;
        }

        // Check anchor is configured
        IPoolV1.Asset storage anchorAsset = $.assets[anchor];
        if (anchorAsset.decimals == 0) revert AssetNotInTree(anchor);

        // Calculate new depth
        depth = anchorAsset.anchorDepth + 1;
        if (depth > MAX_DEPTH) revert DepthExceeded(asset, depth);

        // Check for cycles by walking from anchor to root
        address current = anchor;
        uint8 steps = 0;

        while (current != address(0)) {
            if (current == asset) revert CycleDetected(asset);

            current = $.assets[current].anchor;
            steps++;

            if (steps > MAX_DEPTH + 1) revert CycleDetected(asset);
        }

        return depth;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PATHFINDING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Find routing path between two assets via LCA
    /// @param $ Pool storage
    /// @param tokenIn Source asset
    /// @param tokenOut Destination asset
    /// @return path The routing path through the tree
    function findRoutingPath(
        IPoolV1.PoolStorage storage $,
        address tokenIn,
        address tokenOut
    ) internal view returns (IPoolV1.RoutePath memory path) {
        // Cache anchor reads to avoid repeated SLOADs (saves ~200 gas per avoided SLOAD)
        // Single SLOAD per asset for the packed slot containing anchor+decimals
        IPoolV1.Asset storage assetInStorage = $.assets[tokenIn];
        IPoolV1.Asset storage assetOutStorage = $.assets[tokenOut];

        // Read packed slot once: decimals (8 bits) + anchor (160 bits) are in same slot
        address anchorIn = assetInStorage.anchor;
        address anchorOut = assetOutStorage.anchor;
        uint8 decimalsIn = assetInStorage.decimals;
        uint8 decimalsOut = assetOutStorage.decimals;

        // Validate assets are in tree
        if (decimalsIn == 0) revert AssetNotInTree(tokenIn);
        if (decimalsOut == 0) revert AssetNotInTree(tokenOut);

        // Direct anchor optimization (most common case: child↔parent)
        if (anchorIn == tokenOut || anchorOut == tokenIn) {
            path.hops = new address[](2);
            path.hops[0] = tokenIn;
            path.hops[1] = tokenOut;
            return path;
        }

        // Common parent optimization (second most common: siblings)
        if (anchorIn == anchorOut && anchorIn != address(0)) {
            path.hops = new address[](3);
            path.hops[0] = tokenIn;
            path.hops[1] = anchorIn;
            path.hops[2] = tokenOut;
            return path;
        }

        // General case: find LCA via path walking
        address[] memory pathIn = walkToRoot($, tokenIn);
        address[] memory pathOut = walkToRoot($, tokenOut);

        address lca = findLCA(pathIn, pathOut);
        path = constructPath(tokenIn, tokenOut, lca, pathIn, pathOut);

        return path;
    }

    /// @notice Walk from asset to root, recording path
    /// @param $ Pool storage
    /// @param asset Starting asset
    /// @return path Array of assets from leaf to root
    function walkToRoot(
        IPoolV1.PoolStorage storage $,
        address asset
    ) internal view returns (address[] memory path) {
        path = new address[](MAX_DEPTH + 1);
        uint256 length = 0;
        address current = asset;

        while (true) {
            path[length++] = current;

            address anchor = $.assets[current].anchor;
            if (anchor == address(0)) break;  // Reached root

            current = anchor;

            // Safety check
            if (length > MAX_DEPTH) revert InvalidPath();
        }

        // Resize array to actual length
        assembly { mstore(path, length) }
        return path;
    }

    /// @notice Find lowest common ancestor in two paths
    /// @param pathA First path (leaf to root)
    /// @param pathB Second path (leaf to root)
    /// @return lca The lowest common ancestor
    function findLCA(
        address[] memory pathA,
        address[] memory pathB
    ) internal pure returns (address lca) {
        // Both paths end at root, so roots must match
        if (pathA[pathA.length - 1] != pathB[pathB.length - 1]) revert IErrors.InvalidInput();

        lca = pathA[pathA.length - 1];  // Start at root

        // Walk down from root until paths diverge
        uint256 i = pathA.length - 1;
        uint256 j = pathB.length - 1;

        while (i > 0 && j > 0) {
            if (pathA[i - 1] != pathB[j - 1]) break;
            i--;
            j--;
            lca = pathA[i];
        }

        return lca;
    }

    /// @notice Construct full routing path via LCA
    /// @param lca Lowest common ancestor
    /// @param pathIn Path from tokenIn to root (includes tokens as array elements)
    /// @param pathOut Path from tokenOut to root
    /// @return path Complete routing path
    function constructPath(
        address /* tokenIn */,
        address /* tokenOut */,
        address lca,
        address[] memory pathIn,
        address[] memory pathOut
    ) internal pure returns (IPoolV1.RoutePath memory path) {
        // Find LCA indices in both paths
        uint256 lcaIndexIn = type(uint256).max;
        uint256 lcaIndexOut = type(uint256).max;

        for (uint256 i = 0; i < pathIn.length; i++) {
            if (pathIn[i] == lca) {
                lcaIndexIn = i;
                break;
            }
        }

        for (uint256 i = 0; i < pathOut.length; i++) {
            if (pathOut[i] == lca) {
                lcaIndexOut = i;
                break;
            }
        }

        if (lcaIndexIn == type(uint256).max || lcaIndexOut == type(uint256).max) revert IErrors.InvalidState();

        // Build full path: tokenIn → ... → LCA → ... → tokenOut
        uint256 totalLength = lcaIndexIn + 1 + lcaIndexOut;
        path.hops = new address[](totalLength);

        // Copy tokenIn → LCA (ascending)
        for (uint256 i = 0; i <= lcaIndexIn; i++) {
            path.hops[i] = pathIn[i];
        }

        // Copy LCA → tokenOut (descending, skip LCA duplicate)
        for (uint256 i = 1; i <= lcaIndexOut; i++) {
            path.hops[lcaIndexIn + i] = pathOut[lcaIndexOut - i];
        }

        return path;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TREE QUERIES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Check if asset is the root
    /// @param $ Pool storage
    /// @param asset Asset to check
    /// @return True if asset is the root
    function isRoot(
        IPoolV1.PoolStorage storage $,
        address asset
    ) internal view returns (bool) {
        return asset == $.baseToken && $.assets[asset].anchor == address(0);
    }
}
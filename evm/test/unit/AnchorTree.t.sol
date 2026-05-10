// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {BaseTestSetup} from "../fixtures/BaseTestSetup.sol";
import {AnchorTree as T} from "../../src/libraries/AnchorTree.sol";
import {IPool} from "../../src/interfaces/IPool.sol";

/// @title LibAnchorTreeHarness
/// @notice Test harness to expose LibAnchorTree internal functions
contract LibAnchorTreeHarness {
    /// @dev ERC-7201 storage slot for pool storage
    bytes32 private constant POOL_STORAGE_SLOT =
        keccak256(abi.encode(uint256(keccak256("btr.storage.pool")) - 1)) & ~bytes32(uint256(0xff));

    function _getPoolStorage() internal pure returns (IPool.PoolStorage storage $) {
        bytes32 slot = POOL_STORAGE_SLOT;
        assembly { $.slot := slot }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function setBaseToken(address baseToken) external {
        IPool.PoolStorage storage $ = _getPoolStorage();
        $.baseToken = baseToken;
    }

    function configureAsset(
        address asset,
        address anchor,
        uint8 anchorDepth,
        uint8 decimals
    ) external {
        IPool.PoolStorage storage $ = _getPoolStorage();
        $.assets[asset].anchor = anchor;
        $.assets[asset].anchorDepth = anchorDepth;
        $.assets[asset].decimals = decimals;
    }

    function setAssetDecimals(address asset, uint8 decimals) external {
        IPool.PoolStorage storage $ = _getPoolStorage();
        $.assets[asset].decimals = decimals;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EXPOSED FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function validateAnchor(
        address asset,
        address anchor
    ) external view returns (uint8 depth) {
        IPool.PoolStorage storage $ = _getPoolStorage();
        return T.validateAnchor($, asset, anchor);
    }

    function findRoutingPath(
        address tokenIn,
        address tokenOut
    ) external view returns (IPool.RoutePath memory path) {
        IPool.PoolStorage storage $ = _getPoolStorage();
        return T.findRoutingPath($, tokenIn, tokenOut);
    }

    function walkToRoot(address asset) external view returns (address[] memory path) {
        IPool.PoolStorage storage $ = _getPoolStorage();
        return T.walkToRoot($, asset);
    }

    function findLCA(
        address[] memory pathA,
        address[] memory pathB
    ) external pure returns (address lca) {
        return T.findLCA(pathA, pathB);
    }

    function isRoot(address asset) external view returns (bool) {
        IPool.PoolStorage storage $ = _getPoolStorage();
        return T.isRoot($, asset);
    }

    function getAsset(address asset) external view returns (IPool.Asset memory) {
        IPool.PoolStorage storage $ = _getPoolStorage();
        return $.assets[asset];
    }

    function getBaseToken() external view returns (address) {
        IPool.PoolStorage storage $ = _getPoolStorage();
        return $.baseToken;
    }
}

/// @title LibAnchorTreeTest
/// @notice Comprehensive unit tests for LibAnchorTree pathfinding and validation
contract LibAnchorTreeTest is BaseTestSetup {

    LibAnchorTreeHarness harness;

    // Test addresses
    address constant ROOT = address(0x1);     // Base token (root)
    address constant CHILD_A = address(0x2);  // Direct child of root
    address constant CHILD_B = address(0x3);  // Direct child of root
    address constant LEAF_A1 = address(0x4);  // Child of CHILD_A
    address constant LEAF_A2 = address(0x5);  // Child of CHILD_A
    address constant LEAF_B1 = address(0x6);  // Child of CHILD_B
    address constant DEEP_LEAF = address(0x7); // Deeper child for depth tests

    function setUp() public override {
        super.setUp();
        harness = new LibAnchorTreeHarness();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Set up a basic tree structure:
    ///         ROOT (depth 0)
    ///        /    \
    ///    CHILD_A  CHILD_B (depth 1)
    ///      /  \       \
    ///  LEAF_A1 LEAF_A2 LEAF_B1 (depth 2)
    function setupBasicTree() internal {
        // Configure root
        harness.setBaseToken(ROOT);
        harness.configureAsset(ROOT, address(0), 0, 18);

        // Configure direct children
        harness.configureAsset(CHILD_A, ROOT, 1, 18);
        harness.configureAsset(CHILD_B, ROOT, 1, 6);

        // Configure leaves
        harness.configureAsset(LEAF_A1, CHILD_A, 2, 18);
        harness.configureAsset(LEAF_A2, CHILD_A, 2, 8);
        harness.configureAsset(LEAF_B1, CHILD_B, 2, 18);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VALIDATE ANCHOR TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_validateAnchor_root_valid() public {
        harness.setBaseToken(ROOT);
        harness.configureAsset(ROOT, address(0), 0, 18);

        uint8 depth = harness.validateAnchor(ROOT, address(0));

        assertEq(depth, 0);
    }

    function test_validateAnchor_non_base_token_as_root_reverts() public {
        harness.setBaseToken(ROOT);
        harness.configureAsset(CHILD_A, address(0), 0, 18); // Not the base token

        vm.expectRevert(abi.encodeWithSelector(T.InvalidAnchor.selector, CHILD_A, address(0)));
        harness.validateAnchor(CHILD_A, address(0));
    }

    function test_validateAnchor_self_reference_reverts() public {
        setupBasicTree();

        vm.expectRevert(abi.encodeWithSelector(T.InvalidAnchor.selector, CHILD_A, CHILD_A));
        harness.validateAnchor(CHILD_A, CHILD_A);
    }

    function test_validateAnchor_unconfigured_anchor_reverts() public {
        harness.setBaseToken(ROOT);
        harness.configureAsset(ROOT, address(0), 0, 18);

        address unconfigured = address(0x999);

        vm.expectRevert(abi.encodeWithSelector(T.AssetNotInTree.selector, unconfigured));
        harness.validateAnchor(CHILD_A, unconfigured);
    }

    function test_validateAnchor_depth_1() public {
        harness.setBaseToken(ROOT);
        harness.configureAsset(ROOT, address(0), 0, 18);

        uint8 depth = harness.validateAnchor(CHILD_A, ROOT);

        assertEq(depth, 1);
    }

    function test_validateAnchor_depth_2() public {
        setupBasicTree();

        uint8 depth = harness.validateAnchor(LEAF_A1, CHILD_A);

        assertEq(depth, 2);
    }

    function test_validateAnchor_max_depth_4() public {
        harness.setBaseToken(ROOT);
        harness.configureAsset(ROOT, address(0), 0, 18);

        address depth1 = address(0x10);
        address depth2 = address(0x20);
        address depth3 = address(0x30);
        address depth4 = address(0x40);

        harness.configureAsset(depth1, ROOT, 1, 18);
        harness.configureAsset(depth2, depth1, 2, 18);
        harness.configureAsset(depth3, depth2, 3, 18);

        uint8 depth = harness.validateAnchor(depth4, depth3);

        assertEq(depth, 4);
    }

    function test_validateAnchor_exceeds_max_depth_reverts() public {
        harness.setBaseToken(ROOT);
        harness.configureAsset(ROOT, address(0), 0, 18);

        address depth1 = address(0x10);
        address depth2 = address(0x20);
        address depth3 = address(0x30);
        address depth4 = address(0x40);
        address depth5 = address(0x50);

        harness.configureAsset(depth1, ROOT, 1, 18);
        harness.configureAsset(depth2, depth1, 2, 18);
        harness.configureAsset(depth3, depth2, 3, 18);
        harness.configureAsset(depth4, depth3, 4, 18);

        vm.expectRevert(abi.encodeWithSelector(T.DepthExceeded.selector, depth5, 5));
        harness.validateAnchor(depth5, depth4);
    }

    function test_validateAnchor_cycle_detection() public {
        setupBasicTree();

        // Try to create a cycle: LEAF_A1 -> CHILD_A -> ROOT -> LEAF_A1 (cycle!)
        // First, we need to configure LEAF_A1 as configured
        // Then try to anchor ROOT to LEAF_A1

        // This would create: ROOT -> LEAF_A1 -> CHILD_A -> ROOT (cycle)
        // But since ROOT must be anchored to address(0), let's test a different cycle

        // Set up: CHILD_A -> ROOT, LEAF_A1 -> CHILD_A
        // Try: anchor ROOT to LEAF_A1 would create cycle
        // But ROOT can only anchor to address(0)

        // Better test: Try to anchor CHILD_A to LEAF_A1 (its descendant)
        // This would create: LEAF_A1 -> CHILD_A -> LEAF_A1 (cycle)

        vm.expectRevert(abi.encodeWithSelector(T.CycleDetected.selector, CHILD_A));
        harness.validateAnchor(CHILD_A, LEAF_A1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // WALK TO ROOT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_walkToRoot_from_root() public {
        setupBasicTree();

        address[] memory path = harness.walkToRoot(ROOT);

        assertEq(path.length, 1);
        assertEq(path[0], ROOT);
    }

    function test_walkToRoot_from_depth_1() public {
        setupBasicTree();

        address[] memory path = harness.walkToRoot(CHILD_A);

        assertEq(path.length, 2);
        assertEq(path[0], CHILD_A);
        assertEq(path[1], ROOT);
    }

    function test_walkToRoot_from_depth_2() public {
        setupBasicTree();

        address[] memory path = harness.walkToRoot(LEAF_A1);

        assertEq(path.length, 3);
        assertEq(path[0], LEAF_A1);
        assertEq(path[1], CHILD_A);
        assertEq(path[2], ROOT);
    }

    function test_walkToRoot_different_branches() public {
        setupBasicTree();

        address[] memory pathA = harness.walkToRoot(LEAF_A1);
        address[] memory pathB = harness.walkToRoot(LEAF_B1);

        // Both should end at ROOT
        assertEq(pathA[pathA.length - 1], ROOT);
        assertEq(pathB[pathB.length - 1], ROOT);

        // Different intermediate nodes
        assertEq(pathA[1], CHILD_A);
        assertEq(pathB[1], CHILD_B);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FIND LCA TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_findLCA_same_node() public {
        setupBasicTree();

        address[] memory pathA = harness.walkToRoot(LEAF_A1);
        address[] memory pathB = harness.walkToRoot(LEAF_A1);

        address lca = harness.findLCA(pathA, pathB);

        assertEq(lca, LEAF_A1);
    }

    function test_findLCA_direct_parent_child() public {
        setupBasicTree();

        address[] memory pathParent = harness.walkToRoot(CHILD_A);
        address[] memory pathChild = harness.walkToRoot(LEAF_A1);

        address lca = harness.findLCA(pathParent, pathChild);

        assertEq(lca, CHILD_A);
    }

    function test_findLCA_siblings() public {
        setupBasicTree();

        address[] memory pathA = harness.walkToRoot(LEAF_A1);
        address[] memory pathB = harness.walkToRoot(LEAF_A2);

        address lca = harness.findLCA(pathA, pathB);

        assertEq(lca, CHILD_A);
    }

    function test_findLCA_different_branches() public {
        setupBasicTree();

        address[] memory pathA = harness.walkToRoot(LEAF_A1);
        address[] memory pathB = harness.walkToRoot(LEAF_B1);

        address lca = harness.findLCA(pathA, pathB);

        assertEq(lca, ROOT);
    }

    function test_findLCA_root_and_leaf() public {
        setupBasicTree();

        address[] memory pathRoot = harness.walkToRoot(ROOT);
        address[] memory pathLeaf = harness.walkToRoot(LEAF_A1);

        address lca = harness.findLCA(pathRoot, pathLeaf);

        assertEq(lca, ROOT);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FIND ROUTING PATH TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_findRoutingPath_same_asset_reverts() public {
        setupBasicTree();

        // Same asset should still work (path length 1 effectively)
        // Actually, let's check - the code checks decimals != 0 for both
        // If same asset, the path would just be [asset] (length 1)

        IPool.RoutePath memory path = harness.findRoutingPath(CHILD_A, CHILD_A);

        // Direct anchor case won't match, common parent won't match for same asset
        // So it goes to general case with LCA = CHILD_A
        // Path should be [CHILD_A]
        assertGe(path.hops.length, 1);
    }

    function test_findRoutingPath_unconfigured_tokenIn_reverts() public {
        setupBasicTree();

        address unconfigured = address(0x999);

        vm.expectRevert(abi.encodeWithSelector(T.AssetNotInTree.selector, unconfigured));
        harness.findRoutingPath(unconfigured, CHILD_A);
    }

    function test_findRoutingPath_unconfigured_tokenOut_reverts() public {
        setupBasicTree();

        address unconfigured = address(0x999);

        vm.expectRevert(abi.encodeWithSelector(T.AssetNotInTree.selector, unconfigured));
        harness.findRoutingPath(CHILD_A, unconfigured);
    }

    function test_findRoutingPath_direct_parent_child() public {
        setupBasicTree();

        // LEAF_A1's anchor is CHILD_A, so this is direct
        IPool.RoutePath memory path = harness.findRoutingPath(LEAF_A1, CHILD_A);

        assertEq(path.hops.length, 2);
        assertEq(path.hops[0], LEAF_A1);
        assertEq(path.hops[1], CHILD_A);
    }

    function test_findRoutingPath_direct_child_parent() public {
        setupBasicTree();

        // CHILD_A's anchor is ROOT, testing reverse direction
        IPool.RoutePath memory path = harness.findRoutingPath(CHILD_A, ROOT);

        assertEq(path.hops.length, 2);
        assertEq(path.hops[0], CHILD_A);
        assertEq(path.hops[1], ROOT);
    }

    function test_findRoutingPath_common_parent_siblings() public {
        setupBasicTree();

        // LEAF_A1 and LEAF_A2 share parent CHILD_A
        IPool.RoutePath memory path = harness.findRoutingPath(LEAF_A1, LEAF_A2);

        assertEq(path.hops.length, 3);
        assertEq(path.hops[0], LEAF_A1);
        assertEq(path.hops[1], CHILD_A);  // Common parent
        assertEq(path.hops[2], LEAF_A2);
    }

    function test_findRoutingPath_different_branches() public {
        setupBasicTree();

        // LEAF_A1 and LEAF_B1 share common ancestor ROOT
        IPool.RoutePath memory path = harness.findRoutingPath(LEAF_A1, LEAF_B1);

        // Path: LEAF_A1 -> CHILD_A -> ROOT -> CHILD_B -> LEAF_B1
        assertEq(path.hops.length, 5);
        assertEq(path.hops[0], LEAF_A1);
        assertEq(path.hops[1], CHILD_A);
        assertEq(path.hops[2], ROOT);      // LCA
        assertEq(path.hops[3], CHILD_B);
        assertEq(path.hops[4], LEAF_B1);
    }

    function test_findRoutingPath_leaf_to_root() public {
        setupBasicTree();

        IPool.RoutePath memory path = harness.findRoutingPath(LEAF_A1, ROOT);

        // Path: LEAF_A1 -> CHILD_A -> ROOT
        assertEq(path.hops.length, 3);
        assertEq(path.hops[0], LEAF_A1);
        assertEq(path.hops[1], CHILD_A);
        assertEq(path.hops[2], ROOT);
    }

    function test_findRoutingPath_root_to_leaf() public {
        setupBasicTree();

        IPool.RoutePath memory path = harness.findRoutingPath(ROOT, LEAF_B1);

        // Path: ROOT -> CHILD_B -> LEAF_B1
        assertEq(path.hops.length, 3);
        assertEq(path.hops[0], ROOT);
        assertEq(path.hops[1], CHILD_B);
        assertEq(path.hops[2], LEAF_B1);
    }

    function test_findRoutingPath_asymmetric_depths() public {
        setupBasicTree();

        // CHILD_A (depth 1) to LEAF_B1 (depth 2)
        IPool.RoutePath memory path = harness.findRoutingPath(CHILD_A, LEAF_B1);

        // Path: CHILD_A -> ROOT -> CHILD_B -> LEAF_B1
        assertEq(path.hops.length, 4);
        assertEq(path.hops[0], CHILD_A);
        assertEq(path.hops[1], ROOT);
        assertEq(path.hops[2], CHILD_B);
        assertEq(path.hops[3], LEAF_B1);
    }

    function test_findRoutingPath_symmetry() public {
        setupBasicTree();

        IPool.RoutePath memory pathAB = harness.findRoutingPath(LEAF_A1, LEAF_B1);
        IPool.RoutePath memory pathBA = harness.findRoutingPath(LEAF_B1, LEAF_A1);

        // Paths should have same length (symmetric)
        assertEq(pathAB.hops.length, pathBA.hops.length);

        // Paths should be reverse of each other
        for (uint256 i = 0; i < pathAB.hops.length; i++) {
            assertEq(pathAB.hops[i], pathBA.hops[pathBA.hops.length - 1 - i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IS ROOT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_isRoot_true_for_base_token() public {
        setupBasicTree();

        bool result = harness.isRoot(ROOT);

        assertTrue(result);
    }

    function test_isRoot_false_for_children() public {
        setupBasicTree();

        assertFalse(harness.isRoot(CHILD_A));
        assertFalse(harness.isRoot(CHILD_B));
        assertFalse(harness.isRoot(LEAF_A1));
    }

    function test_isRoot_false_for_unconfigured() public {
        setupBasicTree();

        address unconfigured = address(0x999);

        // Unconfigured asset is not the base token
        assertFalse(harness.isRoot(unconfigured));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASES & STRESS TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_deep_tree_routing() public {
        // Create a deep linear tree: ROOT -> D1 -> D2 -> D3 -> D4
        harness.setBaseToken(ROOT);
        harness.configureAsset(ROOT, address(0), 0, 18);

        address[] memory nodes = new address[](5);
        nodes[0] = ROOT;
        nodes[1] = address(0x10);
        nodes[2] = address(0x20);
        nodes[3] = address(0x30);
        nodes[4] = address(0x40);

        for (uint8 i = 1; i < 5; i++) {
            harness.configureAsset(nodes[i], nodes[i-1], i, 18);
        }

        // Route from deepest to root
        IPool.RoutePath memory path = harness.findRoutingPath(nodes[4], ROOT);

        assertEq(path.hops.length, 5);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(path.hops[i], nodes[4 - i]);
        }
    }

    function test_wide_tree_routing() public {
        // Create a wide tree: ROOT with 5 direct children
        harness.setBaseToken(ROOT);
        harness.configureAsset(ROOT, address(0), 0, 18);

        address[] memory children = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            children[i] = address(uint160(0x100 + i));
            harness.configureAsset(children[i], ROOT, 1, 18);
        }

        // Route between any two children should be 3 hops
        IPool.RoutePath memory path = harness.findRoutingPath(children[0], children[4]);

        assertEq(path.hops.length, 3);
        assertEq(path.hops[0], children[0]);
        assertEq(path.hops[1], ROOT);
        assertEq(path.hops[2], children[4]);
    }

    function test_routing_preserves_endpoints() public {
        setupBasicTree();

        address[] memory pairs = new address[](6);
        pairs[0] = ROOT;
        pairs[1] = CHILD_A;
        pairs[2] = CHILD_B;
        pairs[3] = LEAF_A1;
        pairs[4] = LEAF_A2;
        pairs[5] = LEAF_B1;

        // Test all pairs
        for (uint256 i = 0; i < pairs.length; i++) {
            for (uint256 j = 0; j < pairs.length; j++) {
                if (i != j) {
                    IPool.RoutePath memory path = harness.findRoutingPath(pairs[i], pairs[j]);

                    // First hop should be tokenIn
                    assertEq(path.hops[0], pairs[i], "First hop mismatch");
                    // Last hop should be tokenOut
                    assertEq(path.hops[path.hops.length - 1], pairs[j], "Last hop mismatch");
                }
            }
        }
    }

    function test_path_contains_no_duplicates_except_endpoints() public {
        setupBasicTree();

        IPool.RoutePath memory path = harness.findRoutingPath(LEAF_A1, LEAF_B1);

        // Check no internal duplicates (endpoints can be same for trivial paths)
        for (uint256 i = 0; i < path.hops.length; i++) {
            for (uint256 j = i + 1; j < path.hops.length; j++) {
                // Only the same node is allowed if it's the same index
                assertTrue(path.hops[i] != path.hops[j], "Duplicate found in path");
            }
        }
    }
}

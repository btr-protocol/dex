// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Bridge} from "../src/Bridge.sol";
import {IBridge} from "../src/interfaces/IBridge.sol";
import {LZEndpointV2} from "../src/interfaces/external/ILZEndpointV2.sol";
import {IERC7802} from "../src/interfaces/external/IERC7802.sol";
import {Treasury} from "../src/Treasury.sol";
import {Distributor} from "../src/Distributor.sol";
import {IDistributor} from "../src/interfaces/IDistributor.sol";
import {BTRToken} from "./fixtures/BTRToken.sol";
import {MockAC} from "./fixtures/BaseTestSetup.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Maths as M} from "../src/libraries/Maths.sol";

/// @notice Mock LZ endpoint reused from R10.
contract MockLZEndpointR11 {
    function quote(LZEndpointV2.SendParam calldata, bool)
        external pure returns (LZEndpointV2.MessagingFee memory fee)
    {
        return LZEndpointV2.MessagingFee({nativeFee: 1 wei, lzTokenFee: 0});
    }
    function send(LZEndpointV2.SendParam calldata, LZEndpointV2.MessagingFee calldata fee, address)
        external payable returns (LZEndpointV2.MessagingReceipt memory r)
    {
        r.guid = bytes32(0);
        r.nonce = uint64(1);
        r.fee = fee;
    }
}

contract MockBridgeableR11 is IERC7802 {
    uint256 public minted;
    uint256 public burned;
    function crosschainMint(address, uint256 amount, bytes calldata) external { minted += amount; }
    function crosschainBurn(address, uint256 amount, bytes calldata) external { burned += amount; }
}

/// @title Phase42CR11Test
/// @notice Phase 42C R11 cleanup:
///   - F-A3-R11-1 (LOW): Bridge inbound bucket decimals incoherence.
///   - F-A1-R11-1 (INFO): Treasury initializeEmissions ordering vs initializeTGE.
///   - F-A1-R11-2 (INFO): Distributor manager lowering totalAllocated below totalClaimed.
contract Phase42CR11Test is Test {

    // ─────────────────────────────────────────────────────────────────────
    // F-A3-R11-1 — Bridge inbound bucket decimals coherence
    // ─────────────────────────────────────────────────────────────────────

    Bridge bridge;
    MockLZEndpointR11 lz;
    MockBridgeableR11 token;

    address constant BRIDGE_OWNER = address(0xA11CE);
    uint32 constant SRC_EID = 7;
    bytes32 constant SRC_PEER = bytes32(uint256(0xBEEFCAFE));

    function _setUpBridgeWithDecimals(uint8 dec, uint256 limitRaw) internal {
        lz = new MockLZEndpointR11();
        token = new MockBridgeableR11();
        bridge = new Bridge(address(lz));
        bridge.initialize(BRIDGE_OWNER);

        vm.prank(BRIDGE_OWNER);
        bridge.setTokenConfig(address(token), limitRaw, dec, 100, false);

        vm.startPrank(BRIDGE_OWNER);
        bridge.requestSetPeer(SRC_EID, SRC_PEER);
        vm.warp(block.timestamp + SC.BASE_TIMELOCK + 1);
        bridge.executeSetPeer(SRC_EID);
        vm.stopPrank();
    }

    function _lzReceive(uint256 amount, uint256 nonce) internal {
        LZEndpointV2.Origin memory origin = LZEndpointV2.Origin({
            srcEid: SRC_EID, sender: SRC_PEER, nonce: uint64(nonce)
        });
        bytes32 guid = keccak256(abi.encode(SRC_EID, nonce, amount, block.timestamp));
        bytes memory msg_ = abi.encode(
            bytes32(uint256(uint160(address(0xCAFE)))), address(token), amount
        );
        vm.prank(address(lz));
        bridge.lzReceive(origin, guid, msg_, address(0), "");
    }

    /// @notice With non-18 decimals (e.g. USDC=6), the inbound bucket must encode/decode at the
    ///         token's actual decimals so `getRemainingLimits` view agrees with logic. Pre-fix:
    ///         logic used hardcoded 18 → view (decoding via b64Decimals) reported wildly wrong
    ///         remaining-inbound numbers.
    function test_F_A3_R11_1_inboundView_matchesLogic_at6Decimals() public {
        // Limit 1000 USDC at 6 decimals.
        _setUpBridgeWithDecimals(6, 1_000e6);

        // Consume 250 USDC inbound.
        _lzReceive(250e6, 1);
        assertEq(token.minted(), 250e6, "mint exact 250 USDC");

        // View must report 750 USDC remaining inbound (1000 - 250). Pre-fix this
        // would be off by 10^12 because storage was tagged at decimals=18.
        (, uint256 inboundRemaining) = bridge.getRemainingLimits(address(token));
        assertEq(inboundRemaining, 750e6, "view inbound must equal 1000e6 - 250e6 at 6dec");

        // Logic agrees: another 750 USDC fills exactly to cap.
        _lzReceive(750e6, 2);
        assertEq(token.minted(), 1_000e6, "exact cap fill at 6dec");

        (, uint256 inboundRemaining2) = bridge.getRemainingLimits(address(token));
        assertEq(inboundRemaining2, 0, "view at-cap reads 0");
    }

    // ─────────────────────────────────────────────────────────────────────
    // F-A1-R11-1 — Treasury.initializeEmissions ordering guard
    // ─────────────────────────────────────────────────────────────────────

    /// @notice initializeEmissions called AFTER initializeTGE must revert. Pre-fix this would
    ///         silently set emissionsSchedule.totalAllocation but leave maxSupply (snapshotted
    ///         at TGE) unchanged → mintEmissionsToDistributor reverts on _enforceMaxSupply.
    function test_F_A1_R11_1_initializeEmissions_postTGE_reverts() public {
        BTRToken gov = new BTRToken("Gov", "GOV", 18);
        Treasury t = new Treasury(address(gov));
        t.initialize(address(this));

        // Run TGE first. BTRToken has 1M premint to test contract, so use 0/0 amounts to
        // sidestep the maxSupply check (we only care about the ordering guard).
        address[] memory bens = new address[](0);
        uint256[] memory allocs = new uint256[](0);
        t.initializeTGE(0, 0, bens, allocs);

        // Now attempt initializeEmissions → must revert.
        vm.expectRevert(Err.InvalidState.selector);
        t.initializeEmissions(500_000e18);
    }

    /// @notice Sanity: pre-TGE initializeEmissions still succeeds (regression on positive path).
    function test_F_A1_R11_1_initializeEmissions_preTGE_succeeds() public {
        BTRToken gov = new BTRToken("Gov", "GOV", 18);
        Treasury t = new Treasury(address(gov));
        t.initialize(address(this));

        t.initializeEmissions(500_000e18);

        // TGE then includes emissions in maxSupply (use 0/0 amounts; the BTRToken fixture
        // premints 1M to the deployer so any treasury/seed mint here would clash with maxSupply).
        address[] memory bens = new address[](0);
        uint256[] memory allocs = new uint256[](0);
        t.initializeTGE(0, 0, bens, allocs);

        assertEq(t.getMaxSupply(), 500_000e18, "maxSupply must include pre-TGE emissions cap");
    }

    // ─────────────────────────────────────────────────────────────────────
    // F-A1-R11-2 — Distributor.updateCampaignRoot floor at totalClaimed
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Seed `_totalClaimed[pool][campaignId]` on the singleton Distributor (Phase 42H.B.3c).
    ///      Layout: slot 0 = nextCampaignId, slot 1 = _campaigns, slot 2 = _campaignClaimed,
    ///      slot 3 = _totalClaimed (mapping(address pool => mapping(uint256 => uint256))).
    function _seedTotalClaimed(address dist, address pool, uint256 campaignId, uint256 amount) internal {
        bytes32 inner = keccak256(abi.encode(pool, uint256(3)));
        bytes32 slot = keccak256(abi.encode(campaignId, uint256(inner)));
        vm.store(dist, slot, bytes32(amount));
    }

    /// @notice Manager attempting to lower totalAllocated below totalClaimed must revert.
    ///         Pre-fix: would silently brick all subsequent claims (the Phase 42D A3-4 cap
    ///         guard at claimCampaign reverts when totalClaimed > totalAllocated).
    function test_F_A1_R11_2_updateCampaignRoot_belowTotalClaimed_reverts() public {
        // MockAC owner = address(this) so onlyOwner gate passes for createTokenCampaign.
        Distributor dist = new Distributor(address(new MockAC(address(this))));
        address distAddr = address(dist);
        address pool = address(0xB001);

        BTRToken reward = new BTRToken("RWD", "RWD", 18);

        address manager = address(0xA8A6E7);
        uint256 campaignId = dist.createTokenCampaign(pool, address(reward), manager);

        // Initial root: totalClaimable = 1000e18.
        bytes32 root1 = bytes32(uint256(0x1));
        // Pre-fund Distributor so the balance check inside updateCampaignRoot passes.
        reward.mint(distAddr, 1_000e18);
        vm.prank(manager);
        dist.updateCampaignRoot(pool, campaignId, root1, uint32(block.timestamp), 1_000e18);

        // Simulate accumulated claims: totalClaimed = 600e18.
        _seedTotalClaimed(distAddr, pool, campaignId, 600e18);

        // Manager mistakenly lowers totalAllocated below totalClaimed → must revert.
        vm.prank(manager);
        vm.expectRevert(Err.InvalidInput.selector);
        dist.updateCampaignRoot(pool, campaignId, bytes32(uint256(0x2)), uint32(block.timestamp), 500e18);

        // At-or-above totalClaimed allowed (no revert on equality boundary).
        vm.prank(manager);
        dist.updateCampaignRoot(pool, campaignId, bytes32(uint256(0x3)), uint32(block.timestamp), 600e18);
    }
}

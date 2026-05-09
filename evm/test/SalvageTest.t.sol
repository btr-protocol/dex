// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Treasury} from "../src/Treasury.sol";
import {BTRToken} from "./fixtures/BTRToken.sol";
import {Err} from "@btr-peripheral/Errors.sol";
import {LibConstants as C} from "../src/libraries/LibConstants.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title SalvageTest
/// @notice Owner-only stuck-token sweep on Treasury (alm Vault.salvage parity).
contract SalvageTest is Test {
    Treasury treasury;
    BTRToken stuck;
    BTRToken gov;
    address owner = address(0xA11CE);
    address attacker = address(0xBADD1E);
    address receiver = address(0xBEEF);

    function setUp() public {
        gov = new BTRToken("Gov", "GOV", 18);
        treasury = new Treasury(address(gov));
        treasury.initialize(owner);
        stuck = new BTRToken("Stuck", "STK", 18);
        // Seed stuck tokens directly into the Treasury balance.
        stuck.transfer(address(treasury), 1_000 ether);
        // Seed native ETH.
        vm.deal(address(treasury), 5 ether);
    }

    function test_salvage_owner_erc20() public {
        uint256 amount = 750 ether;
        vm.prank(owner);
        treasury.salvage(address(stuck), receiver, amount);
        assertEq(stuck.balanceOf(receiver), amount);
        assertEq(stuck.balanceOf(address(treasury)), 1_000 ether - amount);
    }

    function test_salvage_owner_native() public {
        uint256 amount = 2 ether;
        uint256 prev = receiver.balance;
        vm.prank(owner);
        treasury.salvage(C.NATIVE, receiver, amount);
        assertEq(receiver.balance, prev + amount);
    }

    function test_salvage_nonOwner_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(Ownable.Unauthorized.selector);
        treasury.salvage(address(stuck), receiver, 1 ether);
    }

    function test_salvage_zeroReceiver_reverts() public {
        vm.prank(owner);
        vm.expectRevert(Err.ZeroValue.selector);
        treasury.salvage(address(stuck), address(0), 1 ether);
    }

    function test_salvage_zeroAmount_reverts() public {
        vm.prank(owner);
        vm.expectRevert(Err.ZeroValue.selector);
        treasury.salvage(address(stuck), receiver, 0);
    }

    function test_salvage_amountExceedsBalance_reverts() public {
        // SafeTransferLib reverts on transfer failure (insufficient bal in BTRToken returns false → wraps).
        vm.prank(owner);
        vm.expectRevert();
        treasury.salvage(address(stuck), receiver, 1_000_000 ether);
    }
}

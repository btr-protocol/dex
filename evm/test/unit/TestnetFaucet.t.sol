// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {TestnetFaucet} from "../../src/testnet/TestnetFaucet.sol";
import {TestnetERC20} from "../../src/testnet/TestnetERC20.sol";

contract TestnetFaucetTest is Test {
  TestnetFaucet faucet;
  TestnetERC20 usdc;
  address owner = address(0xA11CE);
  address alice = address(0xB0B);
  address bob = address(0xB0B2);

  function setUp() public {
    vm.prank(owner);
    usdc = new TestnetERC20("USD Coin", "USDC", 18);
    vm.prank(owner);
    faucet = new TestnetFaucet(owner);

    vm.prank(owner);
    faucet.setCap(address(usdc), 10_000 ether);

    vm.prank(owner);
    usdc.mint(owner, 100_000 ether);
    vm.prank(owner);
    usdc.approve(address(faucet), type(uint256).max);
    vm.prank(owner);
    faucet.fund(address(usdc), 100_000 ether);
  }

  function test_ownerWhitelistedByDefault() public view {
    assertTrue(faucet.whitelisted(owner));
    assertFalse(faucet.whitelisted(alice));
  }

  function test_claimRevertsIfNotWhitelisted() public {
    vm.prank(alice);
    vm.expectRevert(TestnetFaucet.NotWhitelisted.selector);
    faucet.claim(address(usdc));
  }

  function test_registerThenClaimDailyCap() public {
    vm.prank(alice);
    faucet.register();

    vm.prank(alice);
    faucet.claim(address(usdc));
    assertEq(usdc.balanceOf(alice), 10_000 ether);
    assertEq(faucet.remaining(alice, address(usdc)), 0);

    vm.prank(alice);
    vm.expectRevert(TestnetFaucet.CapExhausted.selector);
    faucet.claim(address(usdc));

    // Next UTC day resets.
    vm.warp(block.timestamp + 1 days);
    assertEq(faucet.remaining(alice, address(usdc)), 10_000 ether);
    vm.prank(alice);
    faucet.claim(address(usdc));
    assertEq(usdc.balanceOf(alice), 20_000 ether);
  }

  function test_ownerCanRevoke() public {
    vm.prank(alice);
    faucet.register();
    vm.prank(owner);
    faucet.setWhitelisted(alice, false);

    vm.prank(alice);
    vm.expectRevert(TestnetFaucet.NotWhitelisted.selector);
    faucet.claim(address(usdc));
  }

  function test_mintRestrictedToMinter() public {
    vm.prank(bob);
    vm.expectRevert(TestnetERC20.NotMinter.selector);
    usdc.mint(bob, 1 ether);
  }
}

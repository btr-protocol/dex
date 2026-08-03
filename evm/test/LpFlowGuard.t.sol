// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Err} from "@btr-shared/Errors.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {PoolIndexPinFixture} from "./PoolIndexPin.t.sol";
import {NO_DEADLINE} from "./fixtures/BaseTestSetup.sol";

/// @title LpFlowGuardTest
/// @notice Anti-JIT guard, expressed through the POOL surface only, so it compiles unchanged
///         against the pre-tokenization source. The frozen-amount lock keeps that source's
///         invariant (no share leaves within `cooldown` of its own mint) while dropping its
///         all-or-nothing side effect (a fresh top-up froze the whole aged position), and it caps
///         the window one untimelocked admin key can impose.
contract LpFlowGuardTest is PoolIndexPinFixture {
  uint256 constant OPEN = 1000e18;
  /// @dev Literal, not `C.MAX_FLOW_COOLDOWN`, so this file compiles against the pre-cap source too.
  uint16 constant MAX_COOLDOWN = 300;
  uint256 constant TOPUP = 1e15;

  function _lp() internal view returns (uint256) {
    return pool.getLPBalance(LP, address(tok));
  }

  /// Invariant half, unchanged by the lock: a freshly minted share cannot exit in its own window.
  function test_a_fresh_mint_cannot_exit_within_the_cooldown() public {
    vm.prank(LP);
    pool.deposit(address(tok), OPEN);
    uint256 lp = _lp();
    vm.prank(LP);
    vm.expectRevert();
    pool.withdraw(address(tok), lp, 0, NO_DEADLINE);

    skip(uint256(C.DEFAULT_FLOW_COOLDOWN) + 1);
    vm.prank(LP);
    pool.withdraw(address(tok), lp, 0, NO_DEADLINE);
    assertEq(_lp(), 0, "the position exits once its window elapses");
  }

  /// A dust top-up must freeze the dust, not the aged position beside it. The pre-tokenization
  /// source overwrote a single per-holder timestamp, so this withdraw reverted `CooldownActive`
  /// and an LP could be locked out of a matured position indefinitely, once per window, for dust.
  function test_an_aged_balance_survives_a_fresh_dust_deposit() public {
    vm.prank(LP);
    pool.deposit(address(tok), OPEN);
    uint256 aged = _lp();
    skip(3600);

    vm.prank(LP);
    pool.deposit(address(tok), TOPUP);
    uint256 fresh = _lp() - aged;
    assertGt(fresh, 0, "the top-up minted");

    vm.prank(LP);
    pool.withdraw(address(tok), aged, 0, NO_DEADLINE);
    assertEq(_lp(), fresh, "only the fresh parcel stays locked");

    // ...and the fresh parcel is still genuinely frozen for its own window.
    vm.prank(LP);
    vm.expectRevert();
    pool.withdraw(address(tok), fresh, 0, NO_DEADLINE);
  }

  /// The cooldown now gates transfers of a live receipt, not just withdraw, and `setFlowCooldown`
  /// carries no timelock. The ceiling IS the worst-case unavailability one compromised key buys.
  function test_flow_cooldown_is_capped_at_five_minutes() public {
    vm.prank(OWNER);
    vm.expectRevert(Err.InvalidInput.selector);
    admin.setFlowCooldown(address(pool), MAX_COOLDOWN + 1);

    vm.prank(OWNER);
    vm.expectRevert(Err.InvalidInput.selector);
    admin.setFlowCooldown(address(pool), type(uint16).max);

    // The ceiling itself, and zero as an explicit disable, both stay reachable.
    vm.prank(OWNER);
    admin.setFlowCooldown(address(pool), MAX_COOLDOWN);
    vm.prank(OWNER);
    admin.setFlowCooldown(address(pool), 0);

    vm.prank(LP);
    pool.deposit(address(tok), OPEN);
    uint256 lp = _lp();
    vm.prank(LP);
    pool.withdraw(address(tok), lp, 0, NO_DEADLINE);
    assertEq(_lp(), 0, "cooldown 0 disables the guard outright");
  }
}

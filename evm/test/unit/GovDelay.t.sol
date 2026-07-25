// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";

/// @notice `Constants.govDelay` is the ONLY lever shortening governance timelocks. A regression
///         here either bricks testnet iteration (full 7d windows) or — far worse — ships
///         5-minute governance to a production chain. Both directions are asserted.
contract GovDelayTest is Test {
  uint256 internal constant ETH_MAINNET = 1;
  uint256 internal constant BSC_MAINNET = 56;
  uint256 internal constant ANVIL = 31_337;

  /// @dev via_ir LANDMINE (same class as the known warp/timestamp one): `block.chainid` is an
  ///      environment read the optimizer treats as loop-invariant and HOISTS above `vm.chainId`,
  ///      which it does not model. Read inline, every assertion below silently tests the default
  ///      31337. Routing through an EXTERNAL call boundary (`this.*`) forces a fresh read per
  ///      invocation. Do NOT inline these back.
  function isShortExt() external view returns (bool) {
    return SC.isShortTimelockTestnet();
  }

  function govDelayExt(uint48 prod) external view returns (uint48) {
    return SC.govDelay(prod);
  }

  /// @dev Every array literal below casts its FIRST element explicitly: Solidity infers a literal
  ///      array's type from element 0, so `[97, 11155111]` becomes uint8[2] and silently truncates.
  function _prodTiers() internal pure returns (uint48[4] memory) {
    return [
      uint48(SC.CRITICAL_TIMELOCK), SC.HIGH_TIMELOCK, SC.BASE_TIMELOCK, SC.LOW_TIMELOCK
    ];
  }

  function _shortTiers() internal pure returns (uint48[4] memory) {
    return [uint48(1 hours), uint48(30 minutes), uint48(15 minutes), uint48(5 minutes)];
  }

  function test_testnetsGetShortDelays() public {
    uint256[2] memory testnets = [uint256(SC.CHAPEL_CHAIN_ID), SC.SEPOLIA_CHAIN_ID];
    uint48[4] memory prod = _prodTiers();
    uint48[4] memory short_ = _shortTiers();
    for (uint256 c; c < testnets.length; ++c) {
      vm.chainId(testnets[c]);
      assertTrue(this.isShortExt(), "testnet not gated short");
      for (uint256 i; i < prod.length; ++i) {
        assertEq(this.govDelayExt(prod[i]), short_[i], "testnet tier not shortened");
      }
    }
  }

  /// @dev The allow-list is positive, so any chain that is not explicitly a testnet MUST keep
  ///      full production delays — including anvil, whose tests encode mainnet assumptions.
  function test_nonTestnetChainsKeepProductionDelays() public {
    uint256[3] memory chains = [uint256(ETH_MAINNET), BSC_MAINNET, ANVIL];
    uint48[4] memory prod = _prodTiers();
    for (uint256 c; c < chains.length; ++c) {
      vm.chainId(chains[c]);
      assertFalse(this.isShortExt(), "non-testnet gated short");
      for (uint256 i; i < prod.length; ++i) {
        assertEq(this.govDelayExt(prod[i]), prod[i], "production delay was shortened");
      }
    }
  }

  /// @dev Mainnet never shortens anything, including the upgrade/grace windows.
  function test_mainnetUpgradeAndGraceUnchanged() public {
    vm.chainId(ETH_MAINNET);
    assertEq(this.govDelayExt(SC.UPGRADE_TIMELOCK), SC.UPGRADE_TIMELOCK, "upgrade shortened");
    assertEq(this.govDelayExt(SC.GRACE_PERIOD), SC.GRACE_PERIOD, "grace shortened");
  }

  /// @dev Pins the KNOWN value-collision documented on govDelay: UPGRADE_TIMELOCK and
  ///      GRACE_PERIOD share CRITICAL_TIMELOCK's 7-day value, so on a testnet they map to 1 hour.
  ///      No caller routes them through govDelay today; this test exists so that if someone
  ///      starts, the surprise is a red test rather than a 1-hour UUPS window.
  function test_upgradeGraceValueCollisionOnTestnet() public {
    assertEq(SC.UPGRADE_TIMELOCK, SC.CRITICAL_TIMELOCK, "tier values diverged: revisit govDelay");
    assertEq(SC.GRACE_PERIOD, SC.CRITICAL_TIMELOCK, "tier values diverged: revisit govDelay");
    vm.chainId(SC.SEPOLIA_CHAIN_ID);
    assertEq(this.govDelayExt(SC.UPGRADE_TIMELOCK), 1 hours, "collision behaviour changed");
  }

  /// @dev An unrecognized tier must pass through untouched rather than fall into a default.
  function testFuzz_unknownTierPassesThrough(uint48 d) public {
    uint48[4] memory prod = _prodTiers();
    for (uint256 i; i < prod.length; ++i) {
      vm.assume(d != prod[i]);
    }
    vm.chainId(SC.SEPOLIA_CHAIN_ID);
    assertEq(this.govDelayExt(d), d, "unknown tier remapped");
  }
}

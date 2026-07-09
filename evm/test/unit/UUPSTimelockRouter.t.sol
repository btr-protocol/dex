// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {LibClone} from "solady/utils/LibClone.sol";
import {Router} from "../../src/Router.sol";
import {MockAC} from "../fixtures/BaseTestSetup.sol";
import {UUPSTimelockHarness} from "@btr-shared-test/UUPSTimelockHarness.sol";

/// @title UUPSTimelockRouterTest
/// @notice Dex-local Router UUPS timelock coverage (harness lives in shared/evm/test).
contract UUPSTimelockRouterTest is UUPSTimelockHarness {
    MockAC internal ac;

    function _deployProxyAndImpl() internal override returns (address, address) {
        ac = new MockAC(OWNER);
        Router impl = new Router(address(ac));
        address p = LibClone.deployERC1967(address(impl));
        vm.prank(OWNER);
        Router(payable(p)).initialize(address(0xF1));
        Router fresh = new Router(address(ac));
        return (p, address(fresh));
    }

    function _requestUpgrade(address caller, address impl) internal override {
        vm.prank(caller);
        Router(payable(proxy)).requestUpgrade(impl);
    }

    function _executeUpgrade(address caller) internal override {
        vm.prank(caller);
        Router(payable(proxy)).executeUpgrade();
    }

    function _cancelUpgrade(address caller) internal override {
        vm.prank(caller);
        Router(payable(proxy)).cancelUpgrade();
    }

    function _hasPendingUpgrade() internal view override returns (bool) {
        return Router(payable(proxy)).pendingUpgradeOp() != 0;
    }
}

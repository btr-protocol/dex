// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {PoolFactory} from "../../src/PoolFactory.sol";
import {Pool} from "../../src/Pool.sol";
import {Treasury} from "../../src/Treasury.sol";
import {Bridge} from "../../src/Bridge.sol";
import {Router} from "../../src/Router.sol";
import {GovToken} from "../../src/tokens/GovToken.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title DeployScriptTest
/// @notice Phase 42H.D · Round 3 (G11) -exercises the full Deploy.s.sol e2e flow inside
///         forge-test (no broadcast). Verifies addr non-zero, wiring (GovToken owned by
///         Treasury, PoolFactory.referencePool == poolImpl, AC owner == deployer), and
///         that proxies are initialized (calling initialize again must revert).
contract DeployScriptTest is Test {
    Deploy script;

    function setUp() public {
        script = new Deploy();
    }

    function test_deploy_e2e_wiring() public {
        Deploy.Addrs memory a = script.run();

        // ── non-zero addrs ──
        assertTrue(a.ac != address(0), "ac");
        assertTrue(a.admin != address(0), "admin");
        assertTrue(a.staking != address(0), "staking");
        assertTrue(a.distributor != address(0), "distributor");
        assertTrue(a.flash != address(0), "flash");
        assertTrue(a.poolImpl != address(0), "poolImpl");
        assertTrue(a.poolFactory != address(0), "poolFactory");
        assertTrue(a.govToken != address(0), "govToken");
        assertTrue(a.treasuryProxy != address(0), "treasuryProxy");
        assertTrue(a.bridgeProxy != address(0), "bridgeProxy");
        assertTrue(a.routerProxy != address(0), "routerProxy");

        // ── core wiring ──
        assertEq(PoolFactory(payable(a.poolFactory)).referencePool(), a.poolImpl, "factory.refPool");
        assertEq(PoolFactory(payable(a.poolFactory)).AC(), a.ac, "factory.AC");
        assertEq(Pool(payable(a.poolImpl)).AC(), a.ac, "poolImpl.AC");
        assertEq(Pool(payable(a.poolImpl)).admin(), a.admin, "poolImpl.admin");
        assertEq(Pool(payable(a.poolImpl)).staking(), a.staking, "poolImpl.staking");
        assertEq(Pool(payable(a.poolImpl)).flash(), a.flash, "poolImpl.flash");

        // GovToken ownership transferred to Treasury proxy.
        assertEq(GovToken(a.govToken).owner(), a.treasuryProxy, "govToken.owner");

        // ── post-deploy wiring (G13) ──
        assertTrue(Treasury(payable(a.treasuryProxy)).distributor() != address(0), "treasury.distributor unset");
        assertEq(Treasury(payable(a.treasuryProxy)).distributor(), a.distributor, "treasury.distributor mismatch");
        assertTrue(Treasury(payable(a.treasuryProxy)).bridge() != address(0), "treasury.bridge unset");
        assertEq(Treasury(payable(a.treasuryProxy)).bridge(), a.bridgeProxy, "treasury.bridge mismatch");
        assertEq(Treasury(payable(a.treasuryProxy)).getBridge(), a.bridgeProxy, "treasury.getBridge mismatch");
        // PoolFactory ownership funnels through AC.owner() (same multisig governs both).
        assertEq(Ownable(a.poolFactory).owner(), Ownable(a.ac).owner(), "factory.owner != ac.owner");

        // Treasury / Bridge / Router proxies initialized → second initialize reverts.
        vm.expectRevert();
        Treasury(payable(a.treasuryProxy)).initialize(address(this));
        vm.expectRevert();
        Bridge(payable(a.bridgeProxy)).initialize(address(this));
        vm.expectRevert();
        Router(payable(a.routerProxy)).initialize(address(this), a.poolFactory);
    }
}

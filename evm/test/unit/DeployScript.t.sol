// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {PoolFactory} from "../../src/PoolFactory.sol";
import {Pool} from "../../src/Pool.sol";
import {Treasury} from "@btr-shared/Treasury.sol";
import {Bridge} from "@btr-shared/Bridge.sol";
import {GovToken} from "@btr-shared/tokens/GovToken.sol";
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
        // Self-contained env, fully reset before EACH test (vm.setEnv is process-global — avoid bleed).
        vm.setEnv("DEPLOYER_PK", "0x0000000000000000000000000000000000000000000000000000000000000001");
        vm.setEnv("LZ_ENDPOINT", vm.toString(address(this))); // test contract has code
        vm.setEnv("ALLOW_NO_LZ", "false");
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

        // ── core wiring ──
        assertEq(PoolFactory(payable(a.poolFactory)).referencePool(), a.poolImpl, "factory.refPool");
        assertEq(PoolFactory(payable(a.poolFactory)).AC(), a.ac, "factory.AC");
        assertEq(Pool(payable(a.poolImpl)).AC(), a.ac, "poolImpl.AC");
        assertEq(Pool(payable(a.poolImpl)).admin(), a.admin, "poolImpl.admin");
        assertEq(Pool(payable(a.poolImpl)).flash(), a.flash, "poolImpl.flash");

        // Track-B Phase-1b: GovToken has immutable TREASURY = treasuryProxy (no Ownable).
        assertEq(GovToken(a.govToken).TREASURY(), a.treasuryProxy, "govToken.TREASURY");

        // ── post-deploy wiring (G13) ──
        assertTrue(Treasury(payable(a.treasuryProxy)).distributor() != address(0), "treasury.distributor unset");
        assertEq(Treasury(payable(a.treasuryProxy)).distributor(), a.distributor, "treasury.distributor mismatch");
        assertTrue(Treasury(payable(a.treasuryProxy)).bridge() != address(0), "treasury.bridge unset");
        assertEq(Treasury(payable(a.treasuryProxy)).bridge(), a.bridgeProxy, "treasury.bridge mismatch");
        assertEq(Treasury(payable(a.treasuryProxy)).getBridge(), a.bridgeProxy, "treasury.getBridge mismatch");
        // PoolFactory ownership funnels through AC.owner() via AC-singleton modifier
        // (Track-B Phase-1: PoolFactory dropped Solady Ownable; auth resolves via AC.owner()).
        assertEq(PoolFactory(payable(a.poolFactory)).AC(), a.ac, "factory.AC != ac");

        // Treasury / Bridge proxies initialized → second initialize reverts.
        vm.expectRevert();
        Treasury(payable(a.treasuryProxy)).initialize(a.govToken);
        vm.expectRevert();
        Bridge(payable(a.bridgeProxy)).initialize();

        // BRG-01 negatives — kept in ONE test (vm.setEnv is process-global; forge runs
        // separate test fns concurrently, so isolating these avoids env-var races).

        // (a) EOA (no code) LZ endpoint must abort the deploy, not wire a dead bridge.
        vm.setEnv("LZ_ENDPOINT", vm.toString(address(0xBEEF))); // no code
        vm.expectRevert(bytes("LZ endpoint not a contract"));
        script.run();
        vm.setEnv("LZ_ENDPOINT", vm.toString(address(this)));

        // (b) ALLOW_NO_LZ=true opt-out deploys core with NO bridge (no dead endpoint at all).
        vm.setEnv("ALLOW_NO_LZ", "true");
        Deploy.Addrs memory b = script.run();
        assertEq(b.bridgeProxy, address(0), "bridgeProxy should be unset");
        assertEq(b.bridgeImpl, address(0), "bridgeImpl should be unset");
        assertEq(Treasury(payable(b.treasuryProxy)).bridge(), address(0), "treasury.bridge should be unset");
        assertTrue(b.poolFactory != address(0), "core still deployed");
    }
}

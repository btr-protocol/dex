// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {TestnetDeploy} from "../../script/TestnetDeploy.s.sol";
import {ExternalOracle} from "../../src/oracles/ExternalOracle.sol";
import {MockAC} from "../fixtures/BaseTestSetup.sol";

contract TestnetDeployHarness is TestnetDeploy {
  function loadUsdcSeed() external view returns (uint256) {
    return _loadSeedMarks().usdc;
  }

  function validateReferenceOraclesExternal(address ref, address xautRef, address primaryOwner)
    external
    view
  {
    _validateReferenceOracles(ref, xautRef, _loadSignerSets(), primaryOwner);
  }

  function loadSignerSetsExternal() external view returns (SignerSets memory) {
    return _loadSignerSets();
  }

  function validateSignerSetsExternal(SignerSets memory sets) external pure {
    _validateSignerSets(sets);
  }
}

contract TestnetDeployTest is Test {
  TestnetDeployHarness private script;

  function setUp() public {
    script = new TestnetDeployHarness();
    // vm.setEnv is process-global and not reset between tests; seed a valid USDC identity here so
    // every test starts from a clean baseline (a prior test's override cannot leak in).
    vm.setEnv("ORACLE_SEED_USDC_1E18", "1000000000000000000");
    vm.setEnv("ORACLE_SEED_USDT_1E18", "1000000000000000000");
    vm.setEnv("ORACLE_SEED_USD1_1E18", "1000000000000000000");
    vm.setEnv("ORACLE_SEED_USDE_1E18", "1000000000000000000");
    vm.setEnv("ORACLE_SEED_FDUSD_1E18", "1000000000000000000");
    vm.setEnv("ORACLE_SEED_BTCB_1E18", "64300000000000000000000");
    vm.setEnv("ORACLE_SEED_ETH_1E18", "1795000000000000000000");
    vm.setEnv("ORACLE_SEED_WBNB_1E18", "574000000000000000000");
    vm.setEnv("ORACLE_SEED_CAKE_1E18", "1390000000000000000");
    vm.setEnv("ORACLE_SEED_XAUT_1E18", "4090000000000000000000");
    _setSignerEnv("ORACLE_SIGNER_", 0x1000);
    _setSignerEnv("REF_ORACLE_SIGNER_", 0x2000);
    _setSignerEnv("XAUT_REF_ORACLE_SIGNER_", 0x3000);
  }

  function test_loadSeedMarks_acceptsIdentityUsdcFeed() public {
    vm.setEnv("ORACLE_SEED_USDC_1E18", "1000000000000000000");
    assertEq(script.loadUsdcSeed(), 1e18);
  }

  function test_loadSeedMarks_rejectsMarketUsdPriceForIdentityFeed() public {
    vm.setEnv("ORACLE_SEED_USDC_1E18", "990000000000000000");
    vm.expectRevert("USDC/USDC seed must equal 1e18");
    script.loadUsdcSeed();
  }

  function test_referenceOracleValidation_acceptsDisjointSignerAndOwnerDomains() public {
    TestnetDeploy.SignerSets memory sets = script.loadSignerSetsExternal();
    for (uint256 i; i < 3; ++i) {
      assertEq(sets.primary[i], address(uint160(0x1001 + i)));
      assertEq(sets.stableReference[i], address(uint160(0x2001 + i)));
      assertEq(sets.xautReference[i], address(uint160(0x3001 + i)));
    }
    ExternalOracle ref = _oracle(0x2000, address(0xA001));
    ExternalOracle xautRef = _oracle(0x3000, address(0xA002));
    script.validateReferenceOraclesExternal(address(ref), address(xautRef), address(0xA003));
  }

  function test_referenceOracleValidation_rejectsSignerOverlap() public {
    TestnetDeploy.SignerSets memory sets = script.loadSignerSetsExternal();
    sets.xautReference[2] = sets.stableReference[0];
    vm.expectRevert("oracle signer sets must be disjoint");
    script.validateSignerSetsExternal(sets);
  }

  function test_referenceOracleValidation_rejectsSharedGovernanceOwner() public {
    ExternalOracle ref = _oracle(0x2000, address(0xA001));
    ExternalOracle xautRef = _oracle(0x3000, address(0xA001));
    vm.expectRevert("oracle governance owners must differ");
    script.validateReferenceOraclesExternal(address(ref), address(xautRef), address(0xA003));
  }

  function test_referenceOracleValidation_rejectsUndeclaredLiveSignerSet() public {
    ExternalOracle ref = _oracle(0x4000, address(0xA001));
    ExternalOracle xautRef = _oracle(0x3000, address(0xA002));
    vm.expectRevert("invalid REF_ORACLE signer set");
    script.validateReferenceOraclesExternal(address(ref), address(xautRef), address(0xA003));
  }

  function test_referenceOracleValidation_rejectsPendingSignerLoosening() public {
    ExternalOracle ref = _oracle(0x2000, address(this));
    ref.requestSignerGrant(address(0x9999));
    ExternalOracle xautRef = _oracle(0x3000, address(0xA002));
    vm.expectRevert("invalid REF_ORACLE signer set");
    script.validateReferenceOraclesExternal(address(ref), address(xautRef), address(0xA003));
  }

  function _oracle(uint160 base, address owner) internal returns (ExternalOracle oracle) {
    MockAC ac = new MockAC(owner);
    address[] memory signers = new address[](3);
    signers[0] = address(base + 1);
    signers[1] = address(base + 2);
    signers[2] = address(base + 3);
    oracle = new ExternalOracle(address(ac), 60, signers, 2);
  }

  function _setSignerEnv(string memory prefix, uint160 base) internal {
    vm.setEnv(string.concat(prefix, "0"), vm.toString(address(base + 1)));
    vm.setEnv(string.concat(prefix, "1"), vm.toString(address(base + 2)));
    vm.setEnv(string.concat(prefix, "2"), vm.toString(address(base + 3)));
  }
}

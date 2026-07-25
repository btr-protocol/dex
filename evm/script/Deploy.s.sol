// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {DeployBase} from "@btr-shared-script/Deploy.base.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {console2} from "forge-std/Script.sol";

import {Admin} from "../src/Admin.sol";
import {Staking} from "@btr-shared/Staking.sol";
import {Distributor} from "@btr-shared/Distributor.sol";
import {Flash} from "../src/Flash.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {GovTreasury} from "@btr-shared/GovTreasury.sol";
import {OpsTreasury} from "@btr-shared/OpsTreasury.sol";
import {Bridge} from "@btr-shared/Bridge.sol";
import {GovToken} from "@btr-shared/tokens/GovToken.sol";

/// @title Deploy -minimal e2e BTR DEX deploy.
/// @notice Singletons (Admin/Staking/Distributor/Flash) + Pool reference impl + PoolFactory +
///         UUPS peripherals (Treasury, Bridge) behind ERC1967 proxies. GovToken is
///         pre-wired to Treasury (mint/burn gateway). Treasury.distributor + Treasury.bridge
///         are wired post-deploy. PoolFactory ownership is transferred to AC.owner() so all
///         protocol governance funnels through one multisig. All addresses persisted to JSON.
/// @dev    Required env: DEPLOYER_PK, LZ_ENDPOINT (a deployed contract) — unless ALLOW_NO_LZ=1,
///         which skips bridge deploy/wiring for LZ-less testnets. Optional: DEPLOYER, TREASURY,
///         GOV_NAME, GOV_SYMBOL, DEPLOY_OUT.
contract Deploy is DeployBase {
  struct Addrs {
    address deployer;
    address treasury_owner;
    address ac;
    address admin;
    address staking;
    address distributor;
    address flash;
    address poolAux;
    address poolImpl;
    address poolFactory;
    address govToken;
    address treasuryImpl;
    address treasuryProxy;
    address opsTreasuryImpl;
    address opsTreasuryProxy;
    address bridgeImpl;
    address bridgeProxy;
  }

  function run() external returns (Addrs memory a) {
    a = _broadcastDeploy();
    _logAndPersist(a);
  }

  /// @dev Core singleton + peripheral deploy inside one broadcast session.
  function _broadcastDeploy() internal returns (Addrs memory a) {
    return _broadcastDeployWith(address(0));
  }

  /// @dev `acOverride != 0` REUSES an already-deployed AccessControl instead of minting one. A
  ///      chain whose oracle stack shipped first (Sepolia) must bind pools to that same AC: a
  ///      second AC would split protocol governance in two and leave the oracle's guardian unable
  ///      to freeze the pools it feeds. Its owner must be the deployer, else this broadcast cannot
  ///      execute the owner-gated wiring below.
  function _broadcastDeployWith(address acOverride) internal returns (Addrs memory a) {
    uint256 pk = vm.envUint("DEPLOYER_PK");
    a.deployer = vm.addr(pk);
    // If DEPLOYER is set it must match the PK-derived address.
    try vm.envAddress("DEPLOYER") returns (address d) {
      require(d == a.deployer, "DEPLOYER/DEPLOYER_PK mismatch");
    } catch {}
    a.treasury_owner = _resolveTreasury(a.deployer);
    // BRG-01: never wire the bridge to a defaulted/dead endpoint. Either LZ_ENDPOINT is
    // explicitly set to a real on-chain contract (production), or bridge deployment is
    // explicitly opted out via ALLOW_NO_LZ=1 (LZ-less testnet) — deploying a 0xDEAD/EOA
    // endpoint would let a bricked/attacker-controlled endpoint govern cross-chain mint/burn.
    bool allowNoLz = vm.envOr("ALLOW_NO_LZ", false);
    address lzEndpoint;
    if (!allowNoLz) {
      lzEndpoint = vm.envAddress("LZ_ENDPOINT"); // reverts if unset — no silent default
      require(lzEndpoint.code.length > 0, "LZ endpoint not a contract");
    }
    string memory govName = vm.envOr("GOV_NAME", string("BTR Governance"));
    string memory govSymbol = vm.envOr("GOV_SYMBOL", string("BTR"));

    vm.startBroadcast(pk);

    // 1. AccessControl (shared singleton) — or the pre-existing one this chain already governs by.
    if (acOverride == address(0)) {
      a.ac = address(_deployAC(a.deployer, a.treasury_owner));
    } else {
      require(acOverride.code.length > 0, "AC override not a contract");
      require(AccessControl(acOverride).owner() == a.deployer, "AC override not owned by deployer");
      a.ac = acOverride;
    }

    // 2. Singletons (non-upgradeable; carry immutable AC ref).
    a.admin = address(new Admin(a.ac));
    a.staking = address(new Staking(a.ac));
    a.distributor = address(new Distributor(a.ac));
    a.flash = address(new Flash());

    // 3. PoolAux singleton (cold-path dispatcher, Wave-3a EIP-170 reduction)
    //    + Pool reference impl + PoolFactory (clones).
    a.poolAux = address(new PoolAux(a.ac, a.admin, a.flash));
    a.poolImpl = address(new Pool(a.ac, a.admin, a.flash, a.poolAux));
    a.poolFactory = address(new PoolFactory(a.poolImpl, a.deployer, a.ac));

    // 4. Treasury impl + proxy (UUPS). Track-B Phase-1b: deploy order is now
    //    Treasury proxy → GovToken (immutable TREASURY) → Treasury.initialize(govToken).
    a.treasuryImpl = address(new GovTreasury(a.ac));
    a.treasuryProxy = LibClone.deployERC1967(a.treasuryImpl);

    // 5. GovToken w/ immutable TREASURY = treasuryProxy.
    a.govToken = address(new GovToken(a.treasuryProxy, govName, govSymbol));

    // 6. Wire GovTreasury <- govToken via initialize (write-once).
    GovTreasury(payable(a.treasuryProxy)).initialize(a.govToken);

    // 6b. OpsTreasury impl + proxy (UUPS). Operational treasury = pools' `treasury()` sink for
    //     protocol-fee / incentive custody; funds the Distributor singleton. No initialize (AC
    //     is immutable); `distributor` wired post-deploy below. Distinct from GovTreasury.
    a.opsTreasuryImpl = address(new OpsTreasury(a.ac));
    a.opsTreasuryProxy = LibClone.deployERC1967(a.opsTreasuryImpl);

    // 7. Bridge (UUPS). Skipped entirely under ALLOW_NO_LZ — no dead endpoint deployed.
    if (!allowNoLz) {
      a.bridgeImpl = address(new Bridge(lzEndpoint, a.ac));
      a.bridgeProxy = LibClone.deployERC1967(a.bridgeImpl);
    }

    // 8. Post-deploy wiring (G13).
    //    - Treasury.distributor + Treasury.bridge MUST be set; GovToken cross-chain
    //      mint/burn gates on Treasury.getBridge() and emissions claim flows through
    //      Treasury → distributor.
    //    - PoolFactory ownership → AC.owner() so factory governance follows the same
    //      multisig as protocol-wide AccessControl. (deployer initially owns factory
    //      via _initializeOwner(msg.sender) in its constructor.)
    GovTreasury(payable(a.treasuryProxy)).setDistributor(a.distributor);
    if (a.bridgeProxy != address(0)) {
      GovTreasury(payable(a.treasuryProxy)).setBridge(a.bridgeProxy);
    }
    //    - OpsTreasury.distributor MUST be set so `fundDistributor` can push incentive tokens
    //      to the Distributor singleton. Pools' `treasury()` is wired to opsTreasuryProxy in the
    //      per-chain pool-seed scripts (Pool.initialize leaves treasury=0 → sweepIncentives
    //      reverts ZeroAddr until wired via Admin.requestTreasuryUpdate→executeTreasuryUpdate).
    OpsTreasury(payable(a.opsTreasuryProxy)).setDistributor(a.distributor);
    // PoolFactory migrated to AC-singleton (Track-B Phase-1): ownership funnels
    // through AC.owner() automatically; no separate transferOwnership call needed.

    vm.stopBroadcast();
  }

  /// @notice Log addrs + persist deployment JSON via vm.serializeAddress chain.
  /// @dev    `vm.writeJson` writes once at the end; foundry's allow-list (fs_permissions)
  ///         must include the output path or write silently fails (caught + logged).
  function _logAndPersist(Addrs memory a) internal {
    console2.log("=== BTR DEX deploy ===");
    console2.log("AccessControl:    ", a.ac);
    console2.log("Admin:            ", a.admin);
    console2.log("Staking:          ", a.staking);
    console2.log("Distributor:      ", a.distributor);
    console2.log("Flash:            ", a.flash);
    console2.log("PoolAux:          ", a.poolAux);
    console2.log("Pool (impl):      ", a.poolImpl);
    console2.log("PoolFactory:      ", a.poolFactory);
    console2.log("GovToken:         ", a.govToken);
    console2.log("Treasury (proxy): ", a.treasuryProxy);
    console2.log("OpsTreasury(prox):", a.opsTreasuryProxy);
    console2.log("Bridge (proxy):   ", a.bridgeProxy);

    string memory k = "btr_deploy";
    vm.serializeUint(k, "chainId", block.chainid);
    vm.serializeAddress(k, "deployer", a.deployer);
    vm.serializeAddress(k, "ac", a.ac);
    vm.serializeAddress(k, "admin", a.admin);
    vm.serializeAddress(k, "staking", a.staking);
    vm.serializeAddress(k, "distributor", a.distributor);
    vm.serializeAddress(k, "flash", a.flash);
    vm.serializeAddress(k, "poolAux", a.poolAux);
    vm.serializeAddress(k, "poolImpl", a.poolImpl);
    vm.serializeAddress(k, "poolFactory", a.poolFactory);
    vm.serializeAddress(k, "govToken", a.govToken);
    vm.serializeAddress(k, "treasuryImpl", a.treasuryImpl);
    vm.serializeAddress(k, "treasuryProxy", a.treasuryProxy);
    vm.serializeAddress(k, "opsTreasuryImpl", a.opsTreasuryImpl);
    vm.serializeAddress(k, "opsTreasuryProxy", a.opsTreasuryProxy);
    vm.serializeAddress(k, "bridgeImpl", a.bridgeImpl);
    string memory json = vm.serializeAddress(k, "bridgeProxy", a.bridgeProxy);

    string memory outPath = vm.envOr(
      "DEPLOY_OUT", string.concat("deployments/", vm.toString(block.chainid), ".deploy.json")
    );
    try vm.writeJson(json, outPath) {}
    catch {
      console2.log("(skip) writeJson not permitted; JSON below:");
      console2.log(json);
    }
  }
}

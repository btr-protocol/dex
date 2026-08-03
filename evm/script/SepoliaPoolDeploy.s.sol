// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Deploy} from "./Deploy.s.sol";
import {Admin} from "../src/Admin.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {Pool} from "../src/Pool.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {ExternalOracle} from "../src/oracles/ExternalOracle.sol";
import {TestnetERC20} from "../src/testnet/TestnetERC20.sol";
import {TestnetFaucet} from "../src/testnet/TestnetFaucet.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {OpsTreasury} from "@btr-shared/OpsTreasury.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title SepoliaPoolDeploy — Sepolia (11155111) DEX stack on top of the already-deployed oracle.
/// @notice Core singletons (reusing the oracle stack's AccessControl) + faucet + a reference
///         ExternalOracle + the two launch pools, both based on USDC:
///           stable core   = USDC, USDT, USDE, USDS, DAI, USD1, USDG, PYUSD, RLUSD, USDF,
///                           U, GHO, TUSD, USDTB, FDUSD, AUSD
///           volatile core = USDC, USDT, WETH, WBTC, cbBTC, BNB, XAUT, PAXG, EURC
///         No incumbent/comparison pools (owner-descoped 2026-07-24) — our stack only.
/// @dev TWO JSON INPUTS, both consumed, nothing hardcoded:
///      1. `deployments/11155111.deploy.json` (SoT, written by SepoliaOracleDeploy): `ac`,
///         `oracle`, one address per symbol, `feed_<SYM>` = keccak(token, USDC), plus `USD` and
///         `feed_USDC-USD` (the SIGNED USDC/USD reference: keeper idx 23 post-EURC, but this
///         script keys it by name/keccak, never by numeric index; see base config below).
///         ERC20 mocks are REUSED from that file, never re-minted: feed_id binds
///         keccak(asset, USDC) to those exact token addresses forever, so a fresh mock would
///         point every feed at an asset the pool does not hold.
///      2. `deployments/sepolia-risk-params.json` (written by
///         research/stable-core/emit_prod_params.py from the referee-gated central-normal-plateau
///         fit): curve presets + per-asset minFee/dispersion/wall/refBand. Parallel arrays.
/// @dev BASE USDC: mark ≡ 1.0, never pushed (Pricing._readBasePriceOrHalt discards the read price
///      for quoting), κ forbidden (AIMM_PROOFS Thm 2 — a walled numeraire breaks cross-leg
///      round-trip neutrality). Its OracleConfig points at the SIGNED USDC/USD feed (keeper idx 23) so the
///      depeg guard and the USD reservation band both read a real market price; refFeedId /
///      refBandBps / refPrimary stay 0 for the base (it is exempt from requireExternalSpokeBound —
///      its canonical feed IS its breaker).
/// @dev REFERENCE ORACLE (why a second contract is deployed): every EXTERNAL non-base spoke must
///      carry a cumulative bound (PoolAdmin.requireExternalSpokeBound) = a ref band or a two-sided
///      absolute reservation band. `addAsset` has no reservation-price argument and initAsset
///      defaults it to 0, so the ref band is the only bound available at listing time — and
///      validateOracleConfig requires `refPrimary != primary`. The oracle deploy shipped ONE
///      oracle, so this script deploys the reference tier: a second ExternalOracle under its own
///      AccessControl, seeded from the primary's live marks. Pegged stables band against
///      USDC/USD; every other spoke bands against its OWN pair feed (comparing a non-USD mark to
///      a unit price would halt permanently).
///      ⚠ ADDRESS DISTINCTNESS IS NOT OPERATIONAL INDEPENDENCE. On Sepolia the reference set
///      defaults to the same signers and the same deployer-owned governance. Mainnet MUST give it
///      a disjoint signer set AND a different owner (the Chapel script enforces exactly that in
///      _validateReferenceOracles); set REF_ORACLE + REF_ORACLE_SIGNER_{0,1,2} to reuse a genuinely
///      independent tier here.
/// @dev Env: DEPLOYER_PK, GUARDIAN and WNATIVE (all required; WNATIVE must be the SoT's WETH mock,
///      which is a TestnetWETH9 so native ETH can actually wrap). Optional: DEPLOY_IN (oracle SoT
///      path), RISK_PARAMS (params path), POOLS_OUT (output path), TREASURY,
///      REF_ORACLE + REF_ORACLE_SIGNER_{0,1,2},
///      ALLOW_NO_LZ (default true here — Sepolia bring-up ships no bridge), SKIP_UNLISTED
///      (list only the symbols the oracle stack actually carries), REDEPLOY.
/// @dev SKIP_UNLISTED is a safety valve, not a routine flag. Every roster symbol (EURC included,
///      oracle market idx 22) has a feed on the current SepoliaOracleDeploy, so the default FAIL
///      LOUD path lists the full set. A symbol without an oracle feed would revert in
///      validateOracleConfig; SKIP_UNLISTED=true lists the rest and logs the omission instead. If
///      a future roster symbol has no feed, add it to SepoliaOracleDeploy._syms (append-only) first.
/// @dev RUNBOOK: `forge script script/SepoliaPoolDeploy.s.sol:SepoliaPoolDeploy --sig
///      "deployPools()" --rpc-url sepolia` (simulate) then re-run with --broadcast --slow.
///      Swaps are ENABLED at listing (testnet); mainnet gates them behind timelocked risk updates.
/// @dev REF KEEPER (money-path, do NOT skip): the reference oracle is a SECOND push target. The
///      deploy seeds it fresh, so spoke swaps work in the TTL window (7200s stable / 600s vol)
///      right after deploy — but once a ref feed passes TTL with no push it fail-closes, and every
///      spoke that bands against it reverts (dead DEX). Immediately after broadcast, point the
///      keeper at BOTH oracles: `oracle` (primary, all feeds) AND `refOracle` (the `refFeeds` set
///      from 11155111.pools.json). keepers/oracle.sepolia.toml must carry a [reference] block with
///      refOracle's address + the refFeeds names; keepers/scripts/fill-oracle-config.py resolves
///      each name to a feed id by keccak(token, USDC) off 11155111.deploy.json (same as primary).
///      Start the keeper on both in the same session the pools go live.
contract SepoliaPoolDeploy is Deploy {
  uint16 internal constant STABLE_TTL = 7200;
  uint16 internal constant VOLATILE_TTL = 600;
  // σ seed MUST be non-zero: a σ=0 feed's per-push band is pinned at the bare maxDeviation floor
  // until its first signed push lands, and once the market drifts past that floor no push can ever
  // land again (deadlock; recovery = timelocked requestFeedWiden). Per-class, mirrors
  // SepoliaOracleDeploy; under-states the observed live prior so the band is not inflated.
  uint32 internal constant SIGMA_SEED_STABLE = 300;
  uint32 internal constant SIGMA_SEED_FX = 800;
  uint32 internal constant SIGMA_SEED_VOLATILE = 2_000;
  uint16 internal constant CONF_SEED = 25;
  uint16 internal constant STABLE_MAXDEV = 50;
  uint16 internal constant VOLATILE_MAXDEV = 100;
  // FX tier (fx-core, 2026-07-27). Its own class because a fiat-FX leg is NEITHER ~1.0 against the
  // USDC base (so the pegged-stable band would strand it) NOR crypto-volatile (so the volatile band
  // is 2x looser than the tape warrants). Both figures derive from measured NXR FX tape — the
  // derivation + per-leg sigma live in deployments/sepolia-risk-params.json `basis.fx`.
  uint16 internal constant FX_TTL = 3600;
  uint16 internal constant FX_MAXDEV = 75;
  uint8 internal constant SIGNER_THRESHOLD = 2;
  // Faucet drip as a FRACTION of a leg, never its own USD figure: 1/50 = 2%/day, 200 days prefunded.
  uint256 internal constant FAUCET_CAP_DIVISOR = 50;
  uint256 internal constant FAUCET_PREFUND_CLAIMS = 200;
  /// @dev Target VALUE of one leg's dead-share seed, 1e18-scaled USD: $0.001, dust to the first
  ///      depositor on every leg from KRW1 to WBTC. See `_deadSeedPow10`.
  uint256 internal constant DEAD_SEED_TARGET_1E18 = 1e15;
  // Reference-tier signer defaults = the canonical NXR attester set (same pins as the oracle
  // script). Override per the independence warning above.
  address internal constant SIGNER_0 = 0x9E34F1120B9a6fD93AAF81e6eF2df187A6CE45cF;
  address internal constant SIGNER_1 = 0x80F7f57Bd9DF46FA448586bC2Cc5e4ddF765973E;
  address internal constant SIGNER_2 = 0x672C2dc3CA298eDca4793C700b9C658482966B2c;

  struct Cfg {
    string sot; // raw deployments/11155111.deploy.json
    string risk; // raw deployments/sepolia-risk-params.json
    string marks; // raw deployments/<chain>.seed-marks.json (the ceremony's NXR snapshot)
    address oracle; // primary ExternalOracle (marks)
    address refOracle; // reference ExternalOracle (spoke depeg bands)
    address usdc;
    address usd;
    bytes32 usdcUsdFeed;
    uint256 gamma;
    uint256 vega;
    uint256 seedUsdc;
    address wnative;
    bool skipUnlisted;
  }

  /// @dev One row of deployments/sepolia-risk-params.json, resolved for a single symbol.
  struct AssetParams {
    address token;
    uint16 presetId;
    uint16 minFeePbps;
    uint16 maxFeePbps;
    uint32 minDisp;
    uint32 maxDisp;
    uint16 kappaCovBps;
    uint16 depthAmplifier;
    uint16 haircutSuppressor;
    uint16 refBandBps;
    bool refOwnFeed;
    // DEN-01: true when the NXR signer catalog attests this asset as <TOKEN>-USD (idx 1..15 stables,
    // 21 PAXG-USD, 22 EURC-USD, 24..28 the inverted FX legs) while the on-chain feed name is
    // <TOKEN>-USDC. The pool then divides by the base USDC-USD mark at consumption. false for the
    // genuine USDC crosses (idx 16 ETH-USDC, 17/18 BTC-USDC, 19 BNB-USDC) and for the base itself.
    // NOT derivable from `cls`: PAXG/EURC are risk-class `volatile` but catalog-quoted in USD.
    bool usdQuoted;
    bool stable;
    bool fx;
  }

  /// @dev ttl/maxDeviation tier for one asset class. Kept as one switch so the primary-feed add
  ///      (addFxFeeds) and the reference mirror (_mirrorRefFeed) can never disagree on a class.
  function _tier(bool stable, bool fx)
    internal
    pure
    returns (uint16 maxDev, uint16 ttl, uint32 sigma)
  {
    if (stable) return (STABLE_MAXDEV, STABLE_TTL, SIGMA_SEED_STABLE);
    if (fx) return (FX_MAXDEV, FX_TTL, SIGMA_SEED_FX);
    return (VOLATILE_MAXDEV, VOLATILE_TTL, SIGMA_SEED_VOLATILE);
  }

  function deployPools() external returns (address stablePool, address volatilePool) {
    require(block.chainid == 11155111, "Sepolia only");
    string memory outPath = _poolsOutPath();
    // Re-run guard (mirrors the oracle script): a second broadcast mints a duplicate DEX bound to
    // the SAME feeds and silently overwrites the pool SoT.
    require(
      !_deployed(outPath, ".stablePool") || vm.envOr("REDEPLOY", false),
      "already deployed: 11155111.pools.json carries a live stablePool (REDEPLOY=true to override)"
    );
    uint256 pk = vm.envUint("DEPLOYER_PK");
    address deployer = vm.addr(pk);

    Cfg memory cfg = _loadCfg();
    // NOTE: deliberately NO predict-then-assert on the reference oracle. That pattern exists on
    // the PRIMARY oracle because NXR's signing tier and keeper configs are pre-filled with its
    // address, so a mismatch would strand the signed-quote domain. Nothing external is pre-filled
    // with the reference oracle's address, and the core-singleton deploys below consume an
    // unpredictable number of nonces first, so a prediction here would be fragile and protect
    // nothing. The invariant that DOES matter (refPrimary != primary) is asserted after deploy.

    // Core singletons, REUSING the oracle stack's AccessControl (one governance root per chain).
    Deploy.Addrs memory core = _broadcastDeployWith(vm.parseJsonAddress(cfg.sot, ".ac"));
    require(core.deployer == deployer, "unexpected core deployer");

    vm.startBroadcast(pk);
    if (cfg.refOracle == address(0)) {
      cfg.refOracle = _deployRefOracle(deployer);
    }
    // The one invariant that matters: a same-address "reference" cannot bound a walked primary
    // mark (validateOracleConfig enforces it too; failing here keeps the revert readable).
    require(
      cfg.refOracle != cfg.oracle && cfg.refOracle.code.length > 0,
      "reference oracle must be a distinct contract"
    );

    TestnetFaucet faucet = new TestnetFaucet(deployer);
    string[] memory stableSyms = vm.parseJsonStringArray(cfg.risk, ".stablePool");
    string[] memory volSyms = vm.parseJsonStringArray(cfg.risk, ".volatilePool");
    stableSyms = _listable(cfg, stableSyms);
    volSyms = _listable(cfg, volSyms);

    stablePool = _createPool(core, cfg, stableSyms, true);
    volatilePool = _createPool(core, cfg, volSyms, false);
    _fundFaucet(cfg, faucet, stableSyms, volSyms);

    // Guardian is MANDATORY, idempotent with the oracle deploy (same AC is reused). A pool fleet
    // whose only pause/freeze authority is the deployer EOA has no fail-safe at all.
    address guardian = vm.envAddress("GUARDIAN");
    require(guardian != address(0), "GUARDIAN unset: fail-safe would not exist");
    require(guardian != deployer, "GUARDIAN == deployer: not an independent fail-safe");
    AccessControl(core.ac).setGuardian(guardian, true);
    require(AccessControl(core.ac).guardianCount() >= 1, "guardian not registered");
    vm.stopBroadcast();

    _persist(
      core, cfg, address(faucet), stablePool, volatilePool, outPath, _concat(stableSyms, volSyms)
    );
    vm.writeJson(_receiptsJson(cfg, stablePool, stableSyms), outPath, ".stableReceipts");
    vm.writeJson(_receiptsJson(cfg, volatilePool, volSyms), outPath, ".volatileReceipts");
  }

  /// @dev Re-run guard. A bare `vm.exists` self-trips: forge runs the script AGAIN to broadcast, and
  ///      the second pass finds the artifact the first pass wrote, so a genuine first deploy aborts
  ///      (or, with REDEPLOY forced past it, the guard protects nothing). A prior deployment is one
  ///      whose recorded contract has CODE, which no simulation-only pass can fake.
  function _deployed(string memory outPath, string memory key) internal view returns (bool) {
    if (!vm.exists(outPath)) return false;
    string memory j = vm.readFile(outPath);
    if (!vm.keyExists(j, key)) return false;
    return vm.parseJsonAddress(j, key).code.length > 0;
  }

  // ── config ────────────────────────────────────────────────────────────────────────────────

  function _loadCfg() internal view returns (Cfg memory cfg) {
    cfg.sot = vm.readFile(
      vm.envOr("DEPLOY_IN", string.concat("deployments/", vm.toString(block.chainid), ".deploy.json"))
    );
    cfg.risk = vm.readFile(_riskPath());
    cfg.marks = vm.readFile(
      string.concat("deployments/", vm.toString(block.chainid), ".seed-marks.json")
    );
    require(
      vm.parseJsonUint(cfg.marks, ".seedUsdPerLeg")
        == vm.parseJsonUint(cfg.risk, ".seedUsdPerLeg"),
      "seed-marks: fetched for a different seedUsdPerLeg than the params file"
    );
    require(
      vm.parseJsonUint(cfg.risk, ".chainId") == block.chainid, "risk params: wrong chainId"
    );
    cfg.oracle = vm.parseJsonAddress(cfg.sot, ".oracle");
    cfg.usdc = vm.parseJsonAddress(cfg.sot, ".USDC");
    cfg.usd = vm.parseJsonAddress(cfg.sot, ".USD");
    cfg.usdcUsdFeed = vm.parseJsonBytes32(cfg.sot, ".feed_USDC-USD");
    require(
      cfg.usdcUsdFeed == keccak256(abi.encodePacked(cfg.usdc, cfg.usd)),
      "USDC/USD reference feed id does not bind the deployed tokens"
    );
    cfg.gamma = vm.parseJsonUint(cfg.risk, ".gamma");
    cfg.vega = vm.parseJsonUint(cfg.risk, ".vega");
    // gamma/vega are uint16 on-chain (IPool addAsset); a future params file exceeding 65535 would
    // silently truncate at the cast site. Reject at load so the failure is a clear script revert.
    require(
      cfg.gamma <= type(uint16).max && cfg.vega <= type(uint16).max, "gamma/vega exceed uint16"
    );
    cfg.refOracle = vm.envOr("REF_ORACLE", address(0));
    // Seed scale is CONFIG, never an env default: `envOr("SEED_USDC", 2_000_000 ether)` is exactly
    // how the 2026-07-24 Sepolia seed landed 40x over spec, and no on-chain cap exists to catch it.
    // parseJsonUint reverts on a missing key ⇒ a params file without a seed aborts the deploy.
    cfg.seedUsdc = vm.parseJsonUint(cfg.risk, ".seedUsdPerLeg") * 1e18;
    cfg.wnative = _resolveWnative(cfg.sot);
    cfg.skipUnlisted = vm.envOr("SKIP_UNLISTED", false);
  }

  /// @dev WNATIVE is written to Pool storage at initialize and every native deposit/withdraw routes
  ///      through it, so a placeholder there disables native ETH for the life of the pool. It used
  ///      to default to `address(0xCAFE)` — a codeless address whose `deposit()` cannot revert
  ///      because there is nothing to call (#43). Required, and it must be the SoT's WETH: the
  ///      native sentinel resolves to wnative via PoolIO.wrap, so anything else resolves to an
  ///      asset this pool has never listed and every native path reverts NotFound.
  function _resolveWnative(string memory sot) internal view returns (address w) {
    w = vm.envAddress("WNATIVE");
    require(w.code.length > 0, "WNATIVE has no code: native ETH would be permanently bricked");
    IERC20(w).decimals(); // reverts unless it is at least a real ERC-20
    require(w == _tokenOrZero(sot, "WETH"), "WNATIVE must be the SoT WETH leg (see PoolIO.wrap)");
  }

  /// @dev Drop symbols the oracle stack does not carry (no `<SYM>` address in the SoT ⇒ no feed ⇒
  ///      validateOracleConfig would revert). Fails loud unless SKIP_UNLISTED — a silently short
  ///      pool is a money-path surprise, not a convenience.
  function _listable(Cfg memory cfg, string[] memory syms)
    internal
    view
    returns (string[] memory kept)
  {
    address[] memory toks = new address[](syms.length);
    uint256 n;
    for (uint256 i; i < syms.length; ++i) {
      address t = _tokenOrZero(cfg.sot, syms[i]);
      if (t == address(0)) {
        require(cfg.skipUnlisted, string.concat("no oracle feed for ", syms[i]));
        console2.log("SKIP (no oracle feed):", syms[i]);
        continue;
      }
      toks[n] = t;
      syms[n] = syms[i];
      ++n;
    }
    kept = new string[](n);
    for (uint256 i; i < n; ++i) {
      kept[i] = syms[i];
    }
  }

  function _tokenOrZero(string memory sot, string memory sym) internal view returns (address) {
    string memory key = string.concat(".", sym);
    if (!vm.keyExists(sot, key)) return address(0);
    return vm.parseJsonAddress(sot, key);
  }

  /// @dev Resolve one symbol's row out of the parallel arrays. Linear scan over ~26 entries at
  ///      deploy time: keeping the JSON flat (and therefore auditable against the research emit)
  ///      is worth more than the gas.
  function _paramsFor(Cfg memory cfg, string memory sym)
    internal
    view
    returns (AssetParams memory p)
  {
    string[] memory syms = vm.parseJsonStringArray(cfg.risk, ".symbols");
    uint256 idx = type(uint256).max;
    for (uint256 i; i < syms.length; ++i) {
      if (keccak256(bytes(syms[i])) == keccak256(bytes(sym))) {
        idx = i;
        break;
      }
    }
    require(idx != type(uint256).max, string.concat("risk params: missing ", sym));
    p.token = vm.parseJsonAddress(cfg.sot, string.concat(".", sym));
    p.presetId = uint16(vm.parseJsonUintArray(cfg.risk, ".presetIds")[idx]);
    p.minFeePbps = uint16(vm.parseJsonUintArray(cfg.risk, ".minFeePbps")[idx]);
    p.maxFeePbps = uint16(vm.parseJsonUintArray(cfg.risk, ".maxFeePbps")[idx]);
    p.minDisp = uint32(vm.parseJsonUintArray(cfg.risk, ".minDisp")[idx]);
    p.maxDisp = uint32(vm.parseJsonUintArray(cfg.risk, ".maxDisp")[idx]);
    p.kappaCovBps = uint16(vm.parseJsonUintArray(cfg.risk, ".kappaCovBps")[idx]);
    p.depthAmplifier = uint16(vm.parseJsonUintArray(cfg.risk, ".depthAmplifier")[idx]);
    p.haircutSuppressor = uint16(vm.parseJsonUintArray(cfg.risk, ".haircutSuppressor")[idx]);
    p.refBandBps = uint16(vm.parseJsonUintArray(cfg.risk, ".refBandBps")[idx]);
    p.refOwnFeed = vm.parseJsonBoolArray(cfg.risk, ".refOwnFeed")[idx];
    _paramFlags(cfg, p, idx);
  }

  /// @dev Boolean tail of one params row. OWN FRAME, mandatory: `_paramsFor` already carries the
  ///      symbol scan plus a dozen parse temporaries, and folding these back in overflows the
  ///      via_ir stack (profile.default builds with via_ir = true).
  function _paramFlags(Cfg memory cfg, AssetParams memory p, uint256 idx) internal view {
    // Absent key reverts here by design: a missing denomination declaration must fail the ceremony,
    // never default to "already USDC-quoted" (that is exactly the DEN-01 mispricing).
    p.usdQuoted = vm.parseJsonBoolArray(cfg.risk, ".usdQuoted")[idx];
    bytes32 cls = keccak256(bytes(vm.parseJsonStringArray(cfg.risk, ".cls")[idx]));
    p.stable = cls == keccak256(bytes("stable"));
    p.fx = cls == keccak256(bytes("fx"));
    // An unknown class would silently take the volatile tier — the loosest band in the file — so
    // reject it here instead. Adding a class is a deliberate act in BOTH files, never a fallthrough.
    require(p.stable || p.fx || cls == keccak256(bytes("volatile")), "risk params: unknown cls");
  }

  // ── reference oracle ──────────────────────────────────────────────────────────────────────

  function _deployRefOracle(address deployer) internal returns (address) {
    address[] memory signers = new address[](3);
    signers[0] = vm.envOr("REF_ORACLE_SIGNER_0", SIGNER_0);
    signers[1] = vm.envOr("REF_ORACLE_SIGNER_1", SIGNER_1);
    signers[2] = vm.envOr("REF_ORACLE_SIGNER_2", SIGNER_2);
    require(
      signers[0] != address(0) && signers[1] != address(0) && signers[2] != address(0)
        && signers[0] != signers[1] && signers[0] != signers[2] && signers[1] != signers[2],
      "invalid reference signer set (zero or duplicate)"
    );
    // Own AccessControl: the reference tier's admin domain must be separable from the primary's
    // even when (as on Sepolia) the same EOA currently owns both.
    AccessControl refAc = _deployAC(deployer, _resolveTreasury(deployer));
    return address(new ExternalOracle(address(refAc), 30, signers, SIGNER_THRESHOLD));
  }

  /// @dev Mirror + SEED one primary feed onto the reference oracle from the primary's initial mark.
  ///      This is a real seed, not just a stub: addFeed stamps updatedAt = block.timestamp, and
  ///      Oracle.observedAt falls back to updatedAt when sourceTs == 0 (legacy-added feed), so the
  ///      ref feed gates FRESH from the deploy block. That is what lets a spoke swap succeed in the
  ///      TTL window immediately after deploy (STABLE_TTL 7200s / VOLATILE_TTL 600s) BEFORE the
  ///      keeper is live. Continuous operation requires the keeper to push this feed too — the ref
  ///      oracle + its feed manifest are emitted to the pool SoT (see _persist) precisely so the
  ///      keeper config can target BOTH oracles. Idempotent: a feed already present (REF_ORACLE
  ///      reuse, or USDC/USD already mirrored for an earlier stable) is left untouched.
  function _mirrorRefFeed(Cfg memory cfg, address asset, address quote, bool stable, bool fx)
    internal
  {
    bytes32 id = keccak256(abi.encodePacked(asset, quote));
    try IOracle(cfg.refOracle).getFeed(id) returns (IOracle.FeedData memory f) {
      if (f.lastPriceB64 != 0) return;
    } catch {}
    IOracle.FeedData memory src = IOracle(cfg.oracle).getFeed(id);
    require(src.lastPriceB64 != 0, "primary feed unseeded");
    (uint16 maxDev, uint16 ttl, uint32 sigma) = _tier(stable, fx);
    ExternalOracle(cfg.refOracle).addFeed(
      asset, quote, src.lastPriceB64, sigma, CONF_SEED, maxDev, ttl
    );
  }

  // ── pools ─────────────────────────────────────────────────────────────────────────────────

  function _createPool(Deploy.Addrs memory core, Cfg memory cfg, string[] memory syms, bool stable)
    internal
    returns (address poolAddr)
  {
    address[] memory tokens = new address[](syms.length);
    for (uint256 i; i < syms.length; ++i) {
      tokens[i] = vm.parseJsonAddress(cfg.sot, string.concat(".", syms[i]));
    }
    require(tokens[0] == cfg.usdc, "pool base must be USDC (idx 0)");

    IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 20, flashFeePbps: 100});
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, tokens[0], cfg.wnative, fp);
    poolAddr = PoolFactory(payable(core.poolFactory)).createPool(tokens[0], tokens, initdata);
    Admin admin = Admin(core.admin);

    _installPresets(admin, cfg, poolAddr);
    for (uint256 i; i < syms.length; ++i) {
      _listAsset(admin, cfg, poolAddr, syms[i], stable);
    }
    // GOV-03: close the direct bootstrap path — every later listing is timelocked.
    admin.sealBootstrap(poolAddr);
    _seedPool(cfg, poolAddr, syms, tokens);
  }

  /// @dev Install EVERY preset in the risk-params file, pre-seal (a curve must exist before the
  ///      first addAsset that references it). The central-normal plateau is one cell-invariant
  ///      shape: presets differ only by wall tier W, dispersion reference, and the wall flag.
  function _installPresets(Admin admin, Cfg memory cfg, address pool) internal {
    // foundry cannot read an array's length (no `.length`, no `[*]`) — the emit ships an explicit
    // presetCount for exactly this reason.
    uint256 n = vm.parseJsonUint(cfg.risk, ".presetCount");
    require(n != 0, "risk params: no presets");
    for (uint256 i; i < n; ++i) {
      string memory base = string.concat(".presets[", vm.toString(i), "]");
      uint256[] memory interior = vm.parseJsonUintArray(cfg.risk, string.concat(base, ".interiorB"));
      int256[] memory wQ = vm.parseJsonIntArray(cfg.risk, string.concat(base, ".wQ"));
      admin.setCurve(
        pool,
        uint16(vm.parseJsonUint(cfg.risk, string.concat(base, ".id"))),
        interior,
        wQ,
        uint16(vm.parseJsonUint(cfg.risk, string.concat(base, ".dispRef"))),
        uint8(vm.parseJsonUint(cfg.risk, string.concat(base, ".flags")))
      );
    }
  }

  function _listAsset(
    Admin admin,
    Cfg memory cfg,
    address pool,
    string memory sym,
    bool stablePool
  ) internal {
    AssetParams memory p = _paramsFor(cfg, sym);
    bool isBase = p.token == cfg.usdc;
    if (!isBase && p.refBandBps != 0) {
      // The band's reference must EXIST on the reference oracle before the listing validates it.
      if (p.refOwnFeed) {
        _mirrorRefFeed(cfg, p.token, cfg.usdc, p.stable, p.fx);
      } else {
        _mirrorRefFeed(cfg, cfg.usdc, cfg.usd, true, false);
      }
    }
    admin.addAsset(
      pool,
      p.token,
      _oracleCfg(cfg, p, isBase),
      _riskCfg(p),
      p.presetId,
      p.minFeePbps,
      18,
      p.minDisp,
      p.maxDisp,
      uint16(cfg.gamma),
      uint16(cfg.vega)
    );
    // initAsset defaults maxFeePbps to 1% and haircutSuppressor to BPS; clamp both to the fitted
    // SSoT. A κ-walled leg is already forced to haircut 0 by setupOracleAndConfig — restating it
    // here keeps the two paths from silently diverging, and carries any future NAV-accruing leg
    // (κ=0 but haircut MUST be 0 — the haircut path reasons at $1-peg parity).
    admin.setAssetParams(
      pool,
      p.token,
      0,
      p.minFeePbps,
      p.maxFeePbps,
      uint16(cfg.gamma),
      uint16(cfg.vega),
      p.haircutSuppressor,
      0,
      0
    );
    stablePool; // pool class is carried per-asset in the risk params; kept for call-site clarity
  }

  function _oracleCfg(Cfg memory cfg, AssetParams memory p, bool isBase)
    internal
    view
    returns (IPool.OracleConfig memory o)
  {
    o.primary = cfg.oracle;
    o.mode = 0; // EXTERNAL — INTERNAL is forbidden for the base and unused for spokes here.
    // BASE: its mark is the SIGNED USDC/USD reference (keeper idx 23), not a USDC/USDC identity — that is
    // what makes _readBasePriceOrHalt's 500bp depeg halt bite. Ref band stays 0 (base is exempt).
    o.feedId = isBase ? cfg.usdcUsdFeed : keccak256(abi.encodePacked(p.token, cfg.usdc));
    // DEN-01: the base IS the USD reference (rejected on-chain if flagged); spokes carry the
    // catalog's denomination so Pricing re-denominates a <TOKEN>-USD mark into base units.
    o.usdQuoted = !isBase && p.usdQuoted;
    if (isBase || p.refBandBps == 0) return o;
    o.refFeedId =
      p.refOwnFeed ? keccak256(abi.encodePacked(p.token, cfg.usdc)) : cfg.usdcUsdFeed;
    o.refBandBps = p.refBandBps;
    o.refPrimary = cfg.refOracle;
  }

  /// @dev κ>0 ⇒ depthAmplifier must be 0 (the c<1 depth subsidy fights the convex wall) and the
  ///      coverage band must straddle parity. Both come from the risk-params emit; asserted here
  ///      so a bad params file fails at the script, not mid-broadcast in the pool.
  function _riskCfg(AssetParams memory p) internal pure returns (IPool.RiskConfig memory r) {
    require(p.kappaCovBps == 0 || p.depthAmplifier == 0, "kappa>0 requires depthAmplifier==0");
    require(p.kappaCovBps == 0 || p.haircutSuppressor == 0, "kappa>0 requires haircut==0");
    r.decayStartRatioBps = 5000;
    r.coverageMin = 5000;
    r.coverageMax = 20_000;
    r.depthAmplifier = p.depthAmplifier;
    r.kappaCovBps = p.kappaCovBps;
    // Testnet: swaps live at listing. Mainnet gates these behind timelocked risk updates.
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
  }

  // ── liquidity + faucet ────────────────────────────────────────────────────────────────────

  /// @dev The one mark source for the whole ceremony: the NX Rates snapshot in
  ///      deployments/<chain>.seed-marks.json, which SepoliaOracleDeploy seeded the feeds from.
  ///      Cross-checked against the on-chain feed so "the operator seeded both halves from the same
  ///      snapshot" is an assertion, not a hope — a disagreement between the seed conversion and the
  ///      feed seed is the bug class this whole path exists to close.
  function _mark(Cfg memory cfg, string memory sym, address token) internal view returns (uint256) {
    if (token == cfg.usdc) return 1e18;
    uint256 mark = vm.parseJsonUint(cfg.marks, string.concat(".marks.", sym, ".mark1e18"));
    require(mark != 0, "seed-marks: absent or zero mark");
    // Compare in the STORED domain. B64 is lossy, so decoding the feed back to 1e18 and demanding
    // equality asserts roundtrip losslessness on top of same-snapshot, and any mark carrying more
    // mantissa than B64 holds fails it spuriously (RLUSD 1000024170000000128, snapshot 2026-08-02).
    // encodeB64(mark) == lastPriceB64 is the invariant that matters: the oracle half seeded from
    // exactly this number, which is what the oracle script itself encodes.
    require(
      M.encodeB64(mark, 18)
        == IOracle(cfg.oracle).getFeed(keccak256(abi.encodePacked(token, cfg.usdc))).lastPriceB64,
      "seed mark != feed seed: oracle and pool halves used different snapshots"
    );
    return mark;
  }

  /// @dev Seed each leg with seedUsdPerLeg of USDC-equivalent, sized off the ceremony's NXR mark: a
  ///      leg seeded at a stale price starts the pool off-parity and the coverage wall immediately
  ///      tolls honest flow.
  function _seedPool(
    Cfg memory cfg,
    address poolAddr,
    string[] memory syms,
    address[] memory tokens
  ) internal {
    // mint/approve/deposit must target the broadcaster EOA. `msg.sender` inside a forge script is
    // the script contract (or DefaultSender under simulation), NOT the DEPLOYER_PK account —
    // minting there strands the seed and deposit reverts TransferFromFailed (FX ceremony 2026-07-27).
    address recipient = vm.addr(vm.envUint("DEPLOYER_PK"));
    Pool pool = Pool(payable(poolAddr));
    for (uint256 i; i < tokens.length; ++i) {
      uint256 mark = _mark(cfg, syms[i], tokens[i]);
      uint256 amt = tokens[i] == cfg.usdc ? cfg.seedUsdc : cfg.seedUsdc * 1e18 / mark;
      // BEFORE the first credit, always: the dead-share floor is written by the deposit below and
      // adminSetDeadSeedPow10 is a no-op once the leg is seeded.
      IPool(poolAddr).adminSetDeadSeedPow10(tokens[i], _deadSeedPow10(mark));
      TestnetERC20(tokens[i]).mint(recipient, amt);
      IERC20(tokens[i]).approve(poolAddr, type(uint256).max);
      pool.deposit(tokens[i], amt);
    }
  }

  /// @dev Dead-share seed as a power of ten of the leg's own unit, sized by VALUE. The on-chain
  ///      default is 0.001 TOKEN, which is only right where 1 token ~ $1: it burns ~$64 of the first
  ///      WBTC depositor and prices the KRW1 index pin at ~$54k. Largest power of ten worth at most
  ///      DEAD_SEED_TARGET_1E18 at the ceremony mark, inside the on-chain decimals+3 ceiling. Every
  ///      leg here is an 18-dp mock, which is what fixes the exponent range.
  function _deadSeedPow10(uint256 mark) internal pure returns (uint8) {
    for (uint8 p = 18 + C.DEAD_SEED_POW10_HEADROOM; p > 1; --p) {
      if (10 ** uint256(p) * mark <= DEAD_SEED_TARGET_1E18 * 1e18) return p;
    }
    return 1;
  }

  /// @dev Faucet caps DERIVE from seedUsdPerLeg (2% of a leg per day, 200 claims prefunded) so the
  ///      drip stays proportionate to pool depth from one config figure. A cap carrying its own USD
  ///      number is how a $10k/day faucet ended up 20% of a $50k leg.
  function _fundFaucet(
    Cfg memory cfg,
    TestnetFaucet faucet,
    string[] memory stableSyms,
    string[] memory volSyms
  ) internal {
    uint256 n = stableSyms.length + volSyms.length;
    address[] memory toks = new address[](n);
    uint256[] memory caps = new uint256[](n);
    uint256 k;
    for (uint256 i; i < stableSyms.length + volSyms.length; ++i) {
      bool stable = i < stableSyms.length;
      string memory sym = stable ? stableSyms[i] : volSyms[i - stableSyms.length];
      address t = vm.parseJsonAddress(cfg.sot, string.concat(".", sym));
      bool dup;
      for (uint256 j; j < k; ++j) {
        if (toks[j] == t) dup = true;
      }
      if (dup) continue;
      toks[k] = t;
      caps[k] = cfg.seedUsdc / FAUCET_CAP_DIVISOR * 1e18 / _mark(cfg, sym, t);
      ++k;
    }
    address[] memory tk = new address[](k);
    uint256[] memory ck = new uint256[](k);
    for (uint256 i; i < k; ++i) {
      tk[i] = toks[i];
      ck[i] = caps[i];
      // Prefund FAUCET_PREFUND_CLAIMS days of the cap so the drip survives a demo week untouched.
      uint256 amt = caps[i] * FAUCET_PREFUND_CLAIMS;
      address recipient = vm.addr(vm.envUint("DEPLOYER_PK"));
      TestnetERC20(tk[i]).mint(recipient, amt);
      IERC20(tk[i]).approve(address(faucet), type(uint256).max);
      faucet.fund(tk[i], amt);
    }
    faucet.setCaps(tk, ck);
  }

  // ── FX core (third pool, 2026-07-27) ──────────────────────────────────────────────────────
  // A stablecoin-FX pool of fiat-backed stables (Circle StableFX/Arc asset set), USDC-based like
  // the other two. Three entrypoints, run IN ORDER, because each needs the previous one's artifact
  // committed to the SoT and because a 30-leg ceremony in one broadcast is unreviewable:
  //   1. mintFxTokens  — the mock ERC20s (18 dp, matching every existing mock; the pool listing
  //      hardcodes 18 and _seedPool mints raw 1e18 units, so a 6-dp mock would misprice by 1e12).
  //   2. fetch marks   — `bun run sdk/scripts/fetch-seed-marks.ts` now covers the FX legs.
  //   3. addFxFeeds    — primary-oracle feeds, seeded from THAT snapshot.
  //   4. deployFxPool  — the pool itself + the existing faucet.
  // ⚠ NON-PEG LEGS: every FX leg's mark is a REAL rate (CAD/USD ~0.71, JPY/USD ~0.0061,
  // KRW/USD ~0.00068), never a 1.0 peg assumption. A defaulted or peg-clamped seed here misprices
  // by up to 1500x, so both the seed and the class tier are REQUIRED file inputs with no fallback.

  function _deployInPath() internal view returns (string memory) {
    return vm.envOr(
      "DEPLOY_IN", string.concat("deployments/", vm.toString(block.chainid), ".deploy.json")
    );
  }

  function _riskPath() internal view returns (string memory) {
    return vm.envOr("RISK_PARAMS", string("deployments/sepolia-risk-params.json"));
  }

  /// @dev vm.writeJson(value, path, key) parses `value` as JSON, so an address/bytes32 must be
  ///      QUOTED to land as the JSON string every other value in the SoT already is.
  function _jsonStr(string memory raw) internal pure returns (string memory) {
    return string.concat("\"", raw, "\"");
  }

  /// @notice Step 1: mint the FX mock ERC20s missing from the SoT. Idempotent — an existing symbol
  ///         is REUSED, never re-minted (feed_id binds keccak(asset, USDC) to an address forever).
  function mintFxTokens() external {
    require(block.chainid == 11155111, "Sepolia only");
    uint256 pk = vm.envUint("DEPLOYER_PK");
    string memory sotPath = _deployInPath();
    string memory sot = vm.readFile(sotPath);
    string[] memory syms = vm.parseJsonStringArray(vm.readFile(_riskPath()), ".fxPool");
    address[] memory minted = new address[](syms.length);
    vm.startBroadcast(pk);
    for (uint256 i; i < syms.length; ++i) {
      // CODE, not merely a SoT entry: this invocation persists the SoT itself, so a key-only test
      // makes the broadcast pass skip everything the simulation pass "minted" and send nothing.
      address have = _tokenOrZero(sot, syms[i]);
      if (have != address(0) && have.code.length > 0) continue; // USDC + EURC already exist
      minted[i] = address(new TestnetERC20(syms[i], syms[i], 18));
      console2.log("minted", syms[i], minted[i]);
    }
    vm.stopBroadcast();
    for (uint256 i; i < syms.length; ++i) {
      if (minted[i] == address(0)) continue;
      vm.writeJson(_jsonStr(vm.toString(minted[i])), sotPath, string.concat(".", syms[i]));
    }
  }

  /// @notice Step 3: add each FX leg's primary-oracle feed, seeded from the ceremony's NXR snapshot.
  ///         Append-only: new feeds take feedIds[] idx 24.. and disturb no existing feed.
  function addFxFeeds() external {
    require(block.chainid == 11155111, "Sepolia only");
    uint256 pk = vm.envUint("DEPLOYER_PK");
    Cfg memory cfg = _loadCfg();
    string memory sotPath = _deployInPath();
    string[] memory syms = vm.parseJsonStringArray(cfg.risk, ".fxPool");
    bytes32[] memory ids = new bytes32[](syms.length);
    vm.startBroadcast(pk);
    for (uint256 i; i < syms.length; ++i) {
      ids[i] = _addFxFeed(cfg, syms[i]);
    }
    vm.stopBroadcast();
    for (uint256 i; i < syms.length; ++i) {
      if (ids[i] == bytes32(0)) continue;
      vm.writeJson(
        _jsonStr(vm.toString(ids[i])), sotPath, string.concat(".feed_", syms[i])
      );
    }
  }

  /// @dev One FX leg's primary feed add. OWN FRAME, mandatory: the caller's loop already carries the
  ///      index/roster temporaries, and folding the B64 seed encode + string.concat back in
  ///      overflows the via_ir stack (profile.default builds with via_ir = true). Returns the feed
  ///      id (0 for the base, which needs no leg feed).
  function _addFxFeed(Cfg memory cfg, string memory sym) internal returns (bytes32 id) {
    AssetParams memory p = _paramsFor(cfg, sym);
    if (p.token == cfg.usdc) return bytes32(0); // base: identity feed + USDC/USD ref already exist
    id = keccak256(abi.encodePacked(p.token, cfg.usdc));
    if (_feedSeeded(cfg.oracle, id)) return id; // EURC already carries idx 22
    // parseJsonUint reverts on a missing key: a leg absent from the snapshot aborts the add
    // rather than defaulting to a peg. THIS is the 1500x guard for JPYC/KRW1.
    uint256 mark = vm.parseJsonUint(cfg.marks, string.concat(".marks.", sym, ".mark1e18"));
    require(mark != 0, "seed-marks: absent or zero FX mark");
    (uint16 maxDev, uint16 ttl, uint32 sigma) = _tier(p.stable, p.fx);
    ExternalOracle(cfg.oracle).addFeed(
      p.token, cfg.usdc, M.encodeB64(mark, 18), sigma, CONF_SEED, maxDev, ttl
    );
    console2.log("feed added", sym);
  }

  function _feedSeeded(address oracle, bytes32 id) internal view returns (bool) {
    try IOracle(oracle).getFeed(id) returns (IOracle.FeedData memory f) {
      return f.lastPriceB64 != 0;
    } catch {
      return false;
    }
  }

  /// @notice Step 4: create + list + seed the FX pool on the ALREADY-DEPLOYED core singletons.
  /// @dev Core, faucet and the REFERENCE oracle are all REUSED from 11155111.pools.json — a third
  ///      pool must share the one governance root and the one reference tier, or a spoke would band
  ///      against an oracle no keeper pushes.
  function deployFxPool() external returns (address fxPool) {
    require(block.chainid == 11155111, "Sepolia only");
    string memory outPath = _poolsOutPath();
    string memory pools = vm.readFile(outPath);
    require(
      !_deployed(outPath, ".fxPool") || vm.envOr("REDEPLOY", false),
      "already deployed: pools.json carries a live fxPool (REDEPLOY=true to override)"
    );
    uint256 pk = vm.envUint("DEPLOYER_PK");
    Cfg memory cfg = _loadCfg();

    Deploy.Addrs memory core;
    core.deployer = vm.addr(pk);
    core.ac = vm.parseJsonAddress(pools, ".ac");
    core.admin = vm.parseJsonAddress(pools, ".admin");
    core.poolFactory = vm.parseJsonAddress(pools, ".poolFactory");
    cfg.refOracle = vm.parseJsonAddress(pools, ".refOracle");
    require(
      cfg.refOracle != address(0) && cfg.refOracle != cfg.oracle
        && cfg.refOracle.code.length > 0,
      "reference oracle must be the distinct deployed contract"
    );
    require(vm.parseJsonAddress(pools, ".oracle") == cfg.oracle, "pools.json/SoT oracle mismatch");
    TestnetFaucet faucet = TestnetFaucet(vm.parseJsonAddress(pools, ".faucet"));

    string[] memory fxSyms = _listable(cfg, vm.parseJsonStringArray(cfg.risk, ".fxPool"));
    vm.startBroadcast(pk);
    fxPool = _createPool(core, cfg, fxSyms, false);
    // Register the new tokens with the EXISTING faucet so the front can dispense them. USDC/EURC
    // recur harmlessly: the cap DERIVES from seedUsdPerLeg, so a re-set is the same number.
    _fundFaucet(cfg, faucet, fxSyms, new string[](0));
    vm.stopBroadcast();

    console2.log("FX pool:", fxPool);
    vm.writeJson(_jsonStr(vm.toString(fxPool)), outPath, ".fxPool");
    // Keeper manifest for the FX legs' reference-oracle bands (see the REF KEEPER runbook note):
    // a stale ref feed fail-closes every spoke that bands against it.
    vm.writeJson(_jsonArr(_refFeedManifest(cfg, fxSyms)), outPath, ".fxRefFeeds");
    vm.writeJson(_receiptsJson(cfg, fxPool, fxSyms), outPath, ".fxReceipts");
  }

  /// @dev Per-leg ERC-20 receipt addresses, symbol -> clone. `initAsset` deploys one clone per
  ///      (pool, leg) with no factory registry to enumerate, so the SoT is the only discovery path
  ///      the front, the SDK and an integrator have.
  function _receiptsJson(Cfg memory cfg, address pool, string[] memory syms)
    internal
    view
    returns (string memory out)
  {
    out = "{";
    for (uint256 i; i < syms.length; ++i) {
      address tk = vm.parseJsonAddress(cfg.sot, string.concat(".", syms[i]));
      address lp = Pool(payable(pool)).lpToken(tk);
      require(lp != address(0), string.concat("leg receipt missing for ", syms[i]));
      out = string.concat(out, i == 0 ? "" : ",", "\"", syms[i], "\":\"", vm.toString(lp), "\"");
    }
    out = string.concat(out, "}");
  }

  /// @dev The two rosters as one list. The ref-feed manifest must cover exactly the legs THIS run
  ///      listed: `.symbols` also carries the FX roster, whose tokens do not exist in the SoT until
  ///      `mintFxTokens`, so manifesting off it aborts a from-zero ceremony at the final write.
  function _concat(string[] memory a, string[] memory b) internal pure returns (string[] memory o) {
    o = new string[](a.length + b.length);
    for (uint256 i; i < a.length; ++i) {
      o[i] = a[i];
    }
    for (uint256 i; i < b.length; ++i) {
      o[a.length + i] = b[i];
    }
  }

  function _jsonArr(string[] memory items) internal pure returns (string memory out) {
    out = "[";
    for (uint256 i; i < items.length; ++i) {
      out = string.concat(out, i == 0 ? "" : ",", "\"", items[i], "\"");
    }
    out = string.concat(out, "]");
  }

  // ── output ────────────────────────────────────────────────────────────────────────────────

  function _poolsOutPath() internal view returns (string memory) {
    // NOT the oracle SoT: vm.writeJson replaces the whole file, and clobbering
    // 11155111.deploy.json would destroy the token/feed bindings the keeper reads.
    return vm.envOr(
      "POOLS_OUT", string.concat("deployments/", vm.toString(block.chainid), ".pools.json")
    );
  }

  function _persist(
    Deploy.Addrs memory core,
    Cfg memory cfg,
    address faucet,
    address stablePool,
    address volatilePool,
    string memory outPath,
    string[] memory listed
  ) internal {
    console2.log("=== BTR Sepolia DEX ===");
    console2.log("AccessControl (reused):", core.ac);
    console2.log("Admin:                 ", core.admin);
    console2.log("PoolFactory:           ", core.poolFactory);
    console2.log("ExternalOracle (mark): ", cfg.oracle);
    console2.log("ExternalOracle (ref):  ", cfg.refOracle);
    console2.log("Faucet:                ", faucet);
    console2.log("Stable pool:           ", stablePool);
    console2.log("Volatile pool:         ", volatilePool);

    string memory k = "sepolia_pools";
    vm.serializeUint(k, "chainId", block.chainid);
    vm.serializeAddress(k, "deployer", core.deployer);
    vm.serializeAddress(k, "ac", core.ac);
    vm.serializeAddress(k, "admin", core.admin);
    vm.serializeAddress(k, "staking", core.staking);
    vm.serializeAddress(k, "distributor", core.distributor);
    vm.serializeAddress(k, "flash", core.flash);
    vm.serializeAddress(k, "poolAux", core.poolAux);
    vm.serializeAddress(k, "poolImpl", core.poolImpl);
    vm.serializeAddress(k, "poolFactory", core.poolFactory);
    // Shared UpgradeableBeacon: the contract whose implementation() every live pool executes.
    // Third upgrade path alongside the two UUPS treasuries, so it must be in the address SoT.
    vm.serializeAddress(k, "beacon", PoolFactory(payable(core.poolFactory)).beacon());
    vm.serializeAddress(k, "govToken", core.govToken);
    vm.serializeAddress(k, "treasuryProxy", core.treasuryProxy);
    vm.serializeAddress(k, "opsTreasuryProxy", core.opsTreasuryProxy);
    vm.serializeAddress(k, "oracle", cfg.oracle);
    vm.serializeAddress(k, "refOracle", cfg.refOracle);
    vm.serializeAddress(k, "faucet", faucet);
    vm.serializeAddress(k, "stablePool", stablePool);
    vm.serializeAddress(k, "volatilePool", volatilePool);
    // KEEPER MANIFEST: the reference oracle is a first-class push target. It is a SEPARATE contract
    // from the primary, so the keeper's oracle.sepolia.toml needs its address AND the exact feed
    // set it carries (a stale ref feed fail-closes every spoke swap that bands against it — TTL
    // 7200s stable / 600s vol). refFeeds names map to feed ids by keccak(token, USDC) via the token
    // addresses in 11155111.deploy.json, identically to the primary. See runbook step "REF KEEPER".
    string memory json = vm.serializeString(k, "refFeeds", _refFeedManifest(cfg, listed));

    try vm.writeJson(json, outPath) {}
    catch {
      console2.log("(skip) writeJson not permitted; JSON below:");
      console2.log(json);
    }
  }

  /// @dev The exact feed set seeded onto the reference oracle: every spoke with refOwnFeed=true
  ///      bands against its OWN pair feed (<SYM>-USDC), and every pegged stable bands against the
  ///      shared USDC-USD reference. The keeper must push all of these to the ref oracle.
  function _refFeedManifest(Cfg memory cfg, string[] memory syms)
    internal
    view
    returns (string[] memory names)
  {
    string[] memory buf = new string[](syms.length + 1);
    uint256 n;
    bool needUsdcUsd;
    for (uint256 i; i < syms.length; ++i) {
      if (keccak256(bytes(syms[i])) == keccak256(bytes("USDC"))) continue; // base, no ref feed
      if (_paramsFor(cfg, syms[i]).refOwnFeed) {
        buf[n++] = string.concat(syms[i], "-USDC");
      } else {
        needUsdcUsd = true; // a pegged stable bands against USDC/USD
      }
    }
    if (needUsdcUsd) buf[n++] = "USDC-USD";
    names = new string[](n);
    for (uint256 i; i < n; ++i) {
      names[i] = buf[i];
    }
  }
}

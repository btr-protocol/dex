// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Deploy} from "./Deploy.s.sol";
import {Admin} from "../src/Admin.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {Pool} from "../src/Pool.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {ExternalOracle} from "../src/oracles/ExternalOracle.sol";
import {TestnetERC20} from "../src/testnet/TestnetERC20.sol";
import {TestnetFaucet} from "../src/testnet/TestnetFaucet.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";

/// @title TestnetDeploy — chapel (chainId 97) full demo stack.
/// @notice Extends singleton deploy with mock ERC20s, Faucet, ExternalOracle, two pools,
///         feeds (params aligned with deploy/testnet-asset-params.json), and seed liquidity.
/// @dev Env: DEPLOYER_PK, ORACLE_SIGNER_0/1/2, REF_ORACLE + REF_ORACLE_SIGNER_0/1/2,
///         XAUT_REF_ORACLE + XAUT_REF_ORACLE_SIGNER_0/1/2,
///         XAUT_REF_FEED_ID, and ORACLE_SEED_<SYMBOL>_1E18 for every listed feed (required).
///         Optional: WNATIVE (default 0xCAFE stub),
///         SEED_USDC (default 2_000_000e18 per pool side), DEPLOY_OUT.
/// @dev Run: forge script script/TestnetDeploy.s.sol:TestnetDeploy --sig deployTestnet --rpc-url chapel --broadcast
contract TestnetDeploy is Deploy {
  uint16 internal constant STABLE_TTL = 7200;
  uint16 internal constant VOLATILE_TTL = 600;
  uint32 internal constant SIGMA_SEED = 10_000; // 1% PBPS
  uint16 internal constant CONF_SEED = 25; // bps interim
  // Per-push mark-move clamp (bps at zero staleness); grows linearly with staleness on re-sync.
  // Bounds a compromised pusher key. Stables barely move ⇒ tight; volatiles need headroom per push.
  // maxDeviation is now the microstructure FLOOR of a volatility-adaptive band
  // (allowed = floor + Z·σ·√(dtSource/interval)); σ drives the dynamic component, so the floor is
  // kept small and the ticker's own volatility sets the real per-push allowance.
  uint16 internal constant STABLE_MAXDEV = 50; // 0.5% floor (σ≈0 for pegged units)
  uint16 internal constant VOLATILE_MAXDEV = 100; // 1% floor (σ scales this up per ticker)

  struct Tokens {
    TestnetERC20 usdc;
    TestnetERC20 usdt;
    TestnetERC20 usd1;
    TestnetERC20 usde;
    TestnetERC20 fdusd;
    // Faucet-only stables (not in launch stable-core pool).
    TestnetERC20 u;
    TestnetERC20 tusd;
    TestnetERC20 usdf;
    TestnetERC20 usdd;
    TestnetERC20 btcb;
    TestnetERC20 eth;
    TestnetERC20 wbnb;
    TestnetERC20 cake;
    TestnetERC20 xaut;
  }

  struct SeedMarks {
    uint256 usdc;
    uint256 usdt;
    uint256 usd1;
    uint256 usde;
    uint256 fdusd;
    uint256 btcb;
    uint256 eth;
    uint256 wbnb;
    uint256 cake;
    uint256 xaut;
  }

  struct SignerSets {
    address[3] primary;
    address[3] stableReference;
    address[3] xautReference;
  }

  struct TestnetAddrs {
    Deploy.Addrs core;
    ExternalOracle oracle;
    TestnetFaucet faucet;
    Tokens tok;
    bytes32 usdcFeedId;
    address stablePool;
    address volatilePool;
  }

  function deployTestnet() external returns (TestnetAddrs memory out) {
    SignerSets memory signerSets = _loadSignerSets();
    address refOracle = vm.envAddress("REF_ORACLE");
    address xautRefOracle = vm.envAddress("XAUT_REF_ORACLE");
    bytes32 xautRefFeedId = vm.envBytes32("XAUT_REF_FEED_ID");
    uint256 pk = vm.envUint("DEPLOYER_PK");
    address deployer = vm.addr(pk);
    _validateReferenceOracles(refOracle, xautRefOracle, signerSets, deployer);
    SeedMarks memory seedMarks = _loadSeedMarks();

    out.core = _broadcastDeploy();
    require(out.core.deployer == deployer, "unexpected core deployer");
    address wnative = vm.envOr("WNATIVE", address(0xCAFE));
    uint256 seedUsdc = vm.envOr("SEED_USDC", uint256(2_000_000 ether));

    vm.startBroadcast(pk);

    out.tok = _deployTokens();
    out.faucet = new TestnetFaucet(deployer);
    _configureFaucet(out);
    address[] memory initialSigners = new address[](3);
    initialSigners[0] = signerSets.primary[0];
    initialSigners[1] = signerSets.primary[1];
    initialSigners[2] = signerSets.primary[2];
    // lag 30s couples with Pricing.STALE_GRACE_CAP_S = 30 (L-1): a longer oracle lag would leave a
    // window where the pool's staleness premium is capped below the actual mark age.
    out.oracle = new ExternalOracle(out.core.ac, 30, initialSigners, 2);
    require(
      refOracle != address(0) && refOracle != address(out.oracle), "independent REF_ORACLE required"
    );
    require(
      xautRefOracle != address(0) && xautRefOracle != address(out.oracle),
      "independent XAUT_REF_ORACLE required"
    );
    require(
      xautRefFeedId == keccak256(abi.encodePacked(address(out.tok.xaut), address(out.tok.usdc))),
      "XAUT_REF_FEED_ID must be XAUT/USDC"
    );

    out.usdcFeedId = _seedFeeds(out.oracle, out.tok, seedMarks);

    // M-1 P3 extension of _validateReferenceOracles (token addresses only exist post-deploy):
    // the 4 volatile-core asset/USDC ref feeds must EXIST on REF_ORACLE before listing, else the
    // refBand=300 configs below are unexecutable (validateOracleConfig requires a reachable ref).
    _requireVolatileRefFeeds(refOracle, out.tok);

    out.stablePool = _createPool(
      out,
      wnative,
      _stableList(out.tok),
      seedUsdc,
      true,
      refOracle,
      xautRefOracle,
      xautRefFeedId,
      seedMarks
    );
    out.volatilePool = _createPool(
      out,
      wnative,
      _volatileList(out.tok),
      seedUsdc,
      false,
      refOracle,
      xautRefOracle,
      xautRefFeedId,
      seedMarks
    );

    _fundFaucet(out);

    vm.stopBroadcast();

    _logTestnet(out);
    _persistTestnet(out);
  }

  function _deployTokens() internal returns (Tokens memory t) {
    t.usdc = new TestnetERC20("USD Coin", "USDC", 18);
    t.usdt = new TestnetERC20("Tether USD", "USDT", 18);
    t.usd1 = new TestnetERC20("World Liberty USD", "USD1", 18);
    t.usde = new TestnetERC20("Ethena USDe", "USDE", 18);
    t.fdusd = new TestnetERC20("First Digital USD", "FDUSD", 18);
    t.u = new TestnetERC20("United Stable", "U", 18);
    t.tusd = new TestnetERC20("TrueUSD", "TUSD", 18);
    t.usdf = new TestnetERC20("Astherus USDF", "USDF", 18);
    t.usdd = new TestnetERC20("USDD", "USDD", 18);
    t.btcb = new TestnetERC20("Bitcoin BEP20", "BTCB", 18);
    t.eth = new TestnetERC20("Ethereum Peg", "ETH", 18);
    t.wbnb = new TestnetERC20("Wrapped BNB", "WBNB", 18);
    t.cake = new TestnetERC20("PancakeSwap", "CAKE", 18);
    t.xaut = new TestnetERC20("Tether Gold", "XAUT", 18);
  }

  function _configureFaucet(TestnetAddrs memory ctx) internal {
    Tokens memory t = ctx.tok;
    address[] memory tokens = new address[](13);
    uint256[] memory caps = new uint256[](13);
    // Stables: $10k/day each
    tokens[0] = address(t.usdc);
    caps[0] = 10_000 ether;
    tokens[1] = address(t.usdt);
    caps[1] = 10_000 ether;
    tokens[2] = address(t.usd1);
    caps[2] = 10_000 ether;
    tokens[3] = address(t.usde);
    caps[3] = 10_000 ether;
    tokens[4] = address(t.fdusd);
    caps[4] = 10_000 ether;
    tokens[5] = address(t.u);
    caps[5] = 10_000 ether;
    tokens[6] = address(t.tusd);
    caps[6] = 10_000 ether;
    tokens[7] = address(t.usdf);
    caps[7] = 10_000 ether;
    tokens[8] = address(t.usdd);
    caps[8] = 10_000 ether;
    // Volatiles
    tokens[9] = address(t.btcb);
    caps[9] = 0.1 ether;
    tokens[10] = address(t.eth);
    caps[10] = 5 ether;
    tokens[11] = address(t.wbnb);
    caps[11] = 10 ether;
    tokens[12] = address(t.cake);
    caps[12] = 4_000 ether;
    ctx.faucet.setCaps(tokens, caps);
  }

  function _loadSeedMarks() internal view returns (SeedMarks memory m) {
    m.usdc = _seedMark("ORACLE_SEED_USDC_1E18");
    // This feed is keyed as USDC/USDC, so its mark is an identity by construction. Accepting a
    // market USD price here would seed a dimensionally-invalid reference and can either halt every
    // ref-banded stable or strand the first signed push behind the tight bootstrap deviation band.
    require(m.usdc == 1e18, "USDC/USDC seed must equal 1e18");
    m.usdt = _seedMark("ORACLE_SEED_USDT_1E18");
    m.usd1 = _seedMark("ORACLE_SEED_USD1_1E18");
    m.usde = _seedMark("ORACLE_SEED_USDE_1E18");
    m.fdusd = _seedMark("ORACLE_SEED_FDUSD_1E18");
    m.btcb = _seedMark("ORACLE_SEED_BTCB_1E18");
    m.eth = _seedMark("ORACLE_SEED_ETH_1E18");
    m.wbnb = _seedMark("ORACLE_SEED_WBNB_1E18");
    m.cake = _seedMark("ORACLE_SEED_CAKE_1E18");
    m.xaut = _seedMark("ORACLE_SEED_XAUT_1E18");
  }

  function _loadSignerSets() internal view returns (SignerSets memory s) {
    s.primary[0] = vm.envAddress("ORACLE_SIGNER_0");
    s.primary[1] = vm.envAddress("ORACLE_SIGNER_1");
    s.primary[2] = vm.envAddress("ORACLE_SIGNER_2");
    s.stableReference[0] = vm.envAddress("REF_ORACLE_SIGNER_0");
    s.stableReference[1] = vm.envAddress("REF_ORACLE_SIGNER_1");
    s.stableReference[2] = vm.envAddress("REF_ORACLE_SIGNER_2");
    s.xautReference[0] = vm.envAddress("XAUT_REF_ORACLE_SIGNER_0");
    s.xautReference[1] = vm.envAddress("XAUT_REF_ORACLE_SIGNER_1");
    s.xautReference[2] = vm.envAddress("XAUT_REF_ORACLE_SIGNER_2");

    _validateSignerSets(s);
  }

  function _validateSignerSets(SignerSets memory s) internal pure {
    address[] memory all = new address[](9);
    for (uint256 i; i < 3; ++i) {
      all[i] = s.primary[i];
      all[i + 3] = s.stableReference[i];
      all[i + 6] = s.xautReference[i];
    }
    for (uint256 i; i < all.length; ++i) {
      require(all[i] != address(0), "nine nonzero oracle signers required");
      for (uint256 j; j < i; ++j) {
        require(all[i] != all[j], "oracle signer sets must be disjoint");
      }
    }
  }

  function _validateReferenceOracles(
    address refOracle,
    address xautRefOracle,
    SignerSets memory s,
    address primaryOwner
  ) internal view {
    require(
      refOracle != address(0) && xautRefOracle != address(0) && refOracle != xautRefOracle,
      "distinct reference oracles required"
    );
    (address refAc, address refOwner) =
      _validateReferenceOracle(refOracle, s.stableReference, "invalid REF_ORACLE signer set");
    (address xautRefAc, address xautRefOwner) =
      _validateReferenceOracle(xautRefOracle, s.xautReference, "invalid XAUT_REF_ORACLE signer set");
    require(refAc != xautRefAc, "reference oracle ACs must differ");
    require(
      refOwner != primaryOwner && xautRefOwner != primaryOwner && refOwner != xautRefOwner,
      "oracle governance owners must differ"
    );
  }

  function _validateReferenceOracle(
    address oracle,
    address[3] memory expectedSigners,
    string memory errorMessage
  ) internal view returns (address acAddr, address owner) {
    require(oracle.code.length != 0, errorMessage);
    ExternalOracle ref = ExternalOracle(oracle);
    require(
      ref.signerCount() == 3 && ref.signerThreshold() >= 2 && ref.pendingSignerGrantOp() == 0
        && ref.pendingSignerThresholdOp() == 0 && ref.SIGNER_GOV_TIMELOCK() == 2 days
        && ref.SIGNER_GOV_GRACE() == 7 days,
      errorMessage
    );
    for (uint256 i; i < expectedSigners.length; ++i) {
      require(ref.signers(expectedSigners[i]), errorMessage);
    }
    acAddr = ref.AC();
    require(acAddr.code.length != 0, errorMessage);
    owner = AccessControl(acAddr).owner();
    require(owner != address(0), errorMessage);
  }

  function _requireVolatileRefFeeds(address refOracle, Tokens memory t) internal view {
    address usdc = address(t.usdc);
    address[4] memory vols = [address(t.btcb), address(t.eth), address(t.wbnb), address(t.cake)];
    for (uint256 i; i < vols.length; ++i) {
      try ExternalOracle(refOracle).getFeed(keccak256(abi.encodePacked(vols[i], usdc))) {}
      catch {
        revert("REF_ORACLE missing volatile asset/USDC feed");
      }
    }
  }

  function _seedMark(string memory envName) internal view returns (uint256 mark1e18) {
    mark1e18 = vm.envUint(envName);
    require(mark1e18 != 0 && M.encodeB64(mark1e18, 18) != 0, "invalid oracle seed mark");
  }

  function _seedFeeds(ExternalOracle oracle, Tokens memory t, SeedMarks memory m)
    internal
    returns (bytes32 usdcFeed)
  {
    address usdc = address(t.usdc);
    usdcFeed = keccak256(abi.encodePacked(usdc, usdc));
    oracle.addFeed(
      usdc, usdc, M.encodeB64(m.usdc, 18), SIGMA_SEED, CONF_SEED, STABLE_MAXDEV, STABLE_TTL
    );

    _addPairFeed(oracle, address(t.usdt), usdc, M.encodeB64(m.usdt, 18), STABLE_MAXDEV, STABLE_TTL);
    _addPairFeed(oracle, address(t.usd1), usdc, M.encodeB64(m.usd1, 18), STABLE_MAXDEV, STABLE_TTL);
    _addPairFeed(oracle, address(t.usde), usdc, M.encodeB64(m.usde, 18), STABLE_MAXDEV, STABLE_TTL);
    _addPairFeed(
      oracle, address(t.fdusd), usdc, M.encodeB64(m.fdusd, 18), STABLE_MAXDEV, STABLE_TTL
    );
    _addPairFeed(
      oracle, address(t.btcb), usdc, M.encodeB64(m.btcb, 18), VOLATILE_MAXDEV, VOLATILE_TTL
    );
    _addPairFeed(
      oracle, address(t.eth), usdc, M.encodeB64(m.eth, 18), VOLATILE_MAXDEV, VOLATILE_TTL
    );
    _addPairFeed(
      oracle, address(t.wbnb), usdc, M.encodeB64(m.wbnb, 18), VOLATILE_MAXDEV, VOLATILE_TTL
    );
    _addPairFeed(
      oracle, address(t.cake), usdc, M.encodeB64(m.cake, 18), VOLATILE_MAXDEV, VOLATILE_TTL
    );
    _addPairFeed(
      oracle, address(t.xaut), usdc, M.encodeB64(m.xaut, 18), VOLATILE_MAXDEV, VOLATILE_TTL
    );
  }

  function _addPairFeed(
    ExternalOracle oracle,
    address asset,
    address usdc,
    uint64 priceB64,
    uint16 maxDev,
    uint16 ttl
  ) internal {
    oracle.addFeed(asset, usdc, priceB64, SIGMA_SEED, CONF_SEED, maxDev, ttl);
  }

  function _stableList(Tokens memory t) internal pure returns (address[] memory list) {
    list = new address[](5);
    list[0] = address(t.usdc);
    list[1] = address(t.usdt);
    list[2] = address(t.usd1);
    list[3] = address(t.usde);
    list[4] = address(t.fdusd);
  }

  function _volatileList(Tokens memory t) internal pure returns (address[] memory list) {
    list = new address[](7);
    list[0] = address(t.usdc);
    list[1] = address(t.usdt);
    list[2] = address(t.btcb);
    list[3] = address(t.eth);
    list[4] = address(t.wbnb);
    list[5] = address(t.cake);
    list[6] = address(t.xaut);
  }

  function _createPool(
    TestnetAddrs memory ctx,
    address wnative,
    address[] memory tokens,
    uint256 seedUsdc,
    bool stable,
    address refOracle,
    address xautRefOracle,
    bytes32 xautRefFeedId,
    SeedMarks memory seedMarks
  ) internal returns (address poolAddr) {
    IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 20, flashFeePbps: 100});
    bytes memory initdata = abi.encodeWithSelector(Pool.initialize.selector, tokens[0], wnative, fp);
    poolAddr = PoolFactory(payable(ctx.core.poolFactory)).createPool(tokens[0], tokens, initdata);
    Pool pool = Pool(payable(poolAddr));
    Admin admin = Admin(ctx.core.admin);
    IPool.RiskConfig memory rc = _risk();
    // Preset 1 (generic default) must exist pre-seal, before the first addAsset referencing it.
    (uint256[] memory interior, int256[] memory wQ) = _curve();
    admin.setCurve(poolAddr, 1, interior, wQ, 1000, 0);

    for (uint256 i = 0; i < tokens.length; i++) {
      address tok = tokens[i];
      (uint16 minFee, uint16 refBand) = _assetParams(tok, ctx.tok, stable);
      bool volatileCore = !stable && tok != address(ctx.tok.usdc) && tok != address(ctx.tok.usdt)
        && tok != address(ctx.tok.xaut);
      IPool.OracleConfig memory oc = _oracleCfg(
        address(ctx.oracle),
        tok,
        tokens[0],
        address(ctx.tok.xaut),
        ctx.usdcFeedId,
        refBand,
        volatileCore,
        refOracle,
        xautRefOracle,
        xautRefFeedId
      );
      admin.addAsset(poolAddr, tok, oc, rc, 1, minFee, 18, 1000, 100_000, 10_000, 10_000);
    }

    // The listed base asset's OracleConfig is its depeg breaker.
    admin.sealBootstrap(poolAddr);

    _seedPool(pool, ctx.tok, tokens, seedUsdc, seedMarks);
  }

  function _assetParams(address tok, Tokens memory t, bool stable)
    internal
    pure
    returns (uint16 minFee, uint16 refBand)
  {
    minFee = 1;
    refBand = 0;
    if (tok == address(t.usdt)) refBand = 100;
    else if (stable && tok != address(t.usdc)) refBand = 150;
    else if (!stable && tok == address(t.xaut)) refBand = 200;
    // M-1: every EXTERNAL spoke needs a cumulative bound; BTCB/ETH/WBNB/CAKE get a 3% cross-oracle
    // tolerance vs their OWN pair feed on REF_ORACLE (USDC = base, exempt; band unused there).
    else if (!stable && tok != address(t.usdc)) refBand = 300;
  }

  function _oracleCfg(
    address oracle,
    address asset,
    address base,
    address xaut,
    bytes32 usdcFeedId,
    uint16 refBandBps,
    bool volatileCore,
    address refOracle,
    address xautRefOracle,
    bytes32 xautRefFeedId
  ) internal pure returns (IPool.OracleConfig memory o) {
    o.primary = oracle;
    o.feedId = keccak256(abi.encodePacked(asset, base));
    if (refBandBps != 0) {
      bool isXaut = asset == xaut;
      // Volatile non-pegged assets ref their OWN pair feed on the independent oracle; comparing a
      // non-USD mark to the unit-price USDC feed would halt permanently.
      o.refFeedId = isXaut ? xautRefFeedId : volatileCore ? o.feedId : usdcFeedId;
      o.refBandBps = refBandBps;
      o.refPrimary = isXaut ? xautRefOracle : refOracle;
    }
    o.mode = 0;
  }

  function _risk() internal pure returns (IPool.RiskConfig memory r) {
    r.decayStartRatioBps = 5000;
    r.coverageMin = 5000;
    r.coverageMax = 20_000;
    r.depthAmplifier = 10_000;
    // Chapel demo: enable swaps at listing (prod gates these via timelocked risk updates).
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
  }

  // placeholder: production weights come from research/stable-core/out/spline_shared_grid.json at deploy
  /// @dev Preset 1 = generic default: linear ±500 pbps ramp over 9 quartic weights.
  function _curve() internal pure returns (uint256[] memory interior, int256[] memory wQ) {
    interior = new uint256[](4);
    interior[0] = 2000;
    interior[1] = 4000;
    interior[2] = 6000;
    interior[3] = 8000;
    wQ = new int256[](9);
    for (uint256 i = 0; i < 9; i++) {
      wQ[i] = (int256(i) - 4) * 125_000_000_000;
    }
  }

  function _seedPool(
    Pool pool,
    Tokens memory t,
    address[] memory tokens,
    uint256 seedUsdc,
    SeedMarks memory seedMarks
  ) internal {
    for (uint256 i = 0; i < tokens.length; i++) {
      address tok = tokens[i];
      uint256 amt = _seedAmount(tok, t, seedUsdc, seedMarks);
      TestnetERC20(tok).mint(msg.sender, amt);
      IERC20(tok).approve(address(pool), type(uint256).max);
      pool.deposit(tok, amt);
    }
  }

  function _seedAmount(address tok, Tokens memory t, uint256 seedUsdc, SeedMarks memory m)
    internal
    pure
    returns (uint256)
  {
    if (tok == address(t.usdc)) return seedUsdc;
    uint256 mark;
    if (tok == address(t.usdt)) mark = m.usdt;
    else if (tok == address(t.usd1)) mark = m.usd1;
    else if (tok == address(t.usde)) mark = m.usde;
    else if (tok == address(t.fdusd)) mark = m.fdusd;
    else if (tok == address(t.btcb)) mark = m.btcb;
    else if (tok == address(t.eth)) mark = m.eth;
    else if (tok == address(t.wbnb)) mark = m.wbnb;
    else if (tok == address(t.cake)) mark = m.cake;
    else if (tok == address(t.xaut)) mark = m.xaut;
    else revert("unknown seed token");
    return seedUsdc * 1e18 / mark;
  }

  function _fundFaucet(TestnetAddrs memory ctx) internal {
    // Fund only claimable tokens (XAUT has no faucet cap).
    address[] memory all = new address[](13);
    Tokens memory t = ctx.tok;
    all[0] = address(t.usdc);
    all[1] = address(t.usdt);
    all[2] = address(t.usd1);
    all[3] = address(t.usde);
    all[4] = address(t.fdusd);
    all[5] = address(t.u);
    all[6] = address(t.tusd);
    all[7] = address(t.usdf);
    all[8] = address(t.usdd);
    all[9] = address(t.btcb);
    all[10] = address(t.eth);
    all[11] = address(t.wbnb);
    all[12] = address(t.cake);
    for (uint256 i = 0; i < all.length; i++) {
      // Volatile caps are small — still prefund generously for many claimers.
      uint256 amt = 1_000_000 ether;
      if (all[i] == address(t.btcb)) amt = 100 ether;
      TestnetERC20(all[i]).mint(msg.sender, amt);
      IERC20(all[i]).approve(address(ctx.faucet), type(uint256).max);
      ctx.faucet.fund(all[i], amt);
    }
  }

  function _logTestnet(TestnetAddrs memory a) internal view {
    console2.log("=== BTR chapel testnet ===");
    console2.log("ExternalOracle:", address(a.oracle));
    console2.log("Faucet:", address(a.faucet));
    console2.log("Stable pool:", a.stablePool);
    console2.log("Volatile pool:", a.volatilePool);
    console2.log("USDC feedId:");
    console2.logBytes32(a.usdcFeedId);
  }

  function _persistTestnet(TestnetAddrs memory a) internal {
    string memory k = "chapel";
    vm.serializeUint(k, "chainId", block.chainid);
    vm.serializeAddress(k, "oracle", address(a.oracle));
    vm.serializeAddress(k, "faucet", address(a.faucet));
    vm.serializeAddress(k, "stablePool", a.stablePool);
    vm.serializeAddress(k, "volatilePool", a.volatilePool);
    vm.serializeBytes32(k, "usdcFeedId", a.usdcFeedId);
    vm.serializeAddress(k, "poolFactory", a.core.poolFactory);
    vm.serializeAddress(k, "admin", a.core.admin);
    vm.serializeAddress(k, "ac", a.core.ac);
    vm.serializeAddress(k, "usdc", address(a.tok.usdc));
    vm.serializeAddress(k, "usdt", address(a.tok.usdt));
    vm.serializeAddress(k, "usd1", address(a.tok.usd1));
    vm.serializeAddress(k, "usde", address(a.tok.usde));
    vm.serializeAddress(k, "fdusd", address(a.tok.fdusd));
    vm.serializeAddress(k, "u", address(a.tok.u));
    vm.serializeAddress(k, "tusd", address(a.tok.tusd));
    vm.serializeAddress(k, "usdf", address(a.tok.usdf));
    vm.serializeAddress(k, "usdd", address(a.tok.usdd));
    vm.serializeAddress(k, "btcb", address(a.tok.btcb));
    vm.serializeAddress(k, "eth", address(a.tok.eth));
    vm.serializeAddress(k, "wbnb", address(a.tok.wbnb));
    vm.serializeAddress(k, "cake", address(a.tok.cake));
    string memory json = vm.serializeAddress(k, "xaut", address(a.tok.xaut));

    string memory outPath = vm.envOr(
      "DEPLOY_OUT", string.concat("deployments/", vm.toString(block.chainid), ".deploy.json")
    );
    try vm.writeJson(json, outPath) {}
    catch {
      console2.log("(skip) writeJson not permitted");
    }
  }
}

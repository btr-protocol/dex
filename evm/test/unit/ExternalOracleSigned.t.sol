// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {ExternalOracle} from "../../src/oracles/ExternalOracle.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {Oracle} from "../../src/libraries/Oracle.sol";
import {Maths as M} from "../../src/libraries/Maths.sol";
import {Err} from "@btr-shared/Errors.sol";
import {MockAC} from "../fixtures/BaseTestSetup.sol";

/// @notice NXR-signed push path (batchPushSigned) — the SOLE mark-update path. Verifies EIP-712 auth,
///         monotonic-sourceTs replay guard, one-per-block, deviation band + staleness scaling, and gas.
///         See ORACLE_SIGNED_PUSH_SPEC.md. Money path — pre-security-review reference tests.
contract ExternalOracleSignedTest is Test {
  ExternalOracle ext;
  MockAC ac;
  address constant BASE = address(0xB05E);
  address constant QUOTE = address(0x9907E);
  bytes32 feedId;

  uint16 constant TAU = 100;
  uint256 constant NXR_PK = 0xA11CE;
  address nxr;

  bytes32 constant BATCH_TYPEHASH = keccak256("BatchQuote(bytes32 blobHash)");

  function setUp() public {
    ac = new MockAC(address(this));
    ext = new ExternalOracle(address(ac), 600);
    vm.warp(1_700_000_000);
    ext.addFeed(
      BASE, QUOTE, M.encodeB64(3000e18, 18), 1e4, 5, TAU, TAU, ext.MAX_DEV_THRESHOLD(), 3600
    );
    feedId = keccak256(abi.encodePacked(BASE, QUOTE)); // feedIds[0], idx = 0
    nxr = vm.addr(NXR_PK);
    ext.grantSigner(nxr);
  }

  // ─── helpers ───

  function _rec(uint16 idx, uint64 price, uint32 sigma, uint16 conf, uint64 sourceTs)
    internal
    pure
    returns (bytes memory)
  {
    return abi.encodePacked(idx, price, sigma, conf, sourceTs); // 2+8+4+2+8 = 24 B
  }

  function _domainSep() internal view returns (bytes32) {
    return keccak256(
      abi.encode(
        keccak256(
          "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        ),
        keccak256(bytes("BTR ExternalOracle")),
        keccak256(bytes("1")),
        block.chainid,
        address(ext)
      )
    );
  }

  function _sign(uint256 pk, bytes memory blob) internal view returns (bytes memory) {
    bytes32 structHash = keccak256(abi.encode(BATCH_TYPEHASH, keccak256(blob)));
    bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSep(), structHash));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
    return abi.encodePacked(r, s, v);
  }

  function _srcTs() internal view returns (uint64) {
    return uint64(block.timestamp) * 1000; // ms, < 2^48, monotonic as we warp
  }

  // ─── happy path ───

  function test_batchPushSigned_commitsQuote() public {
    skip(TAU);
    bytes memory blob = _rec(0, M.encodeB64(3030e18, 18), 2e4, 7, _srcTs());
    ext.batchPushSigned(blob, _sign(NXR_PK, blob));

    IOracle.FeedData memory f = ext.getFeed(feedId);
    assertApproxEqRel(M.b64To1e18(f.lastPriceB64), 3030e18, 0.001e18, "signed mark committed");
    assertEq(f.sigmaEma, 2e4, "signed sigma stored DIRECTLY (no on-chain EMA)");
    assertEq(f.confidence, 7, "signed confidence");
    assertEq(f.updatedAt, uint32(block.timestamp), "updatedAt = block.timestamp");
    assertEq(f.ttl, 3600, "ttl preserved");
    assertEq(f.maxDeviation, ext.MAX_DEV_THRESHOLD(), "maxDeviation preserved");
  }

  function test_relayer_isUnpermissioned() public {
    skip(TAU);
    bytes memory blob = _rec(0, M.encodeB64(3010e18, 18), 1e4, 5, _srcTs());
    bytes memory sig = _sign(NXR_PK, blob);
    vm.prank(address(0xBEEF)); // arbitrary relay, no oracle/signer grant
    ext.batchPushSigned(blob, sig);
    assertApproxEqRel(
      M.b64To1e18(ext.getFeed(feedId).lastPriceB64), 3010e18, 0.001e18, "any relay can land"
    );
  }

  // ─── auth ───

  function test_reject_unknownSigner() public {
    skip(TAU);
    bytes memory blob = _rec(0, M.encodeB64(3010e18, 18), 1e4, 5, _srcTs());
    bytes memory sig = _sign(0xBADBAD, blob); // not a granted signer
    vm.expectRevert(Err.NotAuth.selector);
    ext.batchPushSigned(blob, sig);
  }

  function test_reject_revokedSigner() public {
    ext.revokeSigner(nxr);
    skip(TAU);
    bytes memory blob = _rec(0, M.encodeB64(3010e18, 18), 1e4, 5, _srcTs());
    vm.expectRevert(Err.NotAuth.selector);
    ext.batchPushSigned(blob, _sign(NXR_PK, blob));
  }

  function test_reject_tamperedBlob() public {
    skip(TAU);
    bytes memory blob = _rec(0, M.encodeB64(3010e18, 18), 1e4, 5, _srcTs());
    bytes memory sig = _sign(NXR_PK, blob);
    bytes memory tampered = _rec(0, M.encodeB64(9999e18, 18), 1e4, 5, _srcTs()); // different price
    vm.expectRevert(Err.NotAuth.selector); // recovered signer != nxr → not in signers
    ext.batchPushSigned(tampered, sig);
  }

  // ─── replay / monotonic sourceTs ───

  function test_reject_replaySameBatch() public {
    skip(TAU);
    bytes memory blob = _rec(0, M.encodeB64(3020e18, 18), 1e4, 5, _srcTs());
    bytes memory sig = _sign(NXR_PK, blob);
    ext.batchPushSigned(blob, sig);
    skip(TAU); // advance block so it's not the cooldown that trips
    vm.expectRevert(Err.InvalidInput.selector); // same sourceTs ≤ stored → monotonic reject
    ext.batchPushSigned(blob, sig);
  }

  function test_reject_staleSourceTs() public {
    skip(TAU);
    uint64 ts = _srcTs();
    bytes memory a = _rec(0, M.encodeB64(3020e18, 18), 1e4, 5, ts);
    ext.batchPushSigned(a, _sign(NXR_PK, a));
    skip(TAU);
    bytes memory b = _rec(0, M.encodeB64(3025e18, 18), 1e4, 5, ts - 1); // older sourceTs
    vm.expectRevert(Err.InvalidInput.selector);
    ext.batchPushSigned(b, _sign(NXR_PK, b));
  }

  // ─── one-per-block ───

  function test_reject_sameBlockRepush() public {
    skip(TAU);
    bytes memory a = _rec(0, M.encodeB64(3020e18, 18), 1e4, 5, _srcTs());
    ext.batchPushSigned(a, _sign(NXR_PK, a));
    // same block, fresher sourceTs → one-per-block guard trips (CooldownActive)
    bytes memory b = _rec(0, M.encodeB64(3021e18, 18), 1e4, 5, _srcTs() + 1);
    vm.expectRevert(abi.encodeWithSelector(Err.CooldownActive.selector, uint256(1)));
    ext.batchPushSigned(b, _sign(NXR_PK, b));
  }

  // ─── deviation band (backstops a compromised push quorum; SOURCE-time-driven) ───

  /// @dev Adds a 5%-band feed (idx 1) and lands a first signed push to seed sourceTs — the band is
  ///      source-time-driven, and a prevSourceTs of 0 (fresh addFeed) caps it at MAX_DEV_THRESHOLD.
  function _seedBandedFeed() internal returns (bytes32 id) {
    address da = address(0xDA5E);
    address db = address(0xDB5E);
    ext.addFeed(da, db, M.encodeB64(100e18, 18), 1e4, 5, TAU, TAU, 500, 3600); // 5% band, ttl 3600, idx=1
    id = keccak256(abi.encodePacked(da, db));
    skip(TAU);
    bytes memory seed = _rec(1, M.encodeB64(100e18, 18), 1e4, 5, _srcTs());
    ext.batchPushSigned(seed, _sign(NXR_PK, seed));
  }

  function test_reject_outOfBand() public {
    _seedBandedFeed();
    skip(10); // source delta 10s → band = 500·(1+10/3600) = 501
    bytes memory blob = _rec(1, M.encodeB64(110e18, 18), 1e4, 5, _srcTs()); // +10% ≫ 5%
    vm.expectRevert(
      abi.encodeWithSelector(Err.ThresholdViolation.selector, uint256(1000), uint256(501))
    );
    ext.batchPushSigned(blob, _sign(NXR_PK, blob));
  }

  /// H-2: the band grows LINEARLY with SOURCE staleness — maxDev·(1+dtSource/ttl) — so a legit
  /// post-gap re-sync passes but an arbitrary jump bought by inducing staleness stays bounded.
  /// At dtSource=ttl the band doubles.
  function test_deviationBand_scalesWithSourceStaleness() public {
    bytes32 id = _seedBandedFeed();
    skip(3600); // source delta = ttl → band = 500·(1+1) = 1000 bps (10%)
    // A +200% jump is REJECTED even fully stale (was allowed under the old dt>=ttl exemption).
    bytes memory j = _rec(1, M.encodeB64(300e18, 18), 1e4, 5, _srcTs());
    vm.expectRevert(
      abi.encodeWithSelector(Err.ThresholdViolation.selector, uint256(20000), uint256(1000))
    );
    ext.batchPushSigned(j, _sign(NXR_PK, j));
    // A move within the doubled band commits (legit post-downtime drift).
    bytes memory ok = _rec(1, M.encodeB64(108e18, 18), 1e4, 5, _srcTs()); // +8% < 10%
    ext.batchPushSigned(ok, _sign(NXR_PK, ok));
    assertApproxEqRel(
      M.b64To1e18(ext.getFeed(id).lastPriceB64), 108e18, 0.001e18, "in-band re-sync committed"
    );
  }

  /// Layer-2 (Ostium hardening): the band is bound to ATTESTED source time, not blocks — a fast
  /// chain (many blocks, tiny sourceTs deltas) earns NO extra cumulative allowance. Two rapid
  /// pushes 1 wall-second apart with sub-second source deltas each get the flat 500-bps band.
  function test_sourceTimeBand_fastChainGetsNoExtraAllowance() public {
    bytes32 id = _seedBandedFeed();
    uint64 ts = _srcTs();
    skip(1); // next block (clears the one-per-block cooldown), source delta 400ms → dtSource = 0
    bytes memory a = _rec(1, M.encodeB64(105_02e16, 18), 1e4, 5, ts + 400); // +5.02% > flat 5%
    vm.expectRevert(
      abi.encodeWithSelector(Err.ThresholdViolation.selector, uint256(502), uint256(500))
    );
    ext.batchPushSigned(a, _sign(NXR_PK, a));
    bytes memory b = _rec(1, M.encodeB64(104_9e17, 18), 1e4, 5, ts + 400); // +4.9% < 5% lands
    ext.batchPushSigned(b, _sign(NXR_PK, b));
    // Second rapid push: another sub-second source delta → flat band again, off the NEW mark.
    skip(1);
    bytes memory c = _rec(1, M.encodeB64(110_2e17, 18), 1e4, 5, ts + 800); // +5.05% off 104.9 > 5%
    vm.expectPartialRevert(Err.ThresholdViolation.selector);
    ext.batchPushSigned(c, _sign(NXR_PK, c));
    assertApproxEqRel(
      M.b64To1e18(ext.getFeed(id).lastPriceB64), 104.9e18, 0.001e18, "walk capped at one band step"
    );
  }

  /// Wall-clock staleness no longer widens the band: a 1-hour block gap with a 1-second source
  /// delta keeps the flat band (the attacker cannot buy allowance by waiting out blocks), while
  /// the one-per-block cooldown stays block-time-based.
  function test_sourceTimeBand_wallGapWithoutSourceGapStaysFlat() public {
    _seedBandedFeed();
    uint64 ts = _srcTs();
    // 500s WALL gap (within the 600s relay lag), 1s SOURCE gap. Block-time scaling would allow
    // 500·(1+500/3600) = 569 bps; source-time keeps the band flat at 500 → +5.5% is rejected.
    skip(500);
    bytes memory a = _rec(1, M.encodeB64(105_5e17, 18), 1e4, 5, ts + 1000); // +5.5% > flat 5%
    vm.expectRevert(
      abi.encodeWithSelector(Err.ThresholdViolation.selector, uint256(550), uint256(500))
    );
    ext.batchPushSigned(a, _sign(NXR_PK, a));
  }

  /// First signed push after addFeed (prevSourceTs == 0): the source delta is epoch-sized, so the
  /// band caps at MAX_DEV_THRESHOLD — same policy as a long-stale re-sync.
  function test_firstSignedPush_bandCapsAtMaxThreshold() public {
    address da = address(0xDA11);
    address db = address(0xDB11);
    ext.addFeed(da, db, M.encodeB64(100e18, 18), 1e4, 5, TAU, TAU, 500, 3600); // idx=1
    bytes32 id = keccak256(abi.encodePacked(da, db));
    skip(TAU);
    bytes memory blob = _rec(1, M.encodeB64(300e18, 18), 1e4, 5, _srcTs()); // +200% < 650% cap
    ext.batchPushSigned(blob, _sign(NXR_PK, blob));
    assertApproxEqRel(
      M.b64To1e18(ext.getFeed(id).lastPriceB64), 300e18, 0.001e18, "first push capped-band commit"
    );
  }

  // ─── malformed calldata ───

  function test_reject_badBlobLength() public {
    skip(TAU);
    bytes memory blob = hex"deadbeef"; // 4 B, not a multiple of 24
    vm.expectRevert(Err.InvalidInput.selector);
    ext.batchPushSigned(blob, _sign(NXR_PK, blob));
  }

  function test_reject_oobIndex() public {
    skip(TAU);
    bytes memory blob = _rec(99, M.encodeB64(3010e18, 18), 1e4, 5, _srcTs()); // idx 99 ≫ feedIds.length
    vm.expectRevert(); // feedIds[99] out of bounds
    ext.batchPushSigned(blob, _sign(NXR_PK, blob));
  }

  // ─── absolute freshness bound (fix #6) + sourceTs surfacing (fix #7) ───

  function test_reject_beyondRelayLag() public {
    ext = new ExternalOracle(address(ac), 60);
    ext.addFeed(
      BASE, QUOTE, M.encodeB64(3000e18, 18), 1e4, 5, TAU, TAU, ext.MAX_DEV_THRESHOLD(), 3600
    );
    ext.grantSigner(nxr);
    skip(TAU);
    // sourceTs 2 minutes behind wall clock (still monotonic > 0, but stale beyond the 60s bound)
    uint64 stale = uint64((block.timestamp - 120) * 1000);
    bytes memory blob = _rec(0, M.encodeB64(3005e18, 18), 1e4, 5, stale);
    vm.expectRevert(Err.FeedStale.selector);
    ext.batchPushSigned(blob, _sign(NXR_PK, blob));
  }

  function test_accept_withinRelayLag_surfacesSourceTs() public {
    skip(TAU);
    uint64 ts = uint64((block.timestamp - 5) * 1000); // 5s behind, within 600s bound
    bytes memory blob = _rec(0, M.encodeB64(3005e18, 18), 1e4, 5, ts);
    ext.batchPushSigned(blob, _sign(NXR_PK, blob));
    // fix #7: getFeed surfaces the signed source timestamp for downstream data-age reasoning.
    assertEq(uint256(ext.getFeed(feedId).sourceTs), ts, "sourceTs stored + surfaced");
  }

  function test_relayLag_isImmutable() public view {
    assertEq(ext.maxRelayLagSecs(), 600);
  }

  function test_constructor_zeroRelayLagRejected() public {
    vm.expectRevert(Err.InvalidInput.selector);
    new ExternalOracle(address(ac), 0);
  }

  function test_constructor_codelessAccessControlRejected() public {
    vm.expectRevert(Err.NotCode.selector);
    new ExternalOracle(address(0xAC), 60);
  }

  function test_constructor_relayLagAboveCeilingRejected() public {
    uint32 ceil = ext.MAX_RELAY_LAG_SECS();
    vm.expectRevert(Err.InvalidInput.selector);
    new ExternalOracle(address(ac), ceil + 1);
  }

  /// H-INT-01: Oracle.gate ages off authenticated sourceTs, not relay landing time.
  function test_gate_agesOffSourceTs_notLandingTime() public {
    skip(TAU);
    // Land a quote 100s behind wall clock (within 600s lag). updatedAt = now.
    uint64 ts = uint64((block.timestamp - 100) * 1000);
    bytes memory blob = _rec(0, M.encodeB64(3005e18, 18), 1e4, 5, ts);
    ext.batchPushSigned(blob, _sign(NXR_PK, blob));
    IOracle.FeedData memory f = ext.getFeed(feedId);
    assertEq(f.updatedAt, uint32(block.timestamp), "landing stamp");
    assertEq(uint256(f.sourceTs), ts, "auth source");

    // Warp so source age > ttl but landing age < ttl.
    skip(3550); // source age = 100+3550 = 3650 > 3600; landing age = 3550 < 3600
    f = ext.getFeed(feedId);
    assertTrue(block.timestamp - f.updatedAt <= f.ttl, "landing still within ttl");
    vm.expectRevert(); // StaleData via Oracle.gate / observedAt
    this.gate(feedId);
  }

  function gate(bytes32 id) external view returns (uint256) {
    return Oracle.gate(ext.getFeed(id));
  }

  // ─── config-bit preservation across the signed write (fix #8) ───

  function test_signed_preservesConfigBits() public {
    address ba = address(0xCAFE1);
    address qa = address(0xCAFE2);
    // distinct tauSigma / maxDeviation / ttl so a bit-mixing bug would surface (idx 1). tau param (111)
    // is vestigial now (struct field repurposed to flags) — addFeed stores flags:0 regardless.
    ext.addFeed(ba, qa, M.encodeB64(1000e18, 18), 1e4, 5, 111, 222, 333, 4444);
    bytes32 id = keccak256(abi.encodePacked(ba, qa));
    skip(TAU);
    uint64 ts = _srcTs();
    bytes memory blob = _rec(1, M.encodeB64(1005e18, 18), 7e4, 9, ts); // +50 bps < 333-bps band
    ext.batchPushSigned(blob, _sign(NXR_PK, blob));

    IOracle.FeedData memory f = ext.getFeed(id);
    assertEq(f.flags, 0, "flags preserved unpaused");
    assertEq(f.tauSigma, 222, "tauSigma preserved");
    assertEq(f.maxDeviation, 333, "maxDeviation preserved");
    assertEq(f.ttl, 4444, "ttl preserved");
    assertEq(f.confidence, 9, "confidence overwritten");
    assertEq(f.sigmaEma, 7e4, "sigma stored direct");
    assertEq(uint256(f.sourceTs), ts, "sourceTs written");
  }

  // ─── future-dated sourceTs bound (Ostium "future-dated report" / feed-freeze DoS) ───

  function test_reject_futureDatedSourceTs() public {
    skip(TAU);
    // sourceTs 10 min ahead of wall-clock ≫ 300s skew → an unbounded far-future ts would clear the
    // monotonic guard once, then permanently freeze the feed (no honest near-now push could exceed it).
    uint64 future = uint64((block.timestamp + 600) * 1000);
    bytes memory blob = _rec(0, M.encodeB64(3010e18, 18), 1e4, 5, future);
    vm.expectRevert(Err.InvalidInput.selector);
    ext.batchPushSigned(blob, _sign(NXR_PK, blob));
  }

  function test_accept_withinFutureSkew() public {
    skip(TAU);
    uint64 near = uint64((block.timestamp + 240) * 1000); // 4 min ahead, within the 300s skew
    bytes memory blob = _rec(0, M.encodeB64(3010e18, 18), 1e4, 5, near);
    ext.batchPushSigned(blob, _sign(NXR_PK, blob));
    assertEq(uint256(ext.getFeed(feedId).sourceTs), near, "within-skew future ts lands");
  }

  function test_futureSourceTs_cannotExtendTtlPastLandingTime() public {
    skip(TAU);
    uint64 future = uint64((block.timestamp + ext.SOURCE_TS_FUTURE_SKEW_S() - 1) * 1000);
    bytes memory blob = _rec(0, M.encodeB64(3005e18, 18), 1e4, 5, future);
    ext.batchPushSigned(blob, _sign(NXR_PK, blob));
    IOracle.FeedData memory f = ext.getFeed(feedId);
    uint32 landed = f.updatedAt;

    skip(uint256(f.ttl) + 1);
    assertEq(Oracle.observedAt(ext.getFeed(feedId)), landed, "future source capped once at landing");
    assertFalse(ext.isFeedFresh(feedId), "future skew must not extend ttl");
    vm.expectPartialRevert(Err.StaleData.selector);
    this.gate(feedId);
  }

  // ─── σ floor at mark-move magnitude (compromised-signer economic backstop) ───

  function test_signed_sigmaFlooredAtMarkMove() public {
    skip(TAU);
    // attested σ = 0, but the mark moves +2% (3000→3060). Floor = |Δmark|/mark = 20_000 PBPS, so a
    // signer signing σ=0 can NOT collapse the spread to the minFee floor.
    bytes memory blob = _rec(0, M.encodeB64(3060e18, 18), 0, 5, _srcTs());
    ext.batchPushSigned(blob, _sign(NXR_PK, blob));
    assertApproxEqRel(
      uint256(ext.getFeed(feedId).sigmaEma),
      20_000,
      0.001e18,
      "sigma floored to mark-move (2pct = 20k PBPS)"
    );
  }

  function test_signed_attestedSigmaKeptAboveFloor() public {
    skip(TAU);
    // attested σ = 50_000 PBPS ≫ the ~20_000 move floor → the attested σ is kept verbatim.
    bytes memory blob = _rec(0, M.encodeB64(3060e18, 18), 50_000, 5, _srcTs());
    ext.batchPushSigned(blob, _sign(NXR_PK, blob));
    assertEq(uint256(ext.getFeed(feedId).sigmaEma), 50_000, "attested sigma > floor kept verbatim");
  }

  // ─── multi-feed batch + gas ───

  function _addFeeds(uint256 n) internal returns (bytes32[] memory ids) {
    return _addFeedsFrom(n, 0);
  }

  function _addFeedsFrom(uint256 n, uint256 off) internal returns (bytes32[] memory ids) {
    ids = new bytes32[](n);
    for (uint256 i; i < n; ++i) {
      address b = address(uint160(0x10000 + off + i));
      address q = address(uint160(0x20000 + off + i));
      ext.addFeed(b, q, M.encodeB64(1000e18, 18), 1e4, 5, TAU, TAU, ext.MAX_DEV_THRESHOLD(), 3600);
      ids[i] = keccak256(abi.encodePacked(b, q));
    }
  }

  function test_batchPushSigned_multiFeed() public {
    uint256 n = 10;
    bytes32[] memory ids = _addFeeds(n); // idx 1..10 (idx 0 is the setUp feed)
    skip(TAU);
    uint64 ts = _srcTs();
    bytes memory blob;
    for (uint16 i; i < n; ++i) {
      blob = bytes.concat(blob, _rec(uint16(i + 1), M.encodeB64(1010e18, 18), 2e4, 6, ts));
    }
    ext.batchPushSigned(blob, _sign(NXR_PK, blob));
    for (uint256 i; i < n; ++i) {
      IOracle.FeedData memory f = ext.getFeed(ids[i]);
      assertApproxEqRel(M.b64To1e18(f.lastPriceB64), 1010e18, 0.001e18, "feed committed");
      assertEq(f.sigmaEma, 2e4, "direct sigma");
    }
  }

  /// Gas: signed path (packed, no event, direct σ) N=10, COLD slots (matches steady-state keeper cadence).
  /// Execution-only (forge gasleft() excludes the 21k base tx + L1 calldata). See ORACLE_SIGNED_PUSH_SPEC.md.
  function test_gas_signed_batch10() public {
    uint256 n = 10;
    _addFeedsFrom(n, 0); // idx 1..10, addr 0x10000.. (cold)
    skip(TAU);
    uint64 ts = _srcTs();
    bytes memory blob;
    for (uint16 i; i < n; ++i) {
      blob = bytes.concat(blob, _rec(uint16(i + 1), M.encodeB64(1010e18, 18), 2e4, 6, ts));
    }
    bytes memory sig = _sign(NXR_PK, blob);
    uint256 g = gasleft();
    ext.batchPushSigned(blob, sig);
    uint256 signed = g - gasleft();
    emit log_named_uint("signed batchPushSigned(10) exec gas", signed);
    emit log_named_uint("  signed per-feed", signed / n);
  }

  // ─── k-of-n multi-ECDSA (Ostium single-key hardening) ───

  uint256 constant NXR_PK2 = 0xB0B;
  uint256 constant NXR_PK3 = 0xCA401;

  /// @dev Concatenated 65-byte sigs sorted by recovered signer address ascending (the contract
  ///      enforces strictly-increasing recovered addresses as the distinctness check).
  function _multiSign(uint256[] memory pks, bytes memory blob)
    internal
    view
    returns (bytes memory sigs)
  {
    for (uint256 i; i < pks.length; ++i) {
      for (uint256 j = i + 1; j < pks.length; ++j) {
        if (vm.addr(pks[j]) < vm.addr(pks[i])) (pks[i], pks[j]) = (pks[j], pks[i]);
      }
    }
    for (uint256 i; i < pks.length; ++i) {
      sigs = bytes.concat(sigs, _sign(pks[i], blob));
    }
  }

  function _pks2() internal pure returns (uint256[] memory pks) {
    pks = new uint256[](2);
    pks[0] = NXR_PK;
    pks[1] = NXR_PK2;
  }

  /// @dev Grants signers 2+3 (3 total) and raises the threshold to 2 (the default 2-of-3 config).
  function _setup2of3() internal {
    ext.grantSigner(vm.addr(NXR_PK2));
    ext.grantSigner(vm.addr(NXR_PK3));
    ext.setSignerThreshold(2);
  }

  function test_kofn_belowThresholdRejected() public {
    _setup2of3();
    skip(TAU);
    bytes memory blob = _rec(0, M.encodeB64(3010e18, 18), 1e4, 5, _srcTs());
    vm.expectRevert(Err.InvalidInput.selector); // k=1 < threshold 2
    ext.batchPushSigned(blob, _sign(NXR_PK, blob));
  }

  function test_kofn_exactThresholdPasses() public {
    _setup2of3();
    skip(TAU);
    bytes memory blob = _rec(0, M.encodeB64(3010e18, 18), 1e4, 5, _srcTs());
    ext.batchPushSigned(blob, _multiSign(_pks2(), blob));
    assertApproxEqRel(
      M.b64To1e18(ext.getFeed(feedId).lastPriceB64), 3010e18, 0.001e18, "2-of-3 committed"
    );
  }

  function test_kofn_aboveThresholdPasses() public {
    _setup2of3();
    skip(TAU);
    bytes memory blob = _rec(0, M.encodeB64(3010e18, 18), 1e4, 5, _srcTs());
    uint256[] memory pks = new uint256[](3);
    pks[0] = NXR_PK;
    pks[1] = NXR_PK2;
    pks[2] = NXR_PK3;
    ext.batchPushSigned(blob, _multiSign(pks, blob));
    assertApproxEqRel(
      M.b64To1e18(ext.getFeed(feedId).lastPriceB64), 3010e18, 0.001e18, "3-of-3 committed"
    );
  }

  function test_kofn_duplicateSignerRejected() public {
    _setup2of3();
    skip(TAU);
    bytes memory blob = _rec(0, M.encodeB64(3010e18, 18), 1e4, 5, _srcTs());
    bytes memory one = _sign(NXR_PK, blob);
    vm.expectRevert(Err.NotAuth.selector); // same key twice: rec == prev fails strict ordering
    ext.batchPushSigned(blob, bytes.concat(one, one));
  }

  function test_kofn_unsortedSigsRejected() public {
    _setup2of3();
    skip(TAU);
    bytes memory blob = _rec(0, M.encodeB64(3010e18, 18), 1e4, 5, _srcTs());
    bytes memory sorted = _multiSign(_pks2(), blob);
    // Reverse the two 65-byte sigs → recovered addresses strictly DECREASE → reject.
    bytes memory swapped = new bytes(130);
    for (uint256 i; i < 65; ++i) {
      swapped[i] = sorted[65 + i];
      swapped[65 + i] = sorted[i];
    }
    vm.expectRevert(Err.NotAuth.selector);
    ext.batchPushSigned(blob, swapped);
  }

  function test_kofn_nonSignerSigRejected() public {
    _setup2of3();
    skip(TAU);
    bytes memory blob = _rec(0, M.encodeB64(3010e18, 18), 1e4, 5, _srcTs());
    uint256[] memory pks = new uint256[](2);
    pks[0] = NXR_PK;
    pks[1] = 0xBADBAD; // never granted
    vm.expectRevert(Err.NotAuth.selector);
    ext.batchPushSigned(blob, _multiSign(pks, blob));
  }

  function test_kofn_raggedSigsLengthRejected() public {
    _setup2of3();
    skip(TAU);
    bytes memory blob = _rec(0, M.encodeB64(3010e18, 18), 1e4, 5, _srcTs());
    bytes memory sigs = _multiSign(_pks2(), blob);
    // Truncate to 129 B: no longer a 65-byte multiple (EIP-2098 64-byte sigs are also out).
    bytes memory ragged = new bytes(129);
    for (uint256 i; i < 129; ++i) {
      ragged[i] = sigs[i];
    }
    vm.expectRevert(Err.InvalidInput.selector);
    ext.batchPushSigned(blob, ragged);
  }

  /// Revoking below the threshold HALTS pushing (fail-safe compromise response) — the remaining
  /// honest signer alone cannot clear k=2, and the revoked key is rejected outright.
  function test_kofn_revokeBelowThreshold_haltsPushing() public {
    _setup2of3();
    ext.revokeSigner(vm.addr(NXR_PK2));
    ext.revokeSigner(vm.addr(NXR_PK3));
    assertEq(ext.signerCount(), 1, "2 revoked");
    assertEq(ext.signerThreshold(), 2, "threshold survives revokes");
    skip(TAU);
    bytes memory blob = _rec(0, M.encodeB64(3010e18, 18), 1e4, 5, _srcTs());
    vm.expectRevert(Err.InvalidInput.selector); // k=1 < 2
    ext.batchPushSigned(blob, _sign(NXR_PK, blob));
    vm.expectRevert(Err.NotAuth.selector); // 2 sigs, but one signer is revoked
    ext.batchPushSigned(blob, _multiSign(_pks2(), blob));
  }

  function test_setSignerThreshold_bounds() public {
    assertEq(ext.signerCount(), 1, "setUp granted one signer");
    vm.expectRevert(Err.InvalidInput.selector); // t=0
    ext.setSignerThreshold(0);
    vm.expectRevert(Err.InvalidInput.selector); // t > signerCount
    ext.setSignerThreshold(2);
    ext.grantSigner(vm.addr(NXR_PK2));
    ext.setSignerThreshold(2);
    assertEq(ext.signerThreshold(), 2);
  }

  function test_setSignerThreshold_onlyAdmin() public {
    ext.grantSigner(vm.addr(NXR_PK2));
    vm.prank(address(0xDEAD));
    vm.expectRevert(Err.NotAuth.selector);
    ext.setSignerThreshold(2);
  }

  function test_signerCount_idempotentGrantRevoke() public {
    ext.grantSigner(nxr); // re-grant existing signer
    assertEq(ext.signerCount(), 1, "double grant does not double count");
    ext.revokeSigner(address(0xDEAD)); // revoke a never-granted address
    assertEq(ext.signerCount(), 1, "no-op revoke does not underflow");
    ext.revokeSigner(nxr);
    assertEq(ext.signerCount(), 0, "revoke decrements");
  }
}

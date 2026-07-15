// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {ExternalOracle} from "../../src/oracles/ExternalOracle.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
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
        ext = new ExternalOracle(address(ac));
        vm.warp(1_700_000_000);
        ext.addFeed(BASE, QUOTE, M.encodeB64(3000e18, 18), 1e4, 5, TAU, TAU, ext.MAX_DEV_THRESHOLD(), 3600);
        feedId = keccak256(abi.encodePacked(BASE, QUOTE)); // feedIds[0], idx = 0
        nxr = vm.addr(NXR_PK);
        ext.grantSigner(nxr);
    }

    // ─── helpers ───

    function _rec(uint16 idx, uint64 price, uint32 sigma, uint16 conf, uint64 sourceTs)
        internal pure returns (bytes memory)
    {
        return abi.encodePacked(idx, price, sigma, conf, sourceTs); // 2+8+4+2+8 = 24 B
    }

    function _domainSep() internal view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("BTR ExternalOracle")),
            keccak256(bytes("1")),
            block.chainid,
            address(ext)
        ));
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
        assertApproxEqRel(M.b64To1e18(ext.getFeed(feedId).lastPriceB64), 3010e18, 0.001e18, "any relay can land");
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

    // ─── deviation band (backstops a compromised NXR key) ───

    function test_reject_outOfBand() public {
        address da = address(0xDA5E);
        address db = address(0xDB5E);
        ext.addFeed(da, db, M.encodeB64(100e18, 18), 1e4, 5, TAU, TAU, 500, 3600); // 5% band, idx=1
        skip(10);
        bytes memory blob = _rec(1, M.encodeB64(110e18, 18), 1e4, 5, _srcTs()); // +10% ≫ 5%
        vm.expectRevert(abi.encodeWithSelector(Err.ThresholdViolation.selector, uint256(1000), uint256(501)));
        ext.batchPushSigned(blob, _sign(NXR_PK, blob));
    }

    /// H-2: the band grows LINEARLY with staleness — maxDev·(1+dt/ttl) — so a legit post-gap re-sync
    /// passes but an arbitrary jump bought by inducing staleness stays bounded. At dt=ttl the band doubles.
    function test_deviationBand_scalesWithStaleness() public {
        address da = address(0xDA5E);
        address db = address(0xDB5E);
        ext.addFeed(da, db, M.encodeB64(100e18, 18), 1e4, 5, TAU, TAU, 500, 3600); // 5% band, ttl 3600, idx=1
        bytes32 id = keccak256(abi.encodePacked(da, db));
        skip(3600); // dt = ttl → band = 500·(1+1) = 1000 bps (10%)
        // A +200% jump is REJECTED even fully stale (was allowed under the old dt>=ttl exemption).
        bytes memory j = _rec(1, M.encodeB64(300e18, 18), 1e4, 5, _srcTs());
        vm.expectRevert(abi.encodeWithSelector(Err.ThresholdViolation.selector, uint256(20000), uint256(1000)));
        ext.batchPushSigned(j, _sign(NXR_PK, j));
        // A move within the doubled band commits (legit post-downtime drift).
        bytes memory ok = _rec(1, M.encodeB64(108e18, 18), 1e4, 5, _srcTs()); // +8% < 10%
        ext.batchPushSigned(ok, _sign(NXR_PK, ok));
        assertApproxEqRel(M.b64To1e18(ext.getFeed(id).lastPriceB64), 108e18, 0.001e18, "in-band re-sync committed");
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
        ext.setMaxRelayLag(60); // 60s absolute bound
        skip(TAU);
        // sourceTs 2 minutes behind wall clock (still monotonic > 0, but stale beyond the 60s bound)
        uint64 stale = uint64((block.timestamp - 120) * 1000);
        bytes memory blob = _rec(0, M.encodeB64(3005e18, 18), 1e4, 5, stale);
        vm.expectRevert(Err.FeedStale.selector);
        ext.batchPushSigned(blob, _sign(NXR_PK, blob));
    }

    function test_accept_withinRelayLag_surfacesSourceTs() public {
        ext.setMaxRelayLag(600);
        skip(TAU);
        uint64 ts = uint64((block.timestamp - 5) * 1000); // 5s behind, within 600s bound
        bytes memory blob = _rec(0, M.encodeB64(3005e18, 18), 1e4, 5, ts);
        ext.batchPushSigned(blob, _sign(NXR_PK, blob));
        // fix #7: getFeed surfaces the signed source timestamp for downstream data-age reasoning.
        assertEq(uint256(ext.getFeed(feedId).sourceTs), ts, "sourceTs stored + surfaced");
    }

    function test_relayLag_disabledByDefault() public view {
        assertEq(ext.maxRelayLagSecs(), 0, "0 = disabled at bring-up");
    }

    // ─── config-bit preservation across the signed write (fix #8) ───

    function test_signed_preservesConfigBits() public {
        address ba = address(0xCAFE1);
        address qa = address(0xCAFE2);
        // distinct tau / tauSigma / maxDeviation / ttl so a bit-mixing bug would surface (idx 1).
        ext.addFeed(ba, qa, M.encodeB64(1000e18, 18), 1e4, 5, 111, 222, 333, 4444);
        bytes32 id = keccak256(abi.encodePacked(ba, qa));
        skip(TAU);
        uint64 ts = _srcTs();
        bytes memory blob = _rec(1, M.encodeB64(1005e18, 18), 7e4, 9, ts); // +50 bps < 333-bps band
        ext.batchPushSigned(blob, _sign(NXR_PK, blob));

        IOracle.FeedData memory f = ext.getFeed(id);
        assertEq(f.tau, 111, "tau preserved");
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

    // ─── σ floor at mark-move magnitude (compromised-signer economic backstop) ───

    function test_signed_sigmaFlooredAtMarkMove() public {
        skip(TAU);
        // attested σ = 0, but the mark moves +2% (3000→3060). Floor = |Δmark|/mark = 20_000 PBPS, so a
        // signer signing σ=0 can NOT collapse the spread to the minFee floor.
        bytes memory blob = _rec(0, M.encodeB64(3060e18, 18), 0, 5, _srcTs());
        ext.batchPushSigned(blob, _sign(NXR_PK, blob));
        assertApproxEqRel(uint256(ext.getFeed(feedId).sigmaEma), 20_000, 0.001e18, "sigma floored to mark-move (2pct = 20k PBPS)");
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
}

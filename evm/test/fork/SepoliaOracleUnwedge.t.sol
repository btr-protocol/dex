// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {ExternalOracle} from "../../src/oracles/ExternalOracle.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";

/// @notice LIVE-STATE proof of the Sepolia oracle deadlock and of its no-redeploy recovery, run
///         against the DEPLOYED bytecode (not the local fixed source) so it measures what is
///         actually on chain today.
/// @dev Evidence this reproduces: relay tx 0xd30b0f29…55e772 @ block 11374401 reverts
///      `ThresholdViolation(119, 100)` — 100 being the BARE `maxDeviation` floor of reference feed
///      idx 3, i.e. the volatility-adaptive term contributed ZERO. Not a ms/s unit bug: the feed has
///      never taken a signed push, so its STORED σ is 0 and `_checkDeviation` skips the σ√dt branch.
/// @dev Forks at LATEST (the public Sepolia endpoint is not an archive node, so a pinned historical
///      block 403s). Skipped, not failed, when the fork cannot be created:
///      `forge test --match-path 'test/fork/*'` to run deliberately.
contract SepoliaOracleUnwedgeTest is Test {
  string constant RPC = "https://ethereum-sepolia-rpc.publicnode.com";
  address constant REF_ORACLE = 0x16d3CD9De87F43144BD73E374c5ABd70ad93AB26;
  address constant PRIMARY_ORACLE = 0x01a52C049896E36c00bd5FD3db788e4d11B216c5;
  address constant OWNER = 0x57b3771F6b772C52E81646Aa007D1Ab28d91B3Fe;
  address constant RELAYER = 0x343D26CcfA5fee26eDda197c6DFE7786D1DEfF3A;

  bytes32 constant BATCH_TYPEHASH = keccak256("BatchQuote(bytes32 blobHash)");
  uint256 constant TEST_PK_A = 0xA11CE;
  uint256 constant TEST_PK_B = 0xB0B;
  /// @dev `signers` mapping lives at storage slot 2 (forge inspect storage).
  uint256 constant SIGNERS_SLOT = 2;
  /// @dev The wedged reference feed the historical relay tripped on (feedIds idx 3).
  uint16 constant WEDGED_IDX = 3;

  ExternalOracle ref = ExternalOracle(REF_ORACLE);

  function _fork() internal returns (bool) {
    try vm.createSelectFork(RPC) { return true; }
    catch {
      return false;
    }
  }

  // ── 1. root cause on live state ──

  /// The wedged feeds have σ == 0 AND sourceTs == 0: seeded by `addFeed(…, sigmaSample = 0, …)` and
  /// never pushed since. The band is `maxDeviation + Z·σ·√(dt/interval)`, so with a zero STORED σ
  /// the band is the bare floor forever — and σ only rises on a SUCCESSFUL push. Chicken-and-egg.
  function test_rootCause_storedSigmaIsZero_soBandIsBareFloor() public {
    if (!_fork()) return;
    IOracle.FeedData memory f = ref.getFeed(ref.getFeedIds()[WEDGED_IDX]);
    assertEq(f.sigma, 0, "stored sigma zero -> sigma-staleness premium is structurally zero");
    assertEq(f.sourceTs, 0, "never took a signed push -> dtSource is zero too");
    assertEq(f.maxDeviation, 100, "band == bare maxDeviation floor");
    assertGt(block.timestamp - f.updatedAt, 1 days, "and the mark is days stale");
  }

  /// A freshly signed push of the SAME +119 bps move the historical relay carried still reverts with
  /// the identical numbers. Reproduces the deadlock on current state, isolated from freshness.
  function test_liveDeadlock_119bpsPushRevertsAtTheBareFloor() public {
    if (!_fork()) return;
    _installTestSigners();
    bytes32 id = ref.getFeedIds()[WEDGED_IDX];
    uint256 prev = M.b64To1e18(ref.getFeed(id).lastPriceB64);

    vm.expectRevert(abi.encodeWithSelector(Err.ThresholdViolation.selector, uint256(119), uint256(100)));
    vm.prank(RELAYER);
    ref.batchPushSigned(_blob(_bps(prev, 119)), _sign2(_blob(_bps(prev, 119))));
  }

  /// Blast radius, measured. The reference oracle is fully wedged; the PRIMARY carries the identical
  /// defect on the feeds that have never been pushed — healthy today only because those marks have
  /// not yet drifted past their 50 bps floor.
  function test_wedgedFeedInventory() public {
    if (!_fork()) return;
    assertEq(_sigmaZeroCount(ref), 13, "13 of 14 reference feeds carry no adaptive band");
    assertEq(
      _sigmaZeroCount(ExternalOracle(PRIMARY_ORACLE)), 2, "primary: 2 feeds one drift away from it"
    );
  }

  // ── 2. recovery WITHOUT redeploy ──

  /// ⚠ The DEPLOYED bytecode predates the tighten-only asymmetry fix: it carries no
  /// `requestFeedWiden`/`executeFeedWiden`/`pendingWiden` at all. Recovery therefore needs NO
  /// timelock whatsoever — `updateFeed` widens instantly. Verified by selector, not by assumption.
  function test_deployedBuild_hasNoTimelockedWidenPath() public {
    if (!_fork()) return;
    (bool ok,) = REF_ORACLE.staticcall(
      abi.encodeWithSignature("pendingWiden(bytes32)", bytes32(0))
    );
    assertFalse(ok, "deployed build has no pendingWiden: widen is instant via updateFeed");
    assertEq(SC.govDelay(SC.BASE_TIMELOCK), 15 minutes, "and even the new build is 15m on Sepolia");
  }

  /// End-to-end against deployed bytecode, exactly the OracleUnwedge runbook: widen the wedged feed
  /// to the ceiling it would ALREADY grant itself once σ is populated (10x floor = the
  /// DEV_BAND_MAX_X cap), land the move the bare floor rejected, then restore the floor. No
  /// timelock, no redeploy, no pool re-pin.
  function test_widenThenPushThenRetighten_restoresTheFeed() public {
    if (!_fork()) return;
    bytes32 id = ref.getFeedIds()[WEDGED_IDX];
    uint16 floorBefore = ref.getFeed(id).maxDeviation;
    uint16 ttl = ref.getFeed(id).ttl;

    vm.prank(OWNER);
    ref.updateFeed(id, floorBefore * 10, ttl);
    assertEq(ref.getFeed(id).maxDeviation, floorBefore * 10, "widened instantly, same tx");

    // Signers are cheated in rather than granted (a real grant is a timelock) — this isolates the
    // BAND, which is what is under test. Auth is covered by test/unit/ExternalOracleSigned.t.sol.
    _installTestSigners();
    uint256 target = _bps(M.b64To1e18(ref.getFeed(id).lastPriceB64), 119);
    vm.prank(RELAYER);
    ref.batchPushSigned(_blob(target), _sign2(_blob(target)));

    IOracle.FeedData memory f = ref.getFeed(id);
    assertApproxEqRel(M.b64To1e18(f.lastPriceB64), target, 0.0002e18, "119 bps move landed");
    assertGt(f.sigma, 0, "sigma populated: the feed is self-healing from here");
    assertGt(f.sourceTs, 0, "sourceTs set: later bands scale with real source-time staleness");

    vm.prank(OWNER);
    ref.updateFeed(id, floorBefore, ttl);
    assertEq(ref.getFeed(id).maxDeviation, floorBefore, "floor restored, still no timelock");
  }

  /// After that first push the feed no longer needs ANY widening: the adaptive band alone now
  /// absorbs a far larger move. This is the property the σ seed was supposed to provide from birth.
  function test_afterFirstPush_theAdaptiveBandCarriesTheFeed() public {
    if (!_fork()) return;
    bytes32 id = ref.getFeedIds()[WEDGED_IDX];
    uint16 floorBefore = ref.getFeed(id).maxDeviation;
    uint16 ttl = ref.getFeed(id).ttl;
    _installTestSigners();

    vm.prank(OWNER);
    ref.updateFeed(id, floorBefore * 10, ttl);
    uint256 mark = _bps(M.b64To1e18(ref.getFeed(id).lastPriceB64), 119);
    vm.prank(RELAYER);
    ref.batchPushSigned(_blob(mark), _sign2(_blob(mark)));
    vm.prank(OWNER);
    ref.updateFeed(id, floorBefore, ttl); // back to the tight 100 bps floor

    // An hour later, at the ORIGINAL floor, a 119 bps move now lands on the sigma premium alone.
    skip(1 hours);
    mark = _bps(M.b64To1e18(ref.getFeed(id).lastPriceB64), 119);
    vm.prank(RELAYER);
    ref.batchPushSigned(_blob(mark), _sign2(_blob(mark)));
    assertApproxEqRel(
      M.b64To1e18(ref.getFeed(id).lastPriceB64), mark, 0.0002e18, "adaptive band absorbed it"
    );
    assertEq(ref.getFeed(id).maxDeviation, floorBefore, "at the tight floor, unaided");
  }

  /// The recovery needs the AC owner and nothing else — no redeploy, no pool re-pin, no guardian.
  function test_widenIsOwnerOnly() public {
    if (!_fork()) return;
    bytes32 id = ref.getFeedIds()[WEDGED_IDX];
    vm.prank(RELAYER);
    vm.expectRevert();
    ref.updateFeed(id, 1000, 600);
  }

  // ── helpers ──

  function _bps(uint256 x, uint256 bps) internal pure returns (uint256) {
    return x * (10_000 + bps) / 10_000;
  }

  function _blob(uint256 mark1e18) internal view returns (bytes memory) {
    return abi.encodePacked(
      WEDGED_IDX, M.encodeB64(mark1e18, 18), uint32(0), uint16(5), uint64(block.timestamp) * 1000
    );
  }

  function _sigmaZeroCount(ExternalOracle o) internal view returns (uint256 n) {
    bytes32[] memory ids = o.getFeedIds();
    for (uint256 i; i < ids.length; ++i) {
      if (o.getFeed(ids[i]).sigma == 0) ++n;
    }
  }

  function _installTestSigners() internal {
    vm.store(REF_ORACLE, keccak256(abi.encode(vm.addr(TEST_PK_A), SIGNERS_SLOT)), bytes32(uint256(1)));
    vm.store(REF_ORACLE, keccak256(abi.encode(vm.addr(TEST_PK_B), SIGNERS_SLOT)), bytes32(uint256(1)));
  }

  function _sign2(bytes memory blob) internal view returns (bytes memory) {
    bytes32 domainSep = keccak256(
      abi.encode(
        keccak256(
          "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        ),
        keccak256(bytes("BTR ExternalOracle")),
        keccak256(bytes("1")),
        block.chainid,
        REF_ORACLE
      )
    );
    bytes32 digest = keccak256(
      abi.encodePacked("\x19\x01", domainSep, keccak256(abi.encode(BATCH_TYPEHASH, keccak256(blob))))
    );
    // Sigs must be sorted by RECOVERED signer address (strictly increasing).
    (uint256 lo, uint256 hi) =
      vm.addr(TEST_PK_A) < vm.addr(TEST_PK_B) ? (TEST_PK_A, TEST_PK_B) : (TEST_PK_B, TEST_PK_A);
    (uint8 v0, bytes32 r0, bytes32 s0) = vm.sign(lo, digest);
    (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(hi, digest);
    return abi.encodePacked(r0, s0, v0, r1, s1, v1);
  }
}

// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {ChainlinkOracle, IAggregatorV3} from "../../src/oracles/ChainlinkOracle.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {Err} from "@btr-shared/Errors.sol";
import {MockAC} from "../fixtures/BaseTestSetup.sol";

/// @dev Configurable Chainlink AggregatorV3 mock.
contract MockAgg is IAggregatorV3 {
  uint8 public decimals;
  int256 answer;
  uint256 updatedAt;
  uint80 roundId;
  uint80 answeredInRound;

  constructor(uint8 d) {
    decimals = d;
  }

  function set(int256 a, uint256 t, uint80 r, uint80 air) external {
    answer = a;
    updatedAt = t;
    roundId = r;
    answeredInRound = air;
  }

  function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
    return (roundId, answer, 0, updatedAt, answeredInRound);
  }
}

contract ChainlinkOracleTest is Test {
  ChainlinkOracle oracle;
  MockAC ac;
  MockAgg agg; // 8-decimal USD feed (Chainlink convention)
  address constant BTC = address(0xB7C);
  address constant USD = address(0x05D);
  bytes32 feedId;

  function setUp() public {
    ac = new MockAC(address(this));
    oracle = new ChainlinkOracle(address(ac));
    agg = new MockAgg(8);
    vm.warp(1_700_000_000);
    feedId = oracle.addFeed(BTC, USD, address(agg), 3600);
    // BTC at $64,300.00 (8 decimals), fresh, complete round.
    agg.set(64_300e8, block.timestamp, 1, 1);
  }

  function test_getFeed_scalesTo1e18() public view {
    IOracle.FeedData memory f = oracle.getFeed(feedId);
    assertApproxEqRel(
      M.b64To1e18(f.lastPriceB64), 64_300e18, 0.0001e18, "8-dec answer -> 1e18 mark"
    );
    assertEq(f.updatedAt, uint32(block.timestamp), "updatedAt from the chainlink round");
    assertEq(f.ttl, 3600, "ttl preserved");
    assertEq(f.confidence, 0, "no CI");
    assertEq(f.flags, 0, "unpaused");
  }

  function test_feedId_matchesKeccak() public view {
    assertEq(feedId, keccak256(abi.encodePacked(BTC, USD)));
  }

  function test_getFeed_revertsOnNonPositiveAnswer() public {
    agg.set(0, block.timestamp, 2, 2);
    vm.expectPartialRevert(Err.StaleData.selector);
    oracle.getFeed(feedId);
    agg.set(-1, block.timestamp, 3, 3);
    vm.expectPartialRevert(Err.StaleData.selector);
    oracle.getFeed(feedId);
  }

  function test_getFeed_revertsOnIncompleteRound() public {
    // answeredInRound < roundId => carried-over stale answer.
    agg.set(64_300e8, block.timestamp, 5, 4);
    vm.expectPartialRevert(Err.StaleData.selector);
    oracle.getFeed(feedId);
  }

  function test_getFeed_revertsOnUnknownFeed() public {
    vm.expectRevert(abi.encodeWithSelector(Err.FeedNotFound.selector, bytes32(uint256(1))));
    oracle.getFeed(bytes32(uint256(1)));
  }

  function test_isFeedFresh() public {
    assertTrue(oracle.isFeedFresh(feedId), "fresh round within ttl");
    skip(3601); // round now older than ttl
    assertFalse(oracle.isFeedFresh(feedId), "stale past ttl");
    assertTrue(oracle.isFeedFresh(feedId, 7200), "fresh within a larger maxAge");
  }

  function test_addFeed_rejectsOver18Decimals() public {
    MockAgg bad = new MockAgg(19);
    vm.expectRevert(Err.InvalidInput.selector);
    oracle.addFeed(address(0x1), address(0x2), address(bad), 3600);
  }

  function test_addFeed_onlyAdmin() public {
    vm.prank(address(0xBEEF));
    vm.expectRevert(Err.NotOwner.selector);
    oracle.addFeed(address(0x1), address(0x2), address(agg), 3600);
  }

  function test_ctor_rejectsZeroAC() public {
    vm.expectRevert(Err.ZeroValue.selector);
    new ChainlinkOracle(address(0));
  }

  function test_ctor_rejectsCodelessAC() public {
    vm.expectRevert(Err.NotCode.selector);
    new ChainlinkOracle(address(0xDEAD));
  }
}

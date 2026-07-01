// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {ExternalOracle} from "../../src/oracles/ExternalOracle.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {Oracle} from "../../src/libraries/Oracle.sol";
import {Maths as M} from "../../src/libraries/Maths.sol";
import {MockAC} from "../fixtures/BaseTestSetup.sol";

/// @title ExternalOracleTest
/// @notice Verifies the slowOffset encoding round-trips through the canonical reader. Pre-fix,
///         _pushInternal stored a raw int16 B64-value delta that Oracle._applyOffset (int32,
///         ORACLE_PBPS) decoded as garbage, making priceSlow / divergence unusable — which
///         disabled the external deviation-collar escape hatch.
contract ExternalOracleTest is Test {
    ExternalOracle ext;
    MockAC ac;
    address constant BASE  = address(0xB05E);
    address constant QUOTE = address(0x9907E);
    bytes32 feedId;

    function setUp() public {
        ac = new MockAC(address(this));                       // owner = this
        ext = new ExternalOracle(address(ac), address(this)); // this = granted oracle
        ext.addFeed(BASE, QUOTE, M.encodeB64(3000e18, 18), M.encodeB64(3000e18, 18), 1e4, 1e4, 0, 3600);
        feedId = keccak256(abi.encodePacked(BASE, QUOTE));
    }

    function test_slow_offset_roundtrip_positive() public {
        // slow 1% ABOVE fast
        ext.pushFeed(feedId, M.encodeB64(3000e18, 18), M.encodeB64(3030e18, 18), 1e4, 1e4);
        IOracle.FeedData memory f = ext.getFeed(feedId);
        (uint256 priceFast, uint256 priceSlow) = Oracle.decodeB64s(f);
        assertApproxEqRel(priceFast, 3000e18, 0.002e18, "fast");
        assertApproxEqRel(priceSlow, 3030e18, 0.01e18, "slow decoded wrong (encoding bug)");
    }

    function test_slow_offset_roundtrip_negative() public {
        // slow 2% BELOW fast
        ext.pushFeed(feedId, M.encodeB64(3000e18, 18), M.encodeB64(2940e18, 18), 1e4, 1e4);
        IOracle.FeedData memory f = ext.getFeed(feedId);
        (, uint256 priceSlow) = Oracle.decodeB64s(f);
        assertApproxEqRel(priceSlow, 2940e18, 0.01e18, "slow (negative offset) decoded wrong");
    }
}

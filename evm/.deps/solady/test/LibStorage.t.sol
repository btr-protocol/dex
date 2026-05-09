// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {LibStorage as S} from "../src/utils/S.sol";

contract LibStorageTest is SoladyTest {
    using LibStorage for *;

    uint256 private constant _BUMPED_STORAGE_REF_SLOT_SEED = 0xd4203f8b;

    function testBumpSlot(bytes32 s, uint256 c) public {
        c = c & 0xffffffffffffffffff;
        S.Bump storage bump = S.bump(s);
        bump._current = c;
        assertEq(
            bump.slot(),
            keccak256(abi.encodePacked(s, uint32(_BUMPED_STORAGE_REF_SLOT_SEED), uint216(c)))
        );
        bump.invalidate();
        assertEq(
            bump.slot(),
            keccak256(abi.encodePacked(s, uint32(_BUMPED_STORAGE_REF_SLOT_SEED), uint216(c + 1)))
        );
    }
}

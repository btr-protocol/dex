// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {Admin} from "../src/Admin.sol";
import {Flash} from "../src/Flash.sol";
import {VenusHook} from "../src/hooks/VenusHook.sol";
import {MockVenus} from "../src/hooks/MockVenus.sol";

/// @notice EIP-170 runtime bytecode cap (24 576 bytes).
contract ContractSizeTest is Test {
    uint256 internal constant EIP170_MAX = 24_576;

    function test_runtime_under_eip170() public {
        assertLe(address(new Pool(address(1), address(2), address(3), address(4))).code.length, EIP170_MAX, "Pool");
        assertLe(address(new PoolAux(address(1), address(2), address(3))).code.length, EIP170_MAX, "PoolAux");
        assertLe(address(new Admin(address(1))).code.length, EIP170_MAX, "Admin");
        assertLe(address(new Flash()).code.length, EIP170_MAX, "Flash");

        MockERC20 tok = new MockERC20("T", "T", 18);
        MockVenus v = new MockVenus(address(tok));
        assertLe(
            address(new VenusHook(address(1), address(2), address(tok), address(v))).code.length,
            EIP170_MAX,
            "VenusHook"
        );
    }
}

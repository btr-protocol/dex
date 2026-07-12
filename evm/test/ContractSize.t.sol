// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {Admin} from "../src/Admin.sol";
import {Flash} from "../src/Flash.sol";
import {VenusHook} from "../src/hooks/VenusHook.sol";
import {CompoundV2YieldHook} from "../src/hooks/CompoundV2YieldHook.sol";
import {AaveV3YieldHook} from "../src/hooks/AaveV3YieldHook.sol";
import {ERC4626YieldHook} from "../src/hooks/ERC4626YieldHook.sol";
import {MorphoBlueYieldHook} from "../src/hooks/MorphoBlueYieldHook.sol";
import {AaveV4YieldHook} from "../src/hooks/AaveV4YieldHook.sol";
import {MockVenus} from "../src/hooks/MockVenus.sol";
import {MockAavePool, MockAToken} from "../src/hooks/MockAavePool.sol";
import {MockERC4626} from "../src/hooks/MockERC4626.sol";
import {MockMorphoBlue} from "../src/hooks/MockMorphoBlue.sol";
import {MockAaveV4Spoke} from "../src/hooks/MockAaveV4Spoke.sol";
import {IMorphoBlue} from "../src/interfaces/external/IMorphoBlue.sol";

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
        assertLe(
            address(new CompoundV2YieldHook(address(1), address(2), address(tok), address(v))).code.length,
            EIP170_MAX,
            "CompoundV2YieldHook"
        );

        MockAavePool aave = new MockAavePool();
        MockAToken aTok = new MockAToken(address(tok));
        aave.setAToken(address(tok), address(aTok));
        assertLe(
            address(new AaveV3YieldHook(address(1), address(2), address(tok), address(aave), address(0))).code.length,
            EIP170_MAX,
            "AaveV3YieldHook"
        );

        MockERC4626 vault = new MockERC4626(address(tok));
        assertLe(
            address(new ERC4626YieldHook(address(1), address(2), address(tok), address(vault))).code.length,
            EIP170_MAX,
            "ERC4626YieldHook"
        );

        MockMorphoBlue morpho = new MockMorphoBlue();
        IMorphoBlue.MarketParams memory mp = IMorphoBlue.MarketParams({
            loanToken: address(tok),
            collateralToken: address(3),
            oracle: address(4),
            irm: address(5),
            lltv: 0.8e18
        });
        morpho.setMarket(mp);
        assertLe(
            address(new MorphoBlueYieldHook(address(1), address(2), address(tok), address(morpho), mp)).code.length,
            EIP170_MAX,
            "MorphoBlueYieldHook"
        );

        MockAaveV4Spoke spoke = new MockAaveV4Spoke();
        spoke.setReserve(1, address(tok));
        assertLe(
            address(new AaveV4YieldHook(address(1), address(2), address(tok), address(spoke), 1, address(0))).code
                .length,
            EIP170_MAX,
            "AaveV4YieldHook"
        );
    }
}

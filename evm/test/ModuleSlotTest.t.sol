// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test, console2} from "forge-std/Test.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {PoolProxy} from "../src/PoolProxy.sol";
import {Pool} from "../src/modules/Pool.sol";
import {Admin} from "../src/modules/Admin.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {Maths} from "../src/libraries/Maths.sol";

contract ModuleSlotTest is Test {
    PoolProxy pool;
    Pool poolModule;
    Admin adminModule;

    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    function setUp() public {
        poolModule = new Pool();
        adminModule = new Admin();
        pool = new PoolProxy();

        uint8[29] memory feePad;
        IPool.FeeParams memory feeParams = IPool.FeeParams({
            protoShare: 25,
            flashFeeBps: 5,
            _pad: feePad
        });
        pool.initialize(address(this), USDC, WBNB, feeParams);
    }

    function test_moduleSlotCalculation() public {
        bytes4 selector = Admin.requestAddAsset.selector;
        console2.log("Selector:", vm.toString(selector));
        console2.log("Selector as uint32:", uint32(selector));

        // Calculate slot the same way as deployment script
        bytes32 modulesSlot = bytes32(uint256(C.CORE_STORAGE_LOC) + 14);
        console2.log("Modules slot:", vm.toString(modulesSlot));

        bytes32 slot = keccak256(abi.encode(selector, modulesSlot));
        console2.log("Computed storage slot:", vm.toString(slot));

        // Store module address
        vm.store(address(pool), slot, bytes32(uint256(uint160(address(adminModule)))));

        // Read it back via sload
        bytes32 stored = vm.load(address(pool), slot);
        console2.log("Stored value:", vm.toString(stored));
        console2.log("Admin module:", address(adminModule));

        // Try calling the function
        // If slot is wrong, this will revert with InvalidInput
        // If slot is right, it might revert with something else (missing oracle, etc)
        vm.expectRevert();
        IPool(address(pool)).requestAddAsset(
            USDC,
            IPool.OracleConfig(address(pool), address(0), bytes32(0), 0, 6, [uint8(0),0,0,0,0,0,0,0,0,0,0,0,0]),
            IPool.RiskConfig(9800, 5000, 20000, 31709791, 20000, 3, [uint8(0),0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]),
            concentratedProfile(),
            5,
            18,
            1e18,
            10000,
            10000
        );
    }

    function test_verifyGetModule() public {
        bytes4 selector = Admin.getModule.selector;
        console2.log("getModule selector:", vm.toString(selector));

        // Try offset 13 (treasury+initialized pack together)
        bytes32 modulesSlot = bytes32(uint256(C.CORE_STORAGE_LOC) + 13);
        console2.log("Trying modules slot (offset 13):", vm.toString(modulesSlot));

        bytes32 slot = keccak256(abi.encode(selector, modulesSlot));
        console2.log("Storage slot for getModule:", vm.toString(slot));
        vm.store(address(pool), slot, bytes32(uint256(uint160(address(adminModule)))));

        // Also register requestAddAsset
        bytes4 reqSelector = Admin.requestAddAsset.selector;
        bytes32 reqSlot = keccak256(abi.encode(reqSelector, modulesSlot));
        vm.store(address(pool), reqSlot, bytes32(uint256(uint160(address(adminModule)))));

        // Now try getModule - this should work if slot calculation is correct
        address module = IPool(address(pool)).getModule(reqSelector);
        console2.log("getModule result:", module);
        assertEq(module, address(adminModule), "Module not found at expected slot");
    }

    function concentratedProfile() internal pure returns (IPool.LiquidityProfile memory profile) {
        profile.weights[0] = 10;
        profile.weights[1] = 180;
        profile.weights[2] = 10;
        profile.knots[0] = -50;
        profile.knots[1] = -5;
        profile.knots[2] = 5;
        profile.knots[3] = 50;
    }

    function test_priceEncoding() public pure {
        // Test price encoding for WETH at $3500 with 18 decimals
        uint64 wethPrice = Maths.encodeB64(3500 * 1e18, 18);
        console2.log("WETH price B64:", wethPrice);

        // Decode back to verify
        uint256 decoded = Maths.decodeB64(wethPrice, 18);
        console2.log("WETH price decoded:", decoded);
        console2.log("Expected:", uint256(3500 * 1e18));

        // Check BTC price too
        uint64 btcPrice = Maths.encodeB64(95000 * 1e18, 18);
        uint256 btcDecoded = Maths.decodeB64(btcPrice, 18);
        console2.log("BTC price decoded:", btcDecoded);

        // Check stablecoin $1
        uint64 usdcPrice = Maths.encodeB64(1e18, 18);
        uint256 usdcDecoded = Maths.decodeB64(usdcPrice, 18);
        console2.log("USDC price decoded:", usdcDecoded);
    }
}

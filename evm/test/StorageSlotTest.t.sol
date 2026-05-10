// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test, console2} from "forge-std/Test.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {ICore} from "../src/interfaces/modules/ICore.sol";
import {IPoolModule} from "../src/interfaces/modules/IPool.sol";
import {IAdmin, IAdminConfig, IAdminTimelock} from "../src/interfaces/modules/IAdmin.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {PoolProxy} from "../src/PoolProxy.sol";
import {Admin} from "../src/modules/Admin.sol";

/// @title StorageSlotTest
/// @notice Test to verify storage slot layout for PoolStorage struct
contract StorageSlotTest is Test {

    function test_find_modules_slot() public pure {
        // Print the base slot
        console2.log("Base slot (CORE_STORAGE_LOC):");
        console2.logBytes32(C.CORE_STORAGE_LOC);

        // PoolStorage struct fields and their slot offsets:
        // address owner;           // slot 0
        // address baseToken;       // slot 1
        // address wnative;         // slot 2
        // address bridge;          // slot 3
        // address treasury;        // slot 4
        // bool initialized;        // slot 5 (bool takes full slot when alone)
        // mapping assets           // slot 6
        // mapping oracleConfigs    // slot 7
        // mapping riskConfigs      // slot 8
        // mapping profiles         // slot 9
        // mapping hooks            // slot 10
        // mapping hookFlags        // slot 11
        // mapping lpBalances       // slot 12
        // mapping protocolFees     // slot 13
        // mapping modules          // slot 14

        uint256 baseSlot = uint256(C.CORE_STORAGE_LOC);

        console2.log("Modules mapping at slot offset 14:");
        console2.log("Slot:", baseSlot + 14);
        console2.logBytes32(bytes32(baseSlot + 14));
    }

    function test_vm_store_and_load() public {
        // Deploy a simple proxy-like contract
        DummyProxy proxy = new DummyProxy();

        uint256 baseSlot = uint256(C.CORE_STORAGE_LOC);
        uint256 modulesSlot = baseSlot + 14;

        bytes4 testSelector = bytes4(0x12345678);
        address testModule = address(0xBEEF);

        // Compute the slot
        bytes32 slot = keccak256(abi.encode(testSelector, modulesSlot));
        console2.log("Writing to slot:");
        console2.logBytes32(slot);

        // Write to storage
        vm.store(address(proxy), slot, bytes32(uint256(uint160(testModule))));

        // Read back
        bytes32 stored = vm.load(address(proxy), slot);
        console2.log("Read back:");
        console2.logBytes32(stored);

        address storedAddr = address(uint160(uint256(stored)));
        console2.log("Stored address:", storedAddr);
        assertEq(storedAddr, testModule, "Storage should persist");
    }

    function test_pool_proxy_module_registration() public {
        // Deploy actual contracts
        Admin admin = new Admin();
        PoolProxy proxy = new PoolProxy();

        // Initialize
        uint8[29] memory feePad;
        IPool.FeeParams memory feeParams = IPool.FeeParams({
            protoShare: 25,
            flashFeeBps: 5,
            _pad: feePad
        });
        proxy.initialize(address(this), address(0x1234), address(0x5678), feeParams);

        // Compute slot for requestAddAsset selector
        uint256 baseSlot = uint256(C.CORE_STORAGE_LOC);
        uint256 modulesSlot = baseSlot + 14;
        bytes4 selector = IAdminTimelock.requestAddAsset.selector;
        bytes32 slot = keccak256(abi.encode(selector, modulesSlot));

        console2.log("Selector:");
        console2.logBytes4(selector);
        console2.log("Computed storage slot:");
        console2.logBytes32(slot);

        // Write admin module address to this slot
        vm.store(address(proxy), slot, bytes32(uint256(uint160(address(admin)))));

        // Read back to verify
        bytes32 stored = vm.load(address(proxy), slot);
        console2.log("Stored value:");
        console2.logBytes32(stored);

        // Now try to call getModule to see if proxy properly reads it
        // getModule is defined in IAdmin and should be at admin module
        // But we need to register getModule too...

        // Let's just verify the storage is correct
        assertEq(address(uint160(uint256(stored))), address(admin), "Admin should be stored");

        // Also register getModule so we can call it
        bytes4 getModuleSelector = IAdminConfig.getModule.selector;
        console2.log("getModule selector:");
        console2.logBytes4(getModuleSelector);

        bytes32 getModuleSlot = keccak256(abi.encode(getModuleSelector, modulesSlot));
        console2.log("getModule storage slot:");
        console2.logBytes32(getModuleSlot);

        vm.store(address(proxy), getModuleSlot, bytes32(uint256(uint160(address(admin)))));

        // Verify getModule slot was written
        bytes32 getModuleStored = vm.load(address(proxy), getModuleSlot);
        console2.log("getModule slot value:");
        console2.logBytes32(getModuleStored);

        // Let's manually check what the proxy reads
        // We'll use a low-level staticcall to see the exact revert data

        bytes memory callData = abi.encodeWithSelector(IAdminConfig.getModule.selector, selector);
        console2.log("Call data:");
        console2.logBytes(callData);

        (bool success, bytes memory returnData) = address(proxy).staticcall(callData);
        console2.log("Success:", success);
        if (!success) {
            console2.log("Revert data:");
            console2.logBytes(returnData);
        }

        // Try to manually read what the proxy is actually trying to load
        // The proxy does: $.modules[msg.sig] where $ is at CORE_STORAGE_LOC
        // msg.sig for getModule call would be 0xdcef0069

        // The slot the PROXY computes for getModule (0xdcef0069) should be:
        // keccak256(abi.encode(bytes32(0xdcef0069), base + 14))
        // Let's see what the proxy reads from that slot

        // Reading directly from the slot we computed
        bytes32 whatProxyReads = vm.load(address(proxy), getModuleSlot);
        console2.log("Value at computed getModule slot:");
        console2.logBytes32(whatProxyReads);

        // Let's try computing the slot differently
        // When Solidity computes mapping slots, for bytes4 key it should right-pad
        // abi.encode(bytes4) should give 32 bytes with bytes4 in the HIGH bits (left-aligned)
        console2.log("\n--- Exploring slot computation ---");
        console2.log("abi.encode(getModuleSelector, modulesSlot):");
        console2.logBytes(abi.encode(getModuleSelector, modulesSlot));

        // Try with bytes32 cast (high bits)
        bytes32 keyAsBytes32High = bytes32(getModuleSelector);  // Left-aligned
        console2.log("bytes32(getModuleSelector) [high bits]:");
        console2.logBytes32(keyAsBytes32High);

        // Try with uint256 cast (low bits)
        bytes32 keyAsBytes32Low = bytes32(uint256(uint32(getModuleSelector)));  // Right-aligned
        console2.log("bytes32(uint256(uint32(getModuleSelector))) [low bits]:");
        console2.logBytes32(keyAsBytes32Low);

        // Compute slots both ways
        bytes32 slotHigh = keccak256(abi.encode(keyAsBytes32High, modulesSlot));
        bytes32 slotLow = keccak256(abi.encode(keyAsBytes32Low, modulesSlot));
        console2.log("Slot using high bits:");
        console2.logBytes32(slotHigh);
        console2.log("Slot using low bits:");
        console2.logBytes32(slotLow);

        // Check what's at those slots
        console2.log("Value at high-bits slot:");
        console2.logBytes32(vm.load(address(proxy), slotHigh));
        console2.log("Value at low-bits slot:");
        console2.logBytes32(vm.load(address(proxy), slotLow));

        // Brute force: try different offsets to find the real modules slot
        console2.log("\n--- Trying different offsets ---");
        for (uint256 offset = 0; offset < 25; offset++) {
            uint256 trySlot = baseSlot + offset;
            bytes32 slot_ = keccak256(abi.encode(keyAsBytes32High, trySlot));
            // Write to this slot
            vm.store(address(proxy), slot_, bytes32(uint256(uint160(address(admin)))));

            // Test if this works
            (bool ok, ) = address(proxy).staticcall(callData);
            if (ok) {
                console2.log("SUCCESS at offset:", offset);
                console2.log("Slot base:", trySlot);
            }
            // Clear it for next try
            vm.store(address(proxy), slot_, bytes32(0));
        }
    }

    function test_compute_selector_slot() public pure {
        uint256 baseSlot = uint256(C.CORE_STORAGE_LOC);
        uint256 modulesSlot = baseSlot + 14;

        // Test with swap selector from interface
        bytes4 swapSelector = IPoolModule.swap.selector;
        console2.log("IPoolModule.swap.selector:");
        console2.logBytes4(swapSelector);

        // Also computed version
        bytes4 swapSelectorComputed = bytes4(keccak256("swap(address,address,uint256,uint256,address)"));
        console2.log("Computed swap selector:");
        console2.logBytes4(swapSelectorComputed);

        // requestAddAsset selector
        bytes4 requestAddAssetSelector = IAdminTimelock.requestAddAsset.selector;
        console2.log("IAdminTimelock.requestAddAsset.selector:");
        console2.logBytes4(requestAddAssetSelector);

        // getModule selector
        bytes4 getModuleSelector = IAdminConfig.getModule.selector;
        console2.log("IAdminConfig.getModule.selector:");
        console2.logBytes4(getModuleSelector);

        // Solidity mapping slot calculation for mapping(bytes4 => address)
        // slot = keccak256(abi.encode(key, mappingSlot))
        bytes32 slot = keccak256(abi.encode(swapSelector, modulesSlot));
        console2.log("Computed slot for swap selector:");
        console2.logBytes32(slot);

        bytes32 slot2 = keccak256(abi.encode(requestAddAssetSelector, modulesSlot));
        console2.log("Computed slot for requestAddAsset selector:");
        console2.logBytes32(slot2);

        bytes32 slot3 = keccak256(abi.encode(getModuleSelector, modulesSlot));
        console2.log("Computed slot for getModule selector:");
        console2.logBytes32(slot3);
    }
}

contract DummyProxy {
    // Empty contract for storage testing
}

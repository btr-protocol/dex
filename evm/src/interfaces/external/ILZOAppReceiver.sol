// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {LZEndpointV2} from "./ILZEndpointV2.sol";

/// @title ILZOAppReceiver -LayerZero OApp message receiver
interface ILZOAppReceiver {
    function lzReceive(
        LZEndpointV2.Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;
}

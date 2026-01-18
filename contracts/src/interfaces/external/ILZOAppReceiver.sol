// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {LZEndpointV2} from "./ILZEndpointV2.sol";

/// @title ILZOAppReceiver
/// @notice Interface for LayerZero OApp message receiver
/// @dev See https://docs.layerzero.network/v2/developers/evm/oapp/overview
interface ILZOAppReceiver {

    /// @notice Called by LayerZero Endpoint to deliver a message
    /// @param _origin Origin information (srcEid, sender, nonce)
    /// @param _guid Message GUID
    /// @param _message Encoded message payload
    /// @param _executor Executor address
    /// @param _extraData Additional arbitrary data
    function lzReceive(
        LZEndpointV2.Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title LZEndpointV2
/// @notice Minimal LayerZero V2 Endpoint interface for bridge operations
/// @dev See https://docs.layerzero.network/v2/developers/evm/oapp/overview
interface LZEndpointV2 {

    /// @notice Parameters for sending a message
    struct SendParam {
        uint32 dstEid;              // Destination endpoint ID
        bytes32 to;                 // Recipient address (bytes32 for non-EVM)
        bytes message;              // Message payload
        bytes options;              // Execution options (gas, etc)
        bool payInLzToken;          // Pay fees in LZ token vs native
    }

    /// @notice Messaging fee structure
    struct MessagingFee {
        uint256 nativeFee;          // Fee in native gas token
        uint256 lzTokenFee;         // Fee in LZ token
    }

    /// @notice Origin information for received messages
    struct Origin {
        uint32 srcEid;              // Source endpoint ID
        bytes32 sender;             // Sender address on source chain
        uint64 nonce;               // Message nonce
    }

    /// @notice Send a message to destination chain
    /// @param _sendParam Send parameters
    /// @param _fee Messaging fee (from quote)
    /// @param _refundAddress Address to refund excess fees
    /// @return receipt Message receipt with nonce and fee
    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory receipt);

    /// @notice Quote the messaging fee for a send operation
    /// @param _sendParam Send parameters
    /// @param _payInLzToken Whether to pay in LZ token
    /// @return fee Messaging fee structure
    function quote(
        SendParam calldata _sendParam,
        bool _payInLzToken
    ) external view returns (MessagingFee memory fee);

    /// @notice Message receipt returned from send
    struct MessagingReceipt {
        bytes32 guid;               // Message GUID
        uint64 nonce;               // Message nonce
        MessagingFee fee;           // Actual fee paid
    }
}

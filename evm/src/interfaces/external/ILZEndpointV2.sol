// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @title LZEndpointV2 -minimal LayerZero V2 endpoint
interface LZEndpointV2 {
    struct SendParam {
        uint32 dstEid;
        bytes32 to;
        bytes message;
        bytes options;
        bool payInLzToken;
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    struct Origin {
        uint32 srcEid;
        bytes32 sender;
        uint64 nonce;
    }

    struct MessagingReceipt {
        bytes32 guid;
        uint64 nonce;
        MessagingFee fee;
    }

    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory receipt);

    function quote(
        SendParam calldata _sendParam,
        bool _payInLzToken
    ) external view returns (MessagingFee memory fee);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Base} from "./Base.sol";
import {Err} from "@btr-peripheral/Errors.sol";
import {IRescue} from "../interfaces/modules/IRescue.sol";
import {LibConstants as C} from "../libraries/LibConstants.sol";
import {LibTimelock as TL} from "../libraries/LibTimelock.sol";
import {LibRescue} from "../libraries/LibRescue.sol";

/// @title Rescue — emergency asset recovery w/ unified timelock
contract Rescue is Base, IRescue {
    uint48 constant RESCUE_TIMELOCK = 4 days;
    uint48 constant RESCUE_WINDOW = 3 days;

    /// @dev ERC-7201 storage
    struct RescueStorage {
        mapping(bytes32 => RescueRequest) requests;
        mapping(bytes32 => uint96) pending;
    }

    function _rs() internal pure returns (RescueStorage storage $) {
        bytes32 slot = C.RESCUE_STORAGE_LOC;
        assembly { $.slot := slot }
    }

    function requestRescue(
        TokenType tokenType,
        address token,
        uint256[] calldata tokenIds,
        address receiver
    ) external onlyOwner {
        if (receiver == address(0)) revert Err.InvalidInput();

        bytes32 id = keccak256(abi.encodePacked(receiver, tokenType));
        RescueStorage storage rs = _rs();
        if (rs.pending[id] != 0) revert Err.InvalidState();

        uint256 amount;
        if (tokenType <= TokenType.ERC20) {
            amount = LibRescue.getBalance(tokenType == TokenType.NATIVE ? C.NATIVE : token);
            if (amount == 0) revert Err.ZeroValue();
        } else {
            if (tokenIds.length == 0) revert Err.InvalidInput();
            amount = tokenIds.length;
        }

        rs.requests[id] = RescueRequest({
            token: token,
            tokenIds: tokenIds,
            amount: amount,
            receiver: receiver
        });
        rs.pending[id] = TL.pack(RESCUE_TIMELOCK, RESCUE_WINDOW);
        emit RescueRequested(receiver, tokenType, token);
    }

    function executeRescue(address receiver, TokenType tokenType) external nonReentrant {
        bytes32 id = keccak256(abi.encodePacked(receiver, tokenType));
        RescueStorage storage rs = _rs();

        TL.validate(rs.pending[id]);
        RescueRequest memory req = rs.requests[id];
        delete rs.requests[id];
        delete rs.pending[id];

        if (tokenType == TokenType.NATIVE || tokenType == TokenType.ERC20) {
            uint256 balance = LibRescue.getBalance(req.token);
            uint256 payout = balance < req.amount ? balance : req.amount;
            LibRescue.rescueToken(tokenType == TokenType.NATIVE ? C.NATIVE : req.token, req.receiver, payout);
            emit RescueExecuted(req.receiver, tokenType, req.token, payout);
        } else if (tokenType == TokenType.ERC721) {
            LibRescue.rescueERC721Batch(req.token, req.receiver, req.tokenIds);
            emit RescueExecuted(req.receiver, tokenType, req.token, req.tokenIds.length);
        } else {
            LibRescue.rescueERC1155Batch(req.token, req.receiver, req.tokenIds);
            emit RescueExecuted(req.receiver, tokenType, req.token, req.tokenIds.length);
        }
    }

    receive() external payable {}
}

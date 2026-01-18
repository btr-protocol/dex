// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseV1} from "./BaseV1.sol";
import {IErrors} from "../interfaces/IErrors.sol";
import {IPoolV1} from "../interfaces/IPoolV1.sol";
import {IRescueV1} from "../interfaces/modules/IRescueV1.sol";
import {IERC721} from "../interfaces/external/IERC721.sol";
import {IERC1155} from "../interfaces/external/IERC1155.sol";
import {LibConstants as C} from "../libraries/LibConstants.sol";
import {LibTimelock as TL} from "../libraries/LibTimelock.sol";
import {LibRescue} from "../libraries/LibRescue.sol";

/// @title Rescue
/// @notice Ultra-compact emergency asset recovery with unified timelock
contract RescueV1 is BaseV1, IRescueV1 {
    uint48 constant RESCUE_TIMELOCK = 4 days;
    uint48 constant RESCUE_WINDOW = 3 days;

    /// @dev ERC-7201 storage
    struct RescueStorage {
        mapping(bytes32 => RescueRequest) requests;
        mapping(bytes32 => uint96) pending;  // Packed timelock
    }

    function _rs() internal pure returns (RescueStorage storage $) {
        bytes32 slot = C.RESCUE_STORAGE_LOC;
        assembly { $.slot := slot }
    }

    // ========== REQUEST RESCUE ==========

    /// @notice Request any token rescue (unified)
    function requestRescue(
        TokenType tokenType,
        address token,
        uint256[] calldata tokenIds,
        address receiver
    ) external onlyOwner {
        if (receiver == address(0)) revert IErrors.InvalidInput();

        bytes32 id = keccak256(abi.encodePacked(receiver, tokenType));
        RescueStorage storage rs = _rs();

        if (rs.pending[id] != 0) revert IErrors.InvalidState();

        uint256 amount;
        if (tokenType <= TokenType.ERC20) {
            amount = LibRescue.getBalance(tokenType == TokenType.NATIVE ? C.NATIVE : token);
            if (amount == 0) revert IErrors.ZeroValue();
        } else {
            if (tokenIds.length == 0) revert IErrors.InvalidInput();
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

    // ========== EXECUTE RESCUE ==========

    /// @notice Execute rescue after timelock
    function executeRescue(address receiver, TokenType tokenType) external nonReentrant {
        bytes32 id = keccak256(abi.encodePacked(receiver, tokenType));
        RescueStorage storage rs = _rs();

        TL.validate(rs.pending[id]);

        RescueRequest memory req = rs.requests[id];
        delete rs.requests[id];
        delete rs.pending[id];

        // Execute based on type
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
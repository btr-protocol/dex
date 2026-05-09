// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IERC165 — Standard Interface Detection
interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

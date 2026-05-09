// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Base} from "./Base.sol";
import {ILend} from "../interfaces/modules/ILend.sol";

/// @title Lend
/// @notice Reserved for future lending integration. See docs/dex/Lend (Forward-Looking).md for design notes.
abstract contract Lend is Base, ILend {}

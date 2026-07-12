// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {CompoundV2YieldHook} from "./CompoundV2YieldHook.sol";

/// @title VenusHook — thin alias for BSC Venus Core (Compound V2 family).
/// @dev Prefer deploying CompoundV2YieldHook directly; kept for ABI/deploy continuity.
contract VenusHook is CompoundV2YieldHook {
    constructor(address ac_, address pool_, address token_, address vToken_)
        CompoundV2YieldHook(ac_, pool_, token_, vToken_)
    {}
}

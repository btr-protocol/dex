// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {ERC4626YieldHook} from "./ERC4626YieldHook.sol";

/// @title EulerV2YieldHook — Euler EVK / Earn vaults that expose ERC-4626.
/// @dev Same surface as ERC4626YieldHook; separate type for registry / incentives labeling.
contract EulerV2YieldHook is ERC4626YieldHook {
    constructor(address ac_, address pool_, address token_, address vault_)
        ERC4626YieldHook(ac_, pool_, token_, vault_)
    {}
}

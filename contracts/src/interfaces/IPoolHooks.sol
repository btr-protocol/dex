// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title IPoolHooks
/// @notice Per-asset lifecycle hooks with symmetric before/after pairs
/// @dev Inspired by Uniswap v4, Algebra Integral, and Balancer V3
/// @dev Hook flags defined in LibConstants
interface IPoolHooks {
    /// @notice Bitmask of implemented hooks
    function hookFlags() external pure returns (uint32);

    // ========== POOL INITIALIZATION ==========

    function preInitialize(address pool, address owner, address baseToken, address wnative) external;
    function postInitialize(address pool, address owner, address baseToken, address wnative) external;

    // ========== DEPOSIT ==========

    function preDeposit(address pool, address sender, address token, uint256 amountIn) external;

    /// @notice Called after deposit & LP mint
    /// @return hookFeeOut Additional fee to take from deposit
    /// @return hookIncentiveOut Additional incentive to send to depositor
    function postDeposit(
        address pool,
        address sender,
        address token,
        uint256 amountIn,
        uint256 lpMinted
    ) external returns (uint256 hookFeeOut, uint256 hookIncentiveOut);

    // ========== WITHDRAW ==========

    function preWithdraw(address pool, address sender, address token, uint256 lpAmount) external;

    /// @notice Called after LP burn before token transfer
    /// @return exitFee Amount to divert from user
    /// @return incentiveOut Extra amount to send to user
    function postWithdraw(
        address pool,
        address sender,
        address token,
        uint256 amountOutGross,
        uint256 lpBurned
    ) external returns (uint256 exitFee, uint256 incentiveOut);

    // ========== SWAP ==========

    /// @notice Called after pricing, before state update
    /// @return extraFeeOut Additional fee to take
    /// @return newFeeBps Optional fee override (0 = keep core fee)
    function preSwap(
        address pool,
        address sender,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutQuoted
    ) external returns (uint256 extraFeeOut, uint16 newFeeBps);

    /// @notice Called after state update and transfers
    /// @return hookDeltaOut Additional delta (positive = take, negative = give)
    function postSwap(
        address pool,
        address sender,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutFinal
    ) external returns (int256 hookDeltaOut);

    // ========== DONATE ==========

    function preDonate(address pool, address sender, address token, uint256 amount) external;
    function postDonate(address pool, address sender, address token, uint256 amount) external;

    // ========== FLASH LOAN ==========

    function preFlashLoan(
        address pool,
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external;

    function postFlashLoan(
        address pool,
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external;
}

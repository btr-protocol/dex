// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPoolHooks — per-asset lifecycle hooks (symmetric pre/post). Flags in LibConstants.
interface IPoolHooks {
    function hookFlags() external pure returns (uint32);

    function preInitialize(address pool, address owner, address baseToken, address wnative) external;
    function postInitialize(address pool, address owner, address baseToken, address wnative) external;

    function preDeposit(address pool, address sender, address token, uint256 amountIn) external;

    /// @return hookFeeOut extra fee. @return hookIncentiveOut bonus to depositor.
    function postDeposit(address pool, address sender, address token, uint256 amountIn, uint256 lpMinted)
        external returns (uint256 hookFeeOut, uint256 hookIncentiveOut);

    function preWithdraw(address pool, address sender, address token, uint256 lpAmount) external;

    /// @return exitFee diverted from user. @return incentiveOut bonus.
    function postWithdraw(address pool, address sender, address token, uint256 amountOutGross, uint256 lpBurned)
        external returns (uint256 exitFee, uint256 incentiveOut);

    /// @return extraFeeOut extra fee. @return newFeeBps override (0=keep core).
    function preSwap(
        address pool,
        address sender,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutQuoted
    ) external returns (uint256 extraFeeOut, uint16 newFeeBps);

    /// @return hookDeltaOut extra delta (+take, -give)
    function postSwap(
        address pool,
        address sender,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutFinal
    ) external returns (int256 hookDeltaOut);

    function preDonate(address pool, address sender, address token, uint256 amount) external;
    function postDonate(address pool, address sender, address token, uint256 amount) external;

    function preFlashLoan(address pool, address initiator, address token, uint256 amount, uint256 fee, bytes calldata data) external;
    function postFlashLoan(address pool, address initiator, address token, uint256 amount, uint256 fee, bytes calldata data) external;
}

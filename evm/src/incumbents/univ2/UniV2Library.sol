// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.35;

import {UniswapV2Pair} from "./vendor/UniswapV2Pair.sol";

/// @notice Lean helpers around official V2 pair math (getAmountOut = periphery formula).
library UniV2Library {
    /// @dev Identical to UniswapV2Library.getAmountOut (v2-periphery).
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function quote(address pair, bool zeroForOne, uint256 amountIn) internal view returns (uint256 amountOut) {
        (uint112 r0, uint112 r1,) = UniswapV2Pair(pair).getReserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        return getAmountOut(amountIn, reserveIn, reserveOut);
    }
}

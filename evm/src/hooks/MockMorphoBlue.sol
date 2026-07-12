// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IMorphoBlue, MorphoId} from "../interfaces/external/IMorphoBlue.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title MockMorphoBlue — supply-only Morpho Blue market stub (SharesMathLib virtual shares).
contract MockMorphoBlue is IMorphoBlue {
    using SafeTransferLib for address;
    using MorphoId for MarketParams;

    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    mapping(bytes32 => MarketParams) internal _params;
    mapping(bytes32 => uint128) public totalSupplyAssets;
    mapping(bytes32 => uint128) public totalSupplyShares;
    mapping(bytes32 => uint128) public totalBorrowAssets;
    mapping(bytes32 => uint128) public totalBorrowShares;
    mapping(bytes32 => mapping(address => uint256)) public supplySharesOf;

    /// @notice Inject supply totals (e.g. simulate IRM accrual without touching shares).
    function setSupplyTotals(bytes32 id_, uint128 assets, uint128 shares) external {
        totalSupplyAssets[id_] = assets;
        totalSupplyShares[id_] = shares;
    }

    function setMarket(MarketParams calldata params_) external {
        bytes32 id_ = params_.id();
        _params[id_] = params_;
    }

    function setBorrow(bytes32 id_, uint128 borrowed) external {
        totalBorrowAssets[id_] = borrowed;
    }

    function idToMarketParams(bytes32 id_) external view override returns (MarketParams memory) {
        return _params[id_];
    }

    function position(bytes32 id_, address user)
        external
        view
        override
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral)
    {
        supplyShares = supplySharesOf[id_][user];
    }

    function market(bytes32 id_)
        external
        view
        override
        returns (
            uint128 totalSupplyAssets_,
            uint128 totalSupplyShares_,
            uint128 totalBorrowAssets_,
            uint128 totalBorrowShares_,
            uint128 lastUpdate,
            uint128 fee
        )
    {
        totalSupplyAssets_ = totalSupplyAssets[id_];
        totalSupplyShares_ = totalSupplyShares[id_];
        totalBorrowAssets_ = totalBorrowAssets[id_];
        totalBorrowShares_ = totalBorrowShares[id_];
    }

    function supply(MarketParams memory marketParams, uint256 assets, uint256, address onBehalf, bytes calldata)
        external
        override
        returns (uint256 assetsSupplied, uint256 sharesSupplied)
    {
        bytes32 id_ = marketParams.id();
        if (_params[id_].loanToken == address(0)) revert Err.BadConfig();
        marketParams.loanToken.safeTransferFrom(msg.sender, address(this), assets);
        // SharesMathLib.toSharesDown
        uint256 shares = (assets * (uint256(totalSupplyShares[id_]) + VIRTUAL_SHARES))
            / (uint256(totalSupplyAssets[id_]) + VIRTUAL_ASSETS);
        totalSupplyAssets[id_] += uint128(assets);
        totalSupplyShares[id_] += uint128(shares);
        supplySharesOf[id_][onBehalf] += shares;
        return (assets, shares);
    }

    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256,
        address onBehalf,
        address receiver
    ) external override returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn) {
        bytes32 id_ = marketParams.id();
        uint256 userShares = supplySharesOf[id_][onBehalf];
        // SharesMathLib.toSharesUp
        uint256 shares = (
            assets * (uint256(totalSupplyShares[id_]) + VIRTUAL_SHARES)
                + (uint256(totalSupplyAssets[id_]) + VIRTUAL_ASSETS) - 1
        ) / (uint256(totalSupplyAssets[id_]) + VIRTUAL_ASSETS);
        if (shares > userShares) {
            shares = userShares;
            // SharesMathLib.toAssetsDown
            assets = (shares * (uint256(totalSupplyAssets[id_]) + VIRTUAL_ASSETS))
                / (uint256(totalSupplyShares[id_]) + VIRTUAL_SHARES);
        }
        uint256 liq = uint256(totalSupplyAssets[id_]) > uint256(totalBorrowAssets[id_])
            ? uint256(totalSupplyAssets[id_]) - uint256(totalBorrowAssets[id_])
            : 0;
        if (assets > liq) assets = liq;
        supplySharesOf[id_][onBehalf] = userShares - shares;
        totalSupplyShares[id_] -= uint128(shares);
        totalSupplyAssets[id_] -= uint128(assets);
        marketParams.loanToken.safeTransfer(receiver, assets);
        return (assets, shares);
    }
}

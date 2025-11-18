// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {LibStorage as S} from "../libraries/LibStorage.sol";
import {LibDiamondStorage} from "../libraries/LibDiamondStorage.sol";
import {BAMMErrors as E} from "./BAMMErrors.sol";
import {BAMMLPToken} from "./BAMMLPToken.sol";

/// @title BAMMAdmin
/// @notice Admin facet - delegates to existing management functions
/// @dev Delegatecalled from BAMMCore, requires owner access
contract BAMMAdmin {

    // ========== MODIFIERS ==========

    modifier onlyOwner() {
        LibDiamondStorage.DiamondStorage storage d = LibDiamondStorage.ds();
        if (msg.sender != d.owner) revert E.Unauthorized();
        _;
    }

    // ========== ASSET MANAGEMENT ==========

    /// @notice Add new asset to pool (owner only)
    function addAsset(
        address token,
        IBAMM.FeeConfig calldata fees,
        IBAMM.OracleConfig calldata oracle,
        IBAMM.RiskConfig calldata risk,
        IBAMM.LiquidtyConfig calldata profile
    ) external onlyOwner {
        IBAMM.BAMMStorage storage $ = S.bamm();

        // Store asset config
        IBAMM.Asset storage asset = $.assets[token];
        asset.fees = fees;
        asset.decimals = 18; // Default, would be fetched from token in prod
        asset.segmentCount = uint8(profile.weights.length);

        // Store separate configs
        $.riskConfigs[token] = risk;
        $.oracleConfigs[token] = oracle;
        $.lpStates[token] = IBAMM.LPState({
            totalScaledSupply: 0,
            liquidityIndex: 1e18,
            decayStartTime: 0,
            coverageAtStart: 0,
            lastUpdateTime: uint32(block.timestamp)
        });

        $.registeredAssets.push(token);

        emit IBAMM.AssetAdded(token, risk.minLiquidity);
    }

    /// @notice Register LP token for asset (owner only, validates LP token)
    function setLPToken(address asset, address lpToken) external onlyOwner {
        IBAMM.BAMMStorage storage $ = S.bamm();

        // Validate asset exists
        if ($.assets[asset].decimals == 0) revert E.AssetNotFound();

        // Validate LP token points back to this asset and BAMM
        if (BAMMLPToken(lpToken).asset() != asset) revert E.InvalidLPToken();
        if (BAMMLPToken(lpToken).bamm() != address(this)) revert E.InvalidLPToken();

        $.lpTokens[asset] = lpToken;
        emit IBAMM.LPTokenSet(asset, lpToken);
    }

    /// @notice Collect protocol fees (owner only)
    function collectProtocolFees(address[] calldata tokens) external onlyOwner {
        IBAMM.BAMMStorage storage $ = S.bamm();
        uint256[] memory amounts = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; ++i) {
            amounts[i] = $.protocolFees[tokens[i]];
            $.protocolFees[tokens[i]] = 0;
        }

        emit IBAMM.ProtocolFeesCollected(msg.sender, tokens, amounts);
    }

    /// @notice Freeze asset (owner only)
    function freezeAsset(address token, string calldata reason) external onlyOwner {
        IBAMM.BAMMStorage storage $ = S.bamm();
        IBAMM.RiskConfig storage risk = $.riskConfigs[token];
        risk.flags = risk.flags | S.RISK_FLAG_FROZEN;
        emit IBAMM.AssetFrozen(token, reason);
    }

    /// @notice Unfreeze asset (owner only)
    function unfreezeAsset(address token) external onlyOwner {
        IBAMM.BAMMStorage storage $ = S.bamm();
        IBAMM.RiskConfig storage risk = $.riskConfigs[token];
        risk.flags = risk.flags & ~S.RISK_FLAG_FROZEN;
        emit IBAMM.AssetUnfrozen(token);
    }

    /// @notice Update fee config (owner only)
    function updateFeeConfig(address token, IBAMM.FeeConfig calldata fees) external onlyOwner {
        IBAMM.BAMMStorage storage $ = S.bamm();
        $.assets[token].fees = fees;
        emit IBAMM.FeeConfigUpdated(token, fees);
    }

    /// @notice Blacklist address (owner only)
    function blacklistAddress(address account) external onlyOwner {
        IBAMM.BAMMStorage storage $ = S.bamm();
        $.blacklisted[account] = true;
        emit IBAMM.AddressBlacklisted(account);
    }

    /// @notice Unblacklist address (owner only)
    function unblacklistAddress(address account) external onlyOwner {
        IBAMM.BAMMStorage storage $ = S.bamm();
        $.blacklisted[account] = false;
        emit IBAMM.AddressRemovedFromBlacklist(account);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseV1} from "./BaseV1.sol";
import {IErrors} from "../interfaces/IErrors.sol";
import {ILendV1} from "../interfaces/modules/ILendV1.sol";

/// @title Lend
/// @notice Internal money market for LP-collateralized leverage trading
/// @dev ⚠️ DO NOT DELETE - Implementation in progress
///
/// ## DESIGN PHILOSOPHY
///
/// This module implements an **internal money market** where:
/// 1. Each AIMM asset has its own isolated lending market
/// 2. Reserves (idle liquidity) are borrowable
/// 3. Liabilities (LP positions) serve as collateral (valued at liabilities × coverage ratio)
/// 4. Enables leverage trading WITHOUT perpetual contracts
///
/// **NOT for reserves hypothecation** - That's handled by hooks (see AaveYieldHook, MorphoYieldHook)
///
/// ## ADVANTAGE: LP-Collateralized vs Perpetuals
///
/// **Traditional Perpetuals (GMX, Hyperliquid, dYdX)**:
/// - Zero-sum game: Trader profit = LP loss
/// - Historical losses: GMX -$12M, Hyperliquid -$4M + $130M withdrawals
/// - Adversarial relationship: Traders bet AGAINST LPs
///
/// **LP-Collateralized (This Module)**:
/// - Positive-sum: Both earn from real trading fees
/// - Example: 10x leverage, 8% LP APY, 5% borrow → +35% APR (vs -47% for Contango)
/// - Zero slippage: No DEX swaps needed
/// - Aligned incentives: Leveraged traders ARE LPs, want pool health
/// - Organic TVL growth: Each leveraged position increases reserves
///
/// ## LEVERAGE MECHANISM: Flash Loan Loop
///
/// User opens 10x position with $100K:
/// ```
/// 1. Flash loan $900K from AIMM Flash module
/// 2. Deposit $1M total → receive LP tokens (liabilities)
/// 3. Supply LP tokens to THIS module as collateral
/// 4. Borrow $900K from THIS module
/// 5. Repay flash loan
///
/// Result:
/// - User owns: $1M LP position (10x leverage)
/// - User owes: $900K debt to Lend module
/// - Collateral: LP tokens worth $1M × coverage ratio
/// - Cost: 0% slippage, earns LP fees while leveraged
/// ```
///
/// ## COLLATERAL VALUATION (Coverage-Adjusted)
///
/// ```solidity
/// // LP collateral value accounts for coverage ratio
/// lpValue = lpAmount × underlyingPrice × coverageRatio / PRECISION
///
/// // Example: Coverage drops to 90%
/// collateralValue = $1M LP × 0.9 = $900K
/// debtValue = $900K
/// healthFactor = $900K / $900K = 1.0 (liquidation threshold)
/// ```
///
/// **Key insight**: Coverage ratio drop = collateral haircut
/// → Leveraged traders incentivized to maintain pool health
///
/// ## ACCOUNTING NEUTRALITY
///
/// Opening leveraged position doesn't hurt coverage:
/// ```
/// Before:
///   Reserves: $5M, Liabilities: $5M, Coverage: 100%
///
/// After user opens 10x on $100K:
///   Reserves: $5.9M (+$900K borrowed deposited)
///   Liabilities: $5.9M (+$900K LP claim)
///   Coverage: 100% (unchanged!)
/// ```
///
/// ## ISOLATED MARKETS (Per-Asset)
///
/// Each asset operates independently:
/// - USDC market: Borrow USDC against USDC LP collateral
/// - WETH market: Borrow WETH against WETH LP collateral
/// - No cross-asset initially (can add Phase 2)
///
/// Benefits:
/// - Simpler risk management
/// - No contagion between assets
/// - Clear liquidation logic
///
/// ## RISK PARAMETERS
///
/// Per-asset configuration:
/// ```solidity
/// struct LendConfig {
///     uint16 maxLTV;              // Max loan-to-value (e.g., 8000 = 80%)
///     uint16 liquidationThreshold; // Liquidation LTV (e.g., 8600 = 86%)
///     uint16 liquidationBonus;     // Liquidator incentive (e.g., 500 = 5%)
///     uint32 borrowRate;           // Annual borrow rate (e.g., 5% APR)
///     uint128 maxBorrowPerUser;    // Position size cap
/// }
/// ```
///
/// Conservative initial values:
/// ```
/// USDC (low volatility):
///   maxLTV: 80%, liquidationThreshold: 86%, maxLeverage: 5x
///
/// WETH (medium volatility):
///   maxLTV: 75%, liquidationThreshold: 81%, maxLeverage: 4x
/// ```
///
/// ## LIQUIDATION MECHANICS
///
/// Partial liquidations minimize user losses:
/// ```
/// healthFactor = collateralValue × liquidationThreshold / debtValue
///
/// If healthFactor < 1.0:
///   1. Calculate shortfall
///   2. Liquidate minimum required (50% position)
///   3. Liquidator receives 5-10% bonus (from collateral)
///   4. Remaining position restored to healthy ratio
/// ```
///
/// ## INTEREST RATE MODEL
///
/// Simple fixed rate initially, can upgrade to utilization-based:
/// ```
/// // Phase 1: Fixed rate
/// borrowAPR = 5% (constant)
///
/// // Phase 2: Utilization-based (like Aave)
/// utilization = totalBorrowed / totalReserves
/// borrowAPR = baseRate + (utilization × slope)
///
/// Example:
///   0% util → 2% APR
///   50% util → 5% APR
///   80% util → 10% APR (kink)
///   90% util → 20% APR (steep slope)
/// ```
///
/// ## RETURN PROFILE EXAMPLE
///
/// User with 10x leverage on USDC:
/// ```
/// Capital: $100K
/// LP position: $1M (10x)
/// Debt: $900K
///
/// Revenue:
///   LP fees: $1M × 8% APY = $80K/year
///
/// Costs:
///   Borrow interest: $900K × 5% = $45K/year
///
/// Net profit: $35K on $100K capital = 35% APR
/// (Profitable even if USDC price flat!)
/// ```
///
/// Compare to Contango (spot leverage):
/// ```
/// Same 10x position with 0% price movement:
///   Revenue: $0 (no LP fees)
///   Costs: $45K borrow + $2K slippage = $47K
///   Net: -47% (requires 7%+ price appreciation to break even)
/// ```
///
/// ## INTEGRATION WITH OTHER MODULES
///
/// - **Flash**: Provides flash loans for leverage loop
/// - **Core**: Handles deposits/withdrawals (LP token creation)
/// - **Admin**: Configures risk parameters per asset
/// - **Hooks**: NOT used for hypothecation (that's AaveYieldHook/MorphoYieldHook)
///
/// ## RESERVES HYPOTHECATION (Separate Concern)
///
/// Reserves hypothecation to external protocols (Aave, Morpho) is done via hooks:
/// - AaveYieldHook.sol: Deploy reserves to Aave V3 → earn interest
/// - MorphoYieldHook.sol: Deploy reserves to Morpho vaults → earn yield
/// - EulerYieldHook.sol: Deploy reserves to Euler V2 → earn interest
///
/// **Why separate?**
/// - Hooks are modular, composable, per-asset configurable
/// - Don't need to build our own lending protocol for yield
/// - Focus Lend module on leverage trading UX
///
/// ## IMPLEMENTATION PHASES
///
/// **Phase 1 - Basic Lending**:
/// ```solidity
/// function borrow(address token, uint256 amount) external returns (uint256 debtId)
/// function repay(address token, uint256 amount) external
/// function supplyCollateral(address token, uint256 lpAmount) external
/// function withdrawCollateral(address token, uint256 lpAmount) external
/// ```
///
/// **Phase 2 - Leverage Helpers**:
/// ```solidity
/// function openLeveragedPosition(address token, uint256 capital, uint256 targetLeverage) external
/// function closeLeveragedPosition(uint256 positionId) external
/// function adjustLeverage(uint256 positionId, uint256 newLeverage) external
/// ```
///
/// **Phase 3 - Liquidations**:
/// ```solidity
/// function liquidate(address borrower, address token, uint256 amount) external
/// function getHealthFactor(address user, address token) external view returns (uint256)
/// function getLiquidationPrice(address user, address token) external view returns (uint256)
/// ```
///
/// **Phase 4 - Advanced Features**:
/// - Cross-asset margining (borrow USDC against WETH LP)
/// - Utilization-based interest rates
/// - Isolated lending pools with custom risk params
/// - Position transfer/delegation
///
/// ## SECURITY CONSIDERATIONS
///
/// 1. **Oracle Manipulation**: Use TWAP for LP valuation, verify coverage ratio
/// 2. **Liquidation Cascades**: Cap per-user position size (% of total reserves)
/// 3. **Flash Loan Attacks**: ReentrancyGuard, verify coverage before/after
/// 4. **Coverage Ratio Gaming**: Liquidation threshold > coverage drop speed
/// 5. **Interest Accrual Bugs**: Test debt index updates thoroughly
///
/// ## MONITORING & RISK MANAGEMENT
///
/// Key metrics:
/// ```solidity
/// utilizationRate = totalBorrowed / totalReserves
/// avgHealthFactor = average across all positions
/// liquidationRisk = % of positions near liquidation
/// collateralConcentration = largest position / total collateral
/// ```
///
/// Alerts:
/// - Utilization > 90%: Reduce maxLTV, increase borrow rate
/// - AvgHealthFactor < 1.2: Increase liquidation bonus
/// - Coverage ratio drops: Auto-liquidate underwater positions
///
/// ## REFERENCES
///
/// - Specs: old/specs/LEVERAGE_TRADING.md (LP-collateralized design)
/// - Specs: old/specs/RESERVES_HYPOTHECATION.md (for hooks, not this module)
/// - Comparison: GMX (perpetuals), Contango (spot leverage), Aave (lending)
/// - Standards: ERC-3156 (flash loans for leverage loop)
///
abstract contract LendV1 is BaseV1, ILendV1 {
    // ========== STORAGE (ERC-7201 pattern, shared with Base) ==========

    // TODO: Add to IPoolV1.PoolStorage:
    // mapping(address token => LendConfig) lendConfigs;
    // mapping(address user => mapping(address token => Collateral)) collateral;
    // mapping(address user => mapping(address token => Debt)) debts;
    // mapping(address token => uint256) totalBorrowed;
    // mapping(address token => uint256) debtIndex;  // Interest accrual

    // ========== PHASE 1: BASIC LENDING ==========

    // TODO: Core lending functions
    // function borrow(address token, uint256 amount) external returns (uint256 debtAmount)
    // function repay(address token, uint256 amount) external returns (uint256 repaidAmount)
    // function supplyCollateral(address token, uint256 lpAmount) external
    // function withdrawCollateral(address token, uint256 lpAmount) external

    // ========== PHASE 2: LEVERAGE HELPERS ==========

    // TODO: Flash loan-based leverage
    // function openLeveragedPosition(address token, uint256 initialCapital, uint256 targetLeverage) external returns (uint256 positionId)
    // function closeLeveragedPosition(uint256 positionId) external returns (uint256 amountOut)
    // function adjustLeverage(uint256 positionId, uint256 newLeverage) external

    // ========== PHASE 3: LIQUIDATIONS ==========

    // TODO: Liquidation engine
    // function liquidate(address borrower, address token, uint256 debtToCover) external returns (uint256 collateralSeized)
    // function getHealthFactor(address user, address token) external view returns (uint256)
    // function getUserAccountData(address user, address token) external view returns (uint256 collateral, uint256 debt, uint256 healthFactor)

    // ========== PHASE 4: QUERIES & VIEWS ==========

    // TODO: Position and market queries
    // function getCollateralValue(address user, address token) external view returns (uint256)
    // function getMaxBorrow(address user, address token) external view returns (uint256)
    // function getUtilizationRate(address token) external view returns (uint256)
    // function getLiquidationPrice(address user, address token) external view returns (uint256)
}

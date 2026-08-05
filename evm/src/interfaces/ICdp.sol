// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

interface ICdp {
  enum Denom {
    USD,
    BTC,
    ETH,
    GOLD
  }

  struct CollateralConfig {
    address pool;
    address asset;
    address debtToken;
    Denom denom;
    uint16 ltvBps;
    uint16 ltBps;
    uint16 bonusBps;
    uint128 ceiling;
    bool hooked;
    bool enabled;
  }

  struct Position {
    uint128 collateral;
    uint128 debt;
  }

  struct ValueParams {
    uint16 hlBps;
    uint16 hoBps;
    uint256 basisWad;
  }

  event CollateralListed(address indexed lpToken, address pool, address debtToken, Denom denom);
  event CollateralUpdated(address indexed lpToken, uint16 ltvBps, uint16 ltBps, uint16 bonusBps);
  event CollateralEnabled(address indexed lpToken, bool enabled);
  event MintFrozen(address indexed debtToken, bool frozen);
  event CeilingSet(address indexed lpToken, uint128 ceiling);
  event SyntheticCeilingSet(address indexed debtToken, uint256 ceiling);
  event BadDebtRepaid(address indexed debtToken, address indexed payer, uint256 amount);
  event TimelockRequested(bytes32 indexed id, uint8 opType, address indexed target, uint48 eta);
  event TimelockCancelled(bytes32 indexed id, uint8 opType, address indexed target);
  event TimelockExecuted(bytes32 indexed id, uint8 opType, address indexed target);
  event Opened(address indexed owner, address indexed lpToken, uint256 coll, uint256 debt);
  event Adjusted(address indexed owner, address indexed lpToken, int256 collDelta, int256 debtDelta);
  event Repaid(address indexed owner, address indexed lpToken, uint256 amount);
  event Closed(address indexed owner, address indexed lpToken);
  event Liquidated(
    address indexed owner,
    address indexed lpToken,
    address indexed liquidator,
    uint256 debtRepaid,
    uint256 collToLiquidator,
    uint256 collToBackstop
  );
  event BadDebtRealized(
    address indexed debtToken, address indexed lpToken, address indexed owner, uint256 amount
  );

  error SameDenomRequired(Denom collDenom, Denom debtDenom);
  error CollateralDisabled(address lpToken);
  error HookedCollateralForbidden(address lpToken);
  error CollateralHalted(address lpToken);
  error CollateralWiped(address lpToken);
  error CapacityShortfall(address lpToken);
  error MarkUnavailable(address asset);
  error LtvExceeded(uint256 debt, uint256 maxDebt);
  error Healthy(uint256 healthFactorWad);
  error MintFrozenErr(address debtToken);
  error ZeroPosition();
  error BadParams();
  error CeilingExceeded(uint256 nextDebt, uint256 ceiling);
  error SyntheticCeilingExceeded(uint256 nextDebt, uint256 ceiling);
  error IncompleteValuation();
  error NoBackstop();
  error MustQueue();
  error NotTighten();
  error NoBadDebt();
  error ExhaustRequiresFullCover(uint256 debtToCover, uint256 maxRepay);
  error BootstrapSealed();
  error BootstrapOpen();
}

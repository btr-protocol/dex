# BTR AMM (Bayesian True Range AMM)

Adaptive multi-asset AMM with dynamic liquidity distribution, internal oracle system, and rebasing LP tokens.

## Core Features

- **Multi-asset hub-and-spoke** - All swaps route through base token (gas efficient)
- **Dynamic fees** - Multi-factor adaptive fees based on volatility, inventory, and divergence
- **Dual EMA oracle** - Fast and slow exponential moving averages for price and volatility
- **Rebasing LP tokens** - Auto-compounding ERC1155 LP tokens with liquidity index
- **Piecewise bonding curve** - Adaptive liquidity distribution with volatility-based breadth
- **Protocol fees** - Configurable fee split between LPs and treasury
- **Guardian controls** - Operational role for oracle updates, circuit breakers, and blacklisting
- **EIP-7201 storage** - Namespaced storage for upgradeability

## Documentation

### Core Specifications (specs/)
- **[ARCHITECTURE.md](specs/ARCHITECTURE.md)** - System architecture and design patterns
- **[ACCESS_CONTROL.md](specs/ACCESS_CONTROL.md)** - Role-based access control (Owner, Guardian, Treasury)
- **[ORACLE.md](specs/ORACLE.md)** - Dual EMA oracle system with three operating modes
- **[FEES.md](specs/FEES.md)** - Dynamic multi-factor fee calculation
- **[LP_TOKENS.md](specs/LP_TOKENS.md)** - ERC1155 rebasing LP token mechanics
- **[PIECEWISE_BONDING_CURVE.md](specs/PIECEWISE_BONDING_CURVE.md)** - Adaptive liquidity distribution
- **[B64_FLOAT.md](specs/B64_FLOAT.md)** - Custom 64-bit float format for efficient price storage
- **[HOOKS_SPECIFICATION.md](specs/HOOKS_SPECIFICATION.md)** - Runtime-updateable hooks system
- **[DARKPOOL_INTEGRATION.md](specs/DARKPOOL_INTEGRATION.md)** - zkSNARK privacy layer integration

### For Auditors
- **[AUDIT_READY_SUMMARY.md](AUDIT_READY_SUMMARY.md)** - Quick reference and audit checklist

## Quick Start

### Build
```shell
forge build
```

### Test
```shell
forge test
```

### Gas Analysis
```shell
forge snapshot
```

## Contract Architecture

```
src/
├── BAMM.sol                    Main pool contract with EIP-7201 storage
├── BAMMEvents.sol              Error and event definitions
├── interfaces/
│   ├── IBAMM.sol              Main pool interface
│   └── IOracle.sol            External oracle interface
└── libraries/
    ├── LibAccessControl.sol   Role-based access control
    ├── LibPricing.sol         Fee calculation and pricing
    ├── LibOracle.sol          Oracle data encoding/decoding
    ├── LibRescue.sol          Emergency asset recovery
    └── LibCast.sol            Safe type conversions
```

## Key Roles

### Owner
- Add/remove assets
- Pause/unpause pool
- Update base asset
- Configure circuit breakers
- Update fee parameters
- Remove addresses from blacklist

### Guardian (Operational)
- Update oracle prices for internal oracles
- Update liquidity profiles
- Trigger circuit breakers
- Freeze assets (emergency)
- Blacklist addresses

### Treasury
- Collect protocol fees

## Security

- **Reentrancy protection** - Solady ReentrancyGuard
- **Safe transfers** - Solady SafeTransferLib
- **Overflow protection** - Safe casting with revert
- **Access control** - Role-based with timelock for owner changes
- **Circuit breakers** - Asset freeze on excessive deviation
- **Blacklist system** - Compliance and malicious actor blocking

## Development

Built with [Foundry](https://book.getfoundry.sh/):
- **Forge** - Ethereum testing framework
- **Cast** - CLI for smart contract interaction
- **Anvil** - Local Ethereum node

## License

MIT

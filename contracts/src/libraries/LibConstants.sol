// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title LibConstants
/// @notice Shared constants for AIMM
library LibConstants {
    // ========== STORAGE LOCATIONS (ERC-7201) ==========

    /// @notice Base module storage location
    /// @dev ERC-7201: keccak256(abi.encode(uint256(keccak256("pool.storage.base.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant CORE_STORAGE_LOC =
        0x434e413f32fd441540d3f7cfa17fcdb1fe3e5bbbfbfad41a2edc933ab3d8f000;

    /// @notice Staking module storage location
    /// @dev ERC-7201: keccak256(abi.encode(uint256(keccak256("pool.storage.staking.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant STAKING_STORAGE_LOC =
        0xd170c8f7d48e01914fe8e334f1586822533b7239bd77d321e7e2463e4c2aa800;

    /// @notice Distributor module storage location
    /// @dev ERC-7201: keccak256(abi.encode(uint256(keccak256("pool.storage.distributor.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant DISTRIBUTOR_STORAGE_LOC =
        0x766bf381716de468c3786fcb5a0edf7a42b3746246e7a3aecdb4d0deb9a98400;

    /// @notice Oracle module storage location
    /// @dev ERC-7201: keccak256(abi.encode(uint256(keccak256("pool.storage.oracle.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant ORACLE_STORAGE_LOC =
        0x66393ec7629409eaa0af43f8ebdc702f7bad499202b191e5b6258c2b0cb09d00;

    /// @notice Rescue module storage location
    /// @dev ERC-7201: keccak256(abi.encode(uint256(keccak256("pool.storage.rescue.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant RESCUE_STORAGE_LOC =
        0x2cadec949cb31ebc38ad0d5c8be85faee8d3748c72806270425530d755894600;

    // ========== ADDRESS CONSTANTS ==========

    /// @notice Sentinel address for native asset (0xEeee...EEeE from EIP-7528)
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // ========== RISK FLAG BITS ==========

    uint16 internal constant FROZEN_BIT = 1 << 0;
    uint16 internal constant SWAP_ENABLED_BIT = 1 << 1;
    uint16 internal constant LIABILITY_SWAP_ENABLED_BIT = 1 << 2;
    uint16 internal constant DECAY_ENABLED_BIT = 1 << 3;
    uint16 internal constant FLASH_ENABLED_BIT = 1 << 4;
    uint16 internal constant FEE_ON_TRANSFER_BIT = 1 << 5;
    uint16 internal constant STAKEABLE_BIT = 1 << 6;
    uint16 internal constant BRIDGEABLE_BIT = 1 << 7;

    // ========== ORACLE MODE FLAGS ==========

    uint16 internal constant MODE_USE_INTERNAL = 1 << 0;
    uint16 internal constant MODE_USE_EXTERNAL = 1 << 1;
    uint16 internal constant MODE_ALLOW_FALLBACK = 1 << 2;

    // ========== HOOK FLAGS ==========

    uint32 internal constant HOOK_PRE_INIT = 1 << 0;
    uint32 internal constant HOOK_POST_INIT = 1 << 1;
    uint32 internal constant HOOK_PRE_DEPOSIT = 1 << 2;
    uint32 internal constant HOOK_POST_DEPOSIT = 1 << 3;
    uint32 internal constant HOOK_PRE_WITHDRAW = 1 << 4;
    uint32 internal constant HOOK_POST_WITHDRAW = 1 << 5;
    uint32 internal constant HOOK_PRE_SWAP = 1 << 6;
    uint32 internal constant HOOK_POST_SWAP = 1 << 7;
    uint32 internal constant HOOK_PRE_DONATE = 1 << 8;
    uint32 internal constant HOOK_POST_DONATE = 1 << 9;
    uint32 internal constant HOOK_PRE_FLASH_LOAN = 1 << 10;
    uint32 internal constant HOOK_POST_FLASH_LOAN = 1 << 11;

    // ========== FLOW GUARD ==========

    /// @notice Flow guard storage location
    /// @dev ERC-7201: keccak256(abi.encode(uint256(keccak256("pool.storage.flowguard.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant FLOW_GUARD_STORAGE_LOC =
        0x8a7c9f2e5b3d1a4c6e8f0d2b4a6c8e0f2d4b6a8c0e2f4d6b8a0c2e4f6d8b0a00;

    /// @notice Default flow cooldown (15 seconds - protects against JIT across all chains)
    uint16 internal constant DEFAULT_FLOW_COOLDOWN = 15;

    // ========== TIMELOCK DELAYS ==========

    uint48 internal constant CRITICAL_TIMELOCK = 7 days; // Critical risk eg. base token migration
    uint48 internal constant HIGH_TIMELOCK = 3 days; // High risk eg. ownership transfer
    uint48 internal constant BASE_TIMELOCK = 2 days; // Medium risk eg. oracle change
    uint48 internal constant LOW_TIMELOCK = 1 days; // Low risk eg. add asset, update fees
    uint48 internal constant UPGRADE_TIMELOCK = 7 days; // UUPS contract upgrades
    uint48 internal constant GRACE_PERIOD = 7 days; // H-01 FIX: Execution window after timelock expires

    // ========== TIMELOCK IDS (Precomputed) ==========

    /// @notice keccak256("OWNERSHIP_TRANSFER")
    bytes32 internal constant TIMELOCK_ID_OWNERSHIP = 0xb23d8fa2f62c8a954db45521d1249908693b29ffd3d2dab6348898c4198996b2;

    /// @notice keccak256("MODULE_UPDATE")
    bytes32 internal constant TIMELOCK_ID_MODULE = 0x9711820581f0923b8ce766818550d8de681ea05c98d406ede2cb99f547946483;

    /// @notice keccak256("BASE_MIGRATION")
    bytes32 internal constant TIMELOCK_ID_BASE_MIGRATION = 0x481ddbaf0bd6c8dbe0481df731f218348c8e6a7d7c2688a8461149748efe26b2;

    /// @notice For oracle updates, use: keccak256(abi.encodePacked("ORACLE_UPDATE", token))

    /// @notice keccak256("STAKING_CONFIG")
    bytes32 internal constant TIMELOCK_ID_STAKING = 0x31d5d9f75ffb4c90ed2cfe65e740a9e01a63f5c56e0230dcfebcfa5d5d4dabd2;

    /// @notice keccak256("DISTRIBUTION_PARAMS")
    bytes32 internal constant TIMELOCK_ID_DISTRIBUTION = 0x96c0232a810ff94a1df4a4c89c2aa471f0a4ca4008e0c532f71f233529af9490;

    /// @notice keccak256("FEE_PARAMS")
    bytes32 internal constant TIMELOCK_ID_FEE_PARAMS = 0x8b78c6d8bcad3b5cb6b93b4e61d52c5a7b9e8f4c2d1a0e3f6b5c4d8a7e9f1c2d;

    /// @dev keccak256("UPDATE_BRIDGE")
    bytes32 internal constant TIMELOCK_ID_BRIDGE = 0x183169b8f82d189401b48b883d17402cedfd43bd2085165ddeb902945cc01676;

    /// @dev keccak256("UPDATE_TREASURY")
    bytes32 internal constant TIMELOCK_ID_TREASURY = 0x7c5d1f6de8c0b8f9c4a6d5b3e2a1c9f8d7e6b5a4c3d2e1f0a9b8c7d6e5f4a3b2;

    // ========== PRECISION CONSTANTS ==========

    /// @notice 18-decimal fixed-point (EIP-1706 standard)
    /// @dev Used for: coverage ratios, prices, decay rates, exponentiation
    ///      - Coverage: 1e18 = 100%, 0.5e18 = 50%
    ///      - Prices: 1e18 = 1 unit of base currency (e.g., $1 for USD-pegged)
    ///      - Decay: WAD per second (e.g., WAD/31536000 ≈ 100% per year)
    uint256 constant WAD = 1e18;

    /// @notice 0.0001% precision (1 unit = 0.0001% = 0.001 bps)
    /// @dev Used for: fees, spreads, volatility, oracle offsets
    ///      - Fees/spreads: 5,000 = 0.5%, 100 = 0.01%
    ///      - Volatility: 1,000,000 = 1%, 10,000,000 = 10%
    ///      - Oracle offsets: 100,000 = 10% deviation from TWAP
    ///      - Dispersion (min/max): 0.0001% units
    ///      - decayStartRatioBps: 0.0001% units (e.g., 980000 = 98%)
    /// NOTE: Coverage bounds (coverageMin/Max) and multipliers (gamma/vega/lambda) use C.BPS (0.01% units) instead
    uint256 constant PBPS = 1_000_000;

    /// @notice Half of PBPS for 50/50 fee splits
    /// @dev fee = (amount * spread) / (2 * PBPS) = (amount * spread) / HALF_PBPS
    uint256 constant HALF_PBPS = 500_000;

    /// @notice One percent in PBPS units
    /// @dev Used for percentage calculations
    uint256 constant ONE_PCT_PBPS = 10_000;

    /// @notice Hundred percent in PBPS units (legacy, use C.BPS for uint16 params)
    /// @dev DEPRECATED: gamma/vega/lambda now use C.BPS scale (10000 = 100%)
    uint256 constant HUNDRED_PCT_PBPS = 100_000;

    /// @notice Standard BPS (0.01% per unit, 10000 = 100%)
    /// @dev Used for uint16 percentage parameters that must fit in 16 bits:
    ///      - coverageMin/Max (max 655%)
    ///      - gamma/vega/lambda sensitivity multipliers (10000 = 1.0x)
    ///      - depth/position x-axis (0-10000 = 0-100%)
    ///      Different from PBPS (0.0001% per unit) which is for internal precision
    ///      Required because uint16 max (65,535) can't represent 100% at PBPS scale (1,000,000)
    uint256 constant BPS = 10_000;

    // ========== GREEK VARIABLE REFERENCE (for auditors) ==========
    /*
    | Symbol | Code Variable | BPS Value | Meaning |
    |--------|---------------|-----------|---------|
    | ψ (psi) | inventorySkew | - | Inventory skew, [-100, +100] |
    | π (pi)  | progress      | - | Progress toward boundary, [0,1] |
    | γ (gamma) | gamma       | 10,000 | 100% = 1.0x sensitivity (0.01% BPS) |
    | ν (nu)   | vega        | 10,000 | 100% = 1.0x sensitivity (0.01% BPS) |
    | λ (lambda)| lambda      | 10,000 | 100% = 1.0x sensitivity (0.01% BPS) |
    | η (eta)   | haircutSuppressor | 10,000 | 100% = p=2 exponent (0.01% BPS) |
    | σ (sigma) | volatility  | 1,000,000 | 1% volatility (PBPS) |
    | Δ (Delta) | delta       | - | Oracle deviation (PBPS units) |
    | κ (kappa) | dispersion  | - | Liquidity dispersion (PBPS units) |

    Formula scaling examples:
    - Coverage: c = (R * WAD) / L
    - Spread: S = 100 + (σ × ν) / 100  (result in PBPS, ν in BPS so divide by 100)
    - Skew: ψ = sign × γ × π / 100  (γ in BPS as %, divide by 100 for multiplier)
    - Fee: φ = (x × S) / (2 × PBPS)
    */
}

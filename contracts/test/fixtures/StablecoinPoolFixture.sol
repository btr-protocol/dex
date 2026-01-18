// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolV1} from "../../src/interfaces/IPoolV1.sol";
import {ICoreV1} from "../../src/interfaces/modules/ICoreV1.sol";
import {IAdminV1} from "../../src/interfaces/modules/IAdminV1.sol";
import {IOracleV1} from "../../src/interfaces/IOracleV1.sol";

/// @dev Minimal ERC20 interface for testing
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

import {PoolProxyV1} from "../../src/PoolProxyV1.sol";
import {ExchangeV1} from "../../src/modules/ExchangeV1.sol";
import {LiquidityV1} from "../../src/modules/LiquidityV1.sol";
import {AdminV1} from "../../src/modules/AdminV1.sol";
import {BaseV1} from "../../src/modules/BaseV1.sol";
import {InternalOracleV1} from "../../src/modules/InternalOracleV1.sol";
import {LibConstants as C} from "../../src/libraries/LibConstants.sol";
import {LibMaths} from "../../src/libraries/LibMaths.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title StablecoinPoolFixture
/// @notice Base fixture for mainnet fork tests with stablecoin pool
/// @dev Uses real mainnet stablecoins: USDC (anchor), USDT, USDS, USDE, PYUSD
abstract contract StablecoinPoolFixture is Test {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET TOKEN ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant PYUSD = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Token decimals
    uint8 constant USDC_DECIMALS = 6;
    uint8 constant USDT_DECIMALS = 6;
    uint8 constant USDS_DECIMALS = 18;
    uint8 constant USDE_DECIMALS = 18;
    uint8 constant PYUSD_DECIMALS = 6;

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST ACCOUNTS
    // ═══════════════════════════════════════════════════════════════════════════

    address owner;
    address treasury;
    address user1;
    address user2;
    address user3;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONTRACTS
    // ═══════════════════════════════════════════════════════════════════════════

    PoolProxyV1 pool;
    ExchangeV1 exchangeModule;
    LiquidityV1 liquidityModule;
    AdminV1 adminModule;
    InternalOracleV1 oracleModule;

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════

    function setUp() public virtual {
        // Create test accounts
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        vm.startPrank(owner);

        // Deploy modules
        exchangeModule = new ExchangeV1();
        liquidityModule = new LiquidityV1();
        adminModule = new AdminV1();
        oracleModule = new InternalOracleV1();

        // Deploy pool proxy
        pool = new PoolProxyV1();

        // Initialize pool with USDC as base token (anchor)
        uint8[29] memory feePad;
        IPoolV1.FeeParams memory feeParams = IPoolV1.FeeParams({
            protoShare: 25,      // 25% protocol share
            flashFeeBps: 5,      // 0.0005% flash fee
            _pad: feePad
        });

        pool.initialize(owner, USDC, WETH, feeParams);

        // Register module selectors
        _registerModules();

        // Configure base token (USDC)
        _addAsset(USDC, USDC_DECIMALS, address(0)); // Root token has no anchor

        vm.stopPrank();

        // Deal tokens to test users
        _fundTestUsers();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MODULE REGISTRATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _registerModules() internal {
        // Exchange module selectors (swap + views)
        bytes4[] memory exchangeSelectors = new bytes4[](10);
        exchangeSelectors[0] = ICoreV1.swap.selector;
        exchangeSelectors[1] = ICoreV1.getSwapQuote.selector;
        exchangeSelectors[2] = ICoreV1.owner.selector;
        exchangeSelectors[3] = ICoreV1.baseToken.selector;
        exchangeSelectors[4] = ICoreV1.wnative.selector;
        exchangeSelectors[5] = ICoreV1.getAsset.selector;
        exchangeSelectors[6] = ICoreV1.getLPBalance.selector;
        exchangeSelectors[7] = ICoreV1.getProtocolFees.selector;
        exchangeSelectors[8] = ICoreV1.getCoverageRatio.selector;
        exchangeSelectors[9] = ICoreV1.getMidPrice.selector;
        _updateModuleDirect(address(exchangeModule), exchangeSelectors);

        // Liquidity module selectors (deposit/withdraw/donate)
        bytes4[] memory liquiditySelectors = new bytes4[](5);
        liquiditySelectors[0] = ICoreV1.deposit.selector;
        liquiditySelectors[1] = ICoreV1.withdraw.selector;
        liquiditySelectors[2] = ICoreV1.withdrawTo.selector;
        liquiditySelectors[3] = ICoreV1.swapLiability.selector;
        liquiditySelectors[4] = ICoreV1.donate.selector;
        _updateModuleDirect(address(liquidityModule), liquiditySelectors);

        // Admin module selectors (from IAdminV1)
        bytes4[] memory adminSelectors = new bytes4[](20);
        adminSelectors[0] = IAdminV1.freezeAsset.selector;
        adminSelectors[1] = IAdminV1.unfreezeAsset.selector;
        adminSelectors[2] = IAdminV1.requestAddAsset.selector;
        adminSelectors[3] = IAdminV1.executeAddAsset.selector;
        adminSelectors[4] = IAdminV1.requestUpdateRiskConfig.selector;
        adminSelectors[5] = IAdminV1.executeUpdateRiskConfig.selector;
        adminSelectors[6] = IAdminV1.requestUpdateFeeParams.selector;
        adminSelectors[7] = IAdminV1.executeUpdateFeeParams.selector;
        adminSelectors[8] = IAdminV1.collectProtocolFees.selector;
        adminSelectors[9] = IAdminV1.requestOwnershipTransfer.selector;
        adminSelectors[10] = IAdminV1.executeOwnershipTransfer.selector;
        adminSelectors[11] = IAdminV1.requestBridgeUpdate.selector;
        adminSelectors[12] = IAdminV1.executeBridgeUpdate.selector;
        adminSelectors[13] = IAdminV1.requestTreasuryUpdate.selector;
        adminSelectors[14] = IAdminV1.executeTreasuryUpdate.selector;
        adminSelectors[15] = IAdminV1.requestModuleUpdate.selector;
        adminSelectors[16] = IAdminV1.executeModuleUpdate.selector;
        adminSelectors[17] = IAdminV1.cancelTimelock.selector;
        adminSelectors[18] = IAdminV1.getModule.selector;
        // setAnchor, getFeedConfig, getRiskConfig are in CoreV1 or AdminV1 but need manual selector
        adminSelectors[19] = bytes4(keccak256("setAnchor(address,address)"));

        _updateModuleDirect(address(adminModule), adminSelectors);

        // Add view functions that are in IPoolV1 directly but routed to exchange
        bytes4[] memory viewSelectors = new bytes4[](2);
        viewSelectors[0] = IPoolV1.getFeedConfig.selector;
        viewSelectors[1] = IPoolV1.getRiskConfig.selector;
        _updateModuleDirect(address(exchangeModule), viewSelectors);

        // Oracle module selectors (computed manually since InternalOracleV1 has different signatures)
        // InternalOracleV1 functions:
        //   getFeed(address) -> (FeedData)
        //   isFeedFresh(address,uint32) -> (bool)
        //   isFeedFresh(address) -> (bool)
        //   getFastTWAP(address) -> (uint64)
        //   updateFeed(address,uint64,uint8,uint32,uint32) [onlyOwner] - accDecimals param added
        //   pushFeed(address,uint64,uint32) [always reverts - not for internal oracle]
        //   pushFeedInternal(address,address,uint64,uint64) [internal use only]
        bytes4[] memory oracleSelectors = new bytes4[](6);
        oracleSelectors[0] = bytes4(keccak256("getFeed(address)"));
        oracleSelectors[1] = bytes4(keccak256("updateFeed(address,uint64,uint8,uint32,uint32)"));
        oracleSelectors[2] = bytes4(keccak256("pushFeedInternal(address,address,uint64,uint64)"));
        oracleSelectors[3] = bytes4(keccak256("isFeedFresh(address,uint32)"));
        oracleSelectors[4] = bytes4(keccak256("isFeedFresh(address)"));
        oracleSelectors[5] = bytes4(keccak256("getFastTWAP(address)"));

        _updateModuleDirect(address(oracleModule), oracleSelectors);
    }

    /// @dev Direct module update bypassing timelock for test setup
    /// @dev Uses vm.store to write to the proxy's storage
    function _updateModuleDirect(address impl, bytes4[] memory selectors) internal {
        // PoolStorage layout from base slot (CORE_STORAGE_LOC):
        // Slot +0: owner (address)
        // Slot +1: baseToken (address)
        // Slot +2: wnative (address)
        // Slot +3: bridge (address)
        // Slot +4: treasury (address, 20 bytes) + initialized (bool, 1 byte) = PACKED in same slot
        // Slot +5: assets mapping base
        // Slot +6: oracleConfigs mapping base
        // Slot +7: riskConfigs mapping base
        // Slot +8: profiles mapping base
        // Slot +9: hooks mapping base
        // Slot +10: hookFlags mapping base
        // Slot +11: lpBalances mapping base
        // Slot +12: protocolFees mapping base
        // Slot +13: modules mapping base <-- THIS IS WHAT WE NEED

        // For a mapping(bytes4 => address), the slot for key k is:
        // keccak256(abi.encode(k, mappingSlot))
        // where mappingSlot = base + 13 (NOT 14, because treasury+initialized pack together)

        uint256 baseSlot = uint256(C.CORE_STORAGE_LOC);
        uint256 modulesSlot = baseSlot + 13;  // Was 14, but treasury+initialized pack!

        for (uint256 i = 0; i < selectors.length; i++) {
            // For mapping(bytes4 => address), Solidity pads bytes4 to bytes32 (left-aligned/high bits)
            bytes32 slot = keccak256(abi.encode(selectors[i], modulesSlot));
            vm.store(address(pool), slot, bytes32(uint256(uint160(impl))));
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ASSET CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _addAsset(address token, uint8 decimals, address anchor) internal {
        // Oracle config - use internal oracle
        // accDecimals=6 for stablecoins (optimal range for ~$1 prices)
        uint8[13] memory oraclePad;
        IPoolV1.OracleConfig memory oracleCfg = IPoolV1.OracleConfig({
            primary: address(pool), // Internal oracle
            secondary: address(0),
            feedId: bytes32(0),
            modeFlags: 0,
            accDecimals: 6,  // Stablecoin-optimized (max acc ~4.5e72 price-seconds)
            _pad: oraclePad
        });

        // Risk config - stablecoin parameters
        uint8[18] memory riskPad;
        IPoolV1.RiskConfig memory riskCfg = IPoolV1.RiskConfig({
            decayStartRatioBps: 9800,    // 98% coverage threshold for decay
            coverageFloor: 5000,          // 50% critical floor
            decaySlope: 31709791,         // ~1% per year
            depthAmplifier: 10000,        // 1% depth amplification
            flags: C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT,
            _pad: riskPad
        });

        // Liquidity profile - uniform for stablecoins
        IPoolV1.LiquidityProfile memory profile = _uniformProfile();

        // Request and execute asset addition
        IPoolV1(address(pool)).requestAddAsset(
            token,
            oracleCfg,
            riskCfg,
            profile,
            10,           // 0.001% min fee
            decimals,
            _priceB64(1, decimals), // $1.00 initial price
            10000,        // Initial fast vol EMA
            10000         // Initial slow vol EMA
        );

        // Warp past timelock
        vm.warp(block.timestamp + C.LOW_TIMELOCK + 1);

        IPoolV1(address(pool)).executeAddAsset(token);

        // Set anchor if not root
        if (anchor != address(0)) {
            IAdminV1(address(pool)).setAnchor(token, anchor);
        }
    }

    function _uniformProfile() internal pure returns (IPoolV1.LiquidityProfile memory) {
        uint8[16] memory weights;
        int8[17] memory knots;

        // Uniform distribution: 4 segments of 50 each (total 200)
        weights[0] = 50;
        weights[1] = 50;
        weights[2] = 50;
        weights[3] = 50;

        // Knots for 4 segments (5 boundary points): -50, -25, 0, 25, 50 (max - min = 100)
        knots[0] = -50;  // Start knot
        knots[1] = -25;  // End of segment 0
        knots[2] = 0;    // End of segment 1
        knots[3] = 25;   // End of segment 2
        knots[4] = 50;   // End of segment 3

        return IPoolV1.LiquidityProfile({
            weights: weights,
            knots: knots
        });
    }

    function _priceB64(uint256 price, uint8 decimals) internal pure returns (uint64) {
        // Encode price in B64 format using the proper LibMaths.encodeB64
        // For $1.00 stablecoin with 6 decimals: raw value = 1 * 10^6 = 1000000
        uint256 scaledPrice = price * (10 ** decimals);
        return LibMaths.encodeB64(scaledPrice, decimals);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOKEN FUNDING
    // ═══════════════════════════════════════════════════════════════════════════

    function _fundTestUsers() internal {
        // Fund users with stablecoins using deal
        uint256 usdcAmount = 1_000_000 * 10**USDC_DECIMALS; // 1M USDC
        uint256 usdtAmount = 1_000_000 * 10**USDT_DECIMALS; // 1M USDT
        uint256 usdsAmount = 1_000_000 * 10**USDS_DECIMALS; // 1M USDS
        uint256 usdeAmount = 1_000_000 * 10**USDE_DECIMALS; // 1M USDE
        uint256 pyusdAmount = 1_000_000 * 10**PYUSD_DECIMALS; // 1M PYUSD

        address[3] memory users = [user1, user2, user3];

        for (uint256 i = 0; i < users.length; i++) {
            deal(USDC, users[i], usdcAmount);
            deal(USDT, users[i], usdtAmount);
            deal(USDS, users[i], usdsAmount);
            deal(USDE, users[i], usdeAmount);
            deal(PYUSD, users[i], pyusdAmount);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Add all stablecoins to the pool (call after setUp)
    function _addAllStablecoins() internal {
        vm.startPrank(owner);

        // Add USDT anchored to USDC
        _addAsset(USDT, USDT_DECIMALS, USDC);

        // Add USDS anchored to USDC
        _addAsset(USDS, USDS_DECIMALS, USDC);

        // Add USDE anchored to USDC
        _addAsset(USDE, USDE_DECIMALS, USDC);

        // Add PYUSD anchored to USDC
        _addAsset(PYUSD, PYUSD_DECIMALS, USDC);

        vm.stopPrank();
    }

    /// @notice Deposit liquidity for a token
    function _deposit(address user, address token, uint256 amount) internal returns (uint256 lpAmount) {
        vm.startPrank(user);
        // Use SafeTransferLib.safeApprove for USDT compatibility (no return value)
        SafeTransferLib.safeApprove(token, address(pool), amount);
        IPoolV1.DepositResult memory result = IPoolV1(address(pool)).deposit(token, amount);
        vm.stopPrank();
        return result.lpAmount;
    }

    /// @notice Withdraw liquidity
    function _withdraw(address user, address token, uint256 lpAmount) internal returns (uint256 amountOut) {
        vm.startPrank(user);
        IPoolV1.WithdrawResult memory result = IPoolV1(address(pool)).withdraw(token, lpAmount, 0);
        vm.stopPrank();
        return result.amountOut;
    }

    /// @notice Perform a swap
    function _swap(
        address user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        vm.startPrank(user);
        // Use SafeTransferLib.safeApprove for USDT compatibility (no return value)
        SafeTransferLib.safeApprove(tokenIn, address(pool), amountIn);
        amountOut = IPoolV1(address(pool)).swap(tokenIn, tokenOut, amountIn, minAmountOut, user);
        vm.stopPrank();
    }

    /// @notice Get swap quote
    function _getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (IPoolV1.SwapQuote memory) {
        return IPoolV1(address(pool)).getSwapQuote(tokenIn, tokenOut, amountIn);
    }

    /// @notice Seed initial liquidity for all stablecoins
    function _seedLiquidity(uint256 amountPerToken) internal {
        // Deposit initial liquidity from user1
        _deposit(user1, USDC, amountPerToken * 10**USDC_DECIMALS / 1e18);
        _deposit(user1, USDT, amountPerToken * 10**USDT_DECIMALS / 1e18);
        _deposit(user1, USDS, amountPerToken);
        _deposit(user1, USDE, amountPerToken);
        _deposit(user1, PYUSD, amountPerToken * 10**PYUSD_DECIMALS / 1e18);
    }
}

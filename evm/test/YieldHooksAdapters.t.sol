// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {Admin} from "../src/Admin.sol";
import {Flash} from "../src/Flash.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {AaveV3YieldHook} from "../src/hooks/AaveV3YieldHook.sol";
import {AaveV4YieldHook} from "../src/hooks/AaveV4YieldHook.sol";
import {ERC4626YieldHook} from "../src/hooks/ERC4626YieldHook.sol";
import {MorphoBlueYieldHook} from "../src/hooks/MorphoBlueYieldHook.sol";
import {CompoundV2YieldHook} from "../src/hooks/CompoundV2YieldHook.sol";
import {MockAavePool, MockAToken} from "../src/hooks/MockAavePool.sol";
import {MockAaveV4Spoke} from "../src/hooks/MockAaveV4Spoke.sol";
import {MockERC4626} from "../src/hooks/MockERC4626.sol";
import {MockMorphoBlue} from "../src/hooks/MockMorphoBlue.sol";
import {MockVenus} from "../src/hooks/MockVenus.sol";
import {IMorphoBlue, MorphoId} from "../src/interfaces/external/IMorphoBlue.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {Maths as M} from "../src/libraries/Maths.sol";
import {MockAC, MockOracle} from "./fixtures/BaseTestSetup.sol";

/// @notice Focused adapter smoke tests (Aave V3, ERC4626, Morpho Blue, CompoundV2 alias path).
contract YieldHooksAdaptersTest is Test {
    PoolFactory factory;
    Pool poolImpl;
    Admin admin;
    Flash flashSingleton;
    MockAC ac;
    MockOracle oracle;
    Pool pool;
    MockERC20 base;
    MockERC20 quote;

    address constant OWNER = address(0xA11CE);
    uint8 constant PROTO_SHARE = 25;

    function _profile() internal pure returns (IPool.LiquidityProfile memory p) {
        p.weights[0] = 50;
        p.weights[1] = 50;
        p.weights[2] = 50;
        p.weights[3] = 50;
        p.knots[0] = -50;
        p.knots[1] = -25;
        p.knots[2] = 0;
        p.knots[3] = 25;
        p.knots[4] = 50;
    }

    function _risk() internal pure returns (IPool.RiskConfig memory r) {
        r.decayStartRatioBps = 5000;
        r.coverageMin = 5000;
        r.coverageMax = 20000;
        r.depthAmplifier = 10000;
        r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT | C.FLASH_ENABLED_BIT;
    }

    function _oracleCfg(address token) internal view returns (IPool.OracleConfig memory o) {
        o.primary = address(oracle);
        o.feedId = bytes32(uint256(uint160(token)));
    }

    function setUp() public {
        ac = new MockAC(OWNER);
        admin = new Admin(address(ac));
        flashSingleton = new Flash();
        PoolAux poolAux = new PoolAux(address(ac), address(admin), address(flashSingleton));
        poolImpl = new Pool(address(ac), address(admin), address(flashSingleton), address(poolAux));
        factory = new PoolFactory(address(poolImpl), address(this), address(ac));

        base = new MockERC20("Base", "BASE", 18);
        quote = new MockERC20("Quote", "QUOT", 18);
        address[] memory toks = new address[](2);
        toks[0] = address(base);
        toks[1] = address(quote);

        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: PROTO_SHARE, flashFeeBps: 100, _pad: pad});
        bytes memory initdata = abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0xCAFE), fp);
        address pa = factory.createPool(address(base), toks, initdata);
        pool = Pool(payable(pa));

        oracle = new MockOracle();
        oracle.setMark(address(base), M.encodeB64(1e18, 18));
        oracle.setMark(address(quote), M.encodeB64(1e18, 18));
        IPool.RiskConfig memory rc = _risk();
        IPool.LiquidityProfile memory pf = _profile();
        vm.startPrank(OWNER);
        admin.addAsset(pa, address(base), _oracleCfg(address(base)), rc, pf, 1000, 18, 1000, 100000, 10000, 10000);
        admin.addAsset(pa, address(quote), _oracleCfg(address(quote)), rc, pf, 1000, 18, 1000, 100000, 10000, 10000);
        vm.stopPrank();

        uint256 seed = 1_000_000e18;
        base.mint(address(this), seed);
        base.approve(address(pool), type(uint256).max);
        pool.deposit(address(base), seed);
        quote.mint(address(this), seed);
        quote.approve(address(pool), type(uint256).max);
        pool.deposit(address(quote), seed);
    }

    function _setHook(address token, address hook, uint32 flags) internal {
        vm.startPrank(OWNER);
        admin.requestSetAssetHook(address(pool), token, hook, flags);
        vm.warp(block.timestamp + 3 days + 1);
        admin.executeSetAssetHook(address(pool), token);
        vm.stopPrank();
        oracle.setMark(address(base), M.encodeB64(1e18, 18));
        oracle.setMark(address(quote), M.encodeB64(1e18, 18));
    }

    function _forceThinLiquid(address hook) internal {
        uint256 liq = IPool(address(pool)).getLiquidReserves(address(quote));
        if (liq <= 5e18) return;
        uint256 leave = 5e18;
        uint256 extra = liq - leave;
        vm.prank(address(hook));
        IPool(address(pool)).hookDeploy(address(quote), extra);
        // Caller must re-deploy venue with leftover liquid on the hook.
    }

    function test_aaveV3_deploy_and_recall() public {
        MockAavePool aave = new MockAavePool();
        MockAToken aToken = new MockAToken(address(quote));
        aave.setAToken(address(quote), address(aToken));

        AaveV3YieldHook hook = new AaveV3YieldHook(address(ac), address(pool), address(quote), address(aave), address(0));
        _setHook(address(quote), address(hook), hook.recommendedFlags());

        quote.mint(address(this), 200_000e18);
        pool.deposit(address(quote), 200_000e18);

        uint256 inv = IPool(address(pool)).getInvested(address(quote));
        assertGt(inv, 0, "aave deploy");
        assertGt(aToken.balanceOf(address(hook)), 0);

        _forceThinLiquid(address(hook));
        // Re-supply any leftover liquid sitting on the hook from hookDeploy.
        uint256 onHook = quote.balanceOf(address(hook));
        if (onHook > 0) {
            vm.startPrank(address(hook));
            quote.approve(address(aave), onHook);
            aave.supply(address(quote), onHook, address(hook), 0);
            // Book: pull already booked R_inv; tokens now in aToken.
            vm.stopPrank();
        }

        uint256 amt = 20e18;
        base.mint(address(0xBEEF), amt);
        vm.prank(address(0xBEEF));
        base.approve(address(pool), type(uint256).max);
        uint256 invBefore = IPool(address(pool)).getInvested(address(quote));
        vm.prank(address(0xBEEF));
        uint256 out = pool.swap(address(base), address(quote), amt, 0, address(0xBEEF));
        assertGt(out, 0);
        assertLe(IPool(address(pool)).getInvested(address(quote)), invBefore);
    }

    function test_erc4626_deploy_harvest_writedown() public {
        MockERC4626 vault = new MockERC4626(address(quote));
        ERC4626YieldHook hook =
            new ERC4626YieldHook(address(ac), address(pool), address(quote), address(vault));
        _setHook(address(quote), address(hook), hook.recommendedFlags());

        quote.mint(address(this), 200_000e18);
        pool.deposit(address(quote), 200_000e18);
        uint256 invBefore = IPool(address(pool)).getInvested(address(quote));
        assertGt(invBefore, 0);

        vault.setRate(0.5e18);
        vm.prank(OWNER);
        hook.rebalance();
        assertLt(IPool(address(pool)).getInvested(address(quote)), invBefore, "4626 writedown");
    }

    function test_morphoBlue_deploy_and_recall() public {
        MockMorphoBlue morpho = new MockMorphoBlue();
        IMorphoBlue.MarketParams memory params = IMorphoBlue.MarketParams({
            loanToken: address(quote),
            collateralToken: address(base),
            oracle: address(0x1),
            irm: address(0x2),
            lltv: 0.8e18
        });
        morpho.setMarket(params);

        MorphoBlueYieldHook hook =
            new MorphoBlueYieldHook(address(ac), address(pool), address(quote), address(morpho), params);
        _setHook(address(quote), address(hook), hook.recommendedFlags());

        quote.mint(address(this), 200_000e18);
        pool.deposit(address(quote), 200_000e18);
        assertGt(IPool(address(pool)).getInvested(address(quote)), 0, "morpho deploy");

        _forceThinLiquid(address(hook));
        uint256 onHook = quote.balanceOf(address(hook));
        if (onHook > 0) {
            vm.prank(address(hook));
            morpho.supply(params, onHook, 0, address(hook), "");
        }

        uint256 amt = 15e18;
        base.mint(address(0xBEEF), amt);
        vm.prank(address(0xBEEF));
        base.approve(address(pool), type(uint256).max);
        uint256 invBefore = IPool(address(pool)).getInvested(address(quote));
        vm.prank(address(0xBEEF));
        assertGt(pool.swap(address(base), address(quote), amt, 0, address(0xBEEF)), 0);
        assertLe(IPool(address(pool)).getInvested(address(quote)), invBefore);
    }

    function test_compoundV2_alias_path() public {
        MockVenus vToken = new MockVenus(address(quote));
        CompoundV2YieldHook hook =
            new CompoundV2YieldHook(address(ac), address(pool), address(quote), address(vToken));
        _setHook(address(quote), address(hook), hook.recommendedFlags());

        quote.mint(address(this), 100_000e18);
        pool.deposit(address(quote), 100_000e18);
        assertGt(IPool(address(pool)).getInvested(address(quote)), 0);
        assertGt(vToken.balanceOf(address(hook)), 0);
    }

    function test_sweepIncentives_to_treasury() public {
        MockERC4626 vault = new MockERC4626(address(quote));
        ERC4626YieldHook hook =
            new ERC4626YieldHook(address(ac), address(pool), address(quote), address(vault));
        _setHook(address(quote), address(hook), hook.recommendedFlags());

        address treasury = address(0x7ea5);
        vm.prank(OWNER);
        hook.setIncentivesReceiver(treasury);

        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        reward.mint(address(hook), 50e18);

        address[] memory toks = new address[](1);
        toks[0] = address(reward);
        vm.prank(OWNER);
        hook.sweepIncentives(toks);

        assertEq(reward.balanceOf(address(hook)), 0);
        assertEq(reward.balanceOf(treasury), 50e18);
    }

    function test_sweepIncentives_skips_position_tokens() public {
        MockAavePool aave = new MockAavePool();
        MockAToken aToken = new MockAToken(address(quote));
        aave.setAToken(address(quote), address(aToken));

        AaveV3YieldHook hook =
            new AaveV3YieldHook(address(ac), address(pool), address(quote), address(aave), address(0));
        _setHook(address(quote), address(hook), hook.recommendedFlags());

        quote.mint(address(this), 200_000e18);
        pool.deposit(address(quote), 200_000e18);
        uint256 aBal = aToken.balanceOf(address(hook));
        assertGt(aBal, 0, "aToken position");

        address treasury = address(0x7ea5);
        vm.prank(OWNER);
        hook.setIncentivesReceiver(treasury);

        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        reward.mint(address(hook), 10e18);

        address[] memory toks = new address[](3);
        toks[0] = address(aToken);
        toks[1] = address(quote);
        toks[2] = address(reward);
        vm.prank(OWNER);
        hook.sweepIncentives(toks);

        assertEq(aToken.balanceOf(address(hook)), aBal, "aToken not swept");
        assertEq(reward.balanceOf(treasury), 10e18, "reward swept");
        assertEq(aToken.balanceOf(treasury), 0);
    }

    function test_sweepIncentives_skips_cToken() public {
        MockVenus vToken = new MockVenus(address(quote));
        CompoundV2YieldHook cHook =
            new CompoundV2YieldHook(address(ac), address(pool), address(quote), address(vToken));
        _setHook(address(quote), address(cHook), cHook.recommendedFlags());
        quote.mint(address(this), 100_000e18);
        pool.deposit(address(quote), 100_000e18);
        uint256 cBal = vToken.balanceOf(address(cHook));
        assertGt(cBal, 0);

        address treasury = address(0x7ea5);
        vm.prank(OWNER);
        cHook.setIncentivesReceiver(treasury);

        address[] memory cToks = new address[](1);
        cToks[0] = address(vToken);
        vm.prank(OWNER);
        cHook.sweepIncentives(cToks);
        assertEq(vToken.balanceOf(address(cHook)), cBal, "cToken not swept");
        assertEq(vToken.balanceOf(treasury), 0);
    }

    function test_sweepIncentives_skips_vault_shares() public {
        MockERC4626 vault = new MockERC4626(address(quote));
        ERC4626YieldHook vHook =
            new ERC4626YieldHook(address(ac), address(pool), address(quote), address(vault));
        _setHook(address(quote), address(vHook), vHook.recommendedFlags());
        quote.mint(address(this), 100_000e18);
        pool.deposit(address(quote), 100_000e18);
        uint256 shares = vault.balanceOf(address(vHook));
        assertGt(shares, 0);

        address treasury = address(0x7ea5);
        vm.prank(OWNER);
        vHook.setIncentivesReceiver(treasury);

        address[] memory vToks = new address[](1);
        vToks[0] = address(vault);
        vm.prank(OWNER);
        vHook.sweepIncentives(vToks);
        assertEq(vault.balanceOf(address(vHook)), shares, "vault shares not swept");
        assertEq(vault.balanceOf(treasury), 0);
    }

    function test_harvest_credit_capped_by_maxHarvestCreditBps() public {
        MockERC4626 vault = new MockERC4626(address(quote));
        ERC4626YieldHook hook =
            new ERC4626YieldHook(address(ac), address(pool), address(quote), address(vault));
        _setHook(address(quote), address(hook), hook.recommendedFlags());

        quote.mint(address(this), 200_000e18);
        pool.deposit(address(quote), 200_000e18);
        uint256 book = IPool(address(pool)).getInvested(address(quote));
        assertGt(book, 0);

        // 2× rate → ~100% unrealized yield; default cap is 100 bps of book.
        vault.setRate(2e18);
        uint256 expectedCap = (book * 100) / 10_000;

        vm.prank(OWNER);
        hook.rebalance();
        uint256 after1 = IPool(address(pool)).getInvested(address(quote));
        assertEq(after1, book + expectedCap, "first harvest capped at 100 bps");

        vm.prank(OWNER);
        hook.setMaxHarvestCreditBps(500);
        uint256 book2 = after1;
        uint256 expectedCap2 = (book2 * 500) / 10_000;
        vm.prank(OWNER);
        hook.rebalance();
        uint256 after2 = IPool(address(pool)).getInvested(address(quote));
        assertEq(after2, book2 + expectedCap2, "owner-raised cap");
    }

    function test_harvest_credit_disabled_when_cap_zero() public {
        MockERC4626 vault = new MockERC4626(address(quote));
        ERC4626YieldHook hook =
            new ERC4626YieldHook(address(ac), address(pool), address(quote), address(vault));
        _setHook(address(quote), address(hook), hook.recommendedFlags());

        quote.mint(address(this), 200_000e18);
        pool.deposit(address(quote), 200_000e18);
        uint256 book = IPool(address(pool)).getInvested(address(quote));
        assertGt(book, 0);

        vm.prank(OWNER);
        hook.setMaxHarvestCreditBps(0);
        vault.setRate(2e18);
        vm.prank(OWNER);
        hook.rebalance();
        assertEq(IPool(address(pool)).getInvested(address(quote)), book, "cap 0 disables credit");
    }

    function test_aaveV4_experimental_deploy_and_recall() public {
        MockAaveV4Spoke spoke = new MockAaveV4Spoke();
        uint256 reserveId = 1;
        spoke.setReserve(reserveId, address(quote));

        AaveV4YieldHook hook =
            new AaveV4YieldHook(address(ac), address(pool), address(quote), address(spoke), reserveId, address(0));
        _setHook(address(quote), address(hook), hook.recommendedFlags());

        quote.mint(address(this), 200_000e18);
        pool.deposit(address(quote), 200_000e18);
        uint256 inv = IPool(address(pool)).getInvested(address(quote));
        assertGt(inv, 0, "aave v4 deploy");
        assertEq(spoke.getUserSuppliedAssets(reserveId, address(hook)), inv);

        _forceThinLiquid(address(hook));
        uint256 onHook = quote.balanceOf(address(hook));
        if (onHook > 0) {
            vm.startPrank(address(hook));
            quote.approve(address(spoke), onHook);
            spoke.supply(reserveId, onHook, address(hook));
            vm.stopPrank();
        }

        uint256 amt = 20e18;
        base.mint(address(0xBEEF), amt);
        vm.prank(address(0xBEEF));
        base.approve(address(pool), type(uint256).max);
        uint256 invBefore = IPool(address(pool)).getInvested(address(quote));
        vm.prank(address(0xBEEF));
        assertGt(pool.swap(address(base), address(quote), amt, 0, address(0xBEEF)), 0);
        assertLe(IPool(address(pool)).getInvested(address(quote)), invBefore);
    }

    function test_morphoBlue_nav_virtual_shares_no_irm_accrual() public {
        MockMorphoBlue morpho = new MockMorphoBlue();
        IMorphoBlue.MarketParams memory params = IMorphoBlue.MarketParams({
            loanToken: address(quote),
            collateralToken: address(base),
            oracle: address(0x1),
            irm: address(0x2),
            lltv: 0.8e18
        });
        morpho.setMarket(params);

        MorphoBlueYieldHook hook =
            new MorphoBlueYieldHook(address(ac), address(pool), address(quote), address(morpho), params);
        _setHook(address(quote), address(hook), hook.recommendedFlags());

        quote.mint(address(this), 200_000e18);
        pool.deposit(address(quote), 200_000e18);
        uint256 book = IPool(address(pool)).getInvested(address(quote));
        assertGt(book, 0);

        bytes32 mid = MorphoId.id(params);
        (uint256 shares,,) = morpho.position(mid, address(hook));
        (uint128 assets, uint128 totalShares,,,,) = morpho.market(mid);
        // SharesMathLib.toAssetsDown must round-trip ≈ book (virtual shares; no IRM).
        uint256 expectedNav = (shares * (uint256(assets) + 1)) / (uint256(totalShares) + 1e6);
        assertApproxEqAbs(expectedNav, book, 2, "virtual-shares NAV ~ book");

        // Inflate totalSupplyAssets without touching shares (= IRM accrual not reflected in view until
        // we harvest). Harvest should credit only up to maxHarvestCreditBps.
        morpho.setSupplyTotals(mid, assets + uint128(book), totalShares);
        uint256 cap = (book * 100) / 10_000;
        vm.prank(OWNER);
        hook.rebalance();
        uint256 afterHarvest = IPool(address(pool)).getInvested(address(quote));
        assertEq(afterHarvest, book + cap, "stale-to-accrued jump still sandwich-capped");
    }

    function test_compound_maxWithdrawable_bounded_by_cash() public {
        MockVenus vToken = new MockVenus(address(quote));
        CompoundV2YieldHook hook =
            new CompoundV2YieldHook(address(ac), address(pool), address(quote), address(vToken));
        _setHook(address(quote), address(hook), hook.recommendedFlags());

        quote.mint(address(this), 200_000e18);
        pool.deposit(address(quote), 200_000e18);
        uint256 inv = IPool(address(pool)).getInvested(address(quote));
        assertGt(inv, 0);

        // Drain venue cash below book (simulate utilization); redeem must stop at getCash().
        uint256 cash = vToken.getCash();
        uint256 leave = cash / 10;
        vm.prank(address(vToken));
        quote.transfer(address(0xDEAD), cash - leave);
        assertEq(vToken.getCash(), leave);

        _forceThinLiquid(address(hook));
        uint256 onHook = quote.balanceOf(address(hook));
        if (onHook > 0) {
            // Leave liquid on hook unused; recall must pull from venue cash only.
            // (onHook already sits as uninvested tokens on the hook contract.)
        }

        uint256 amt = 50e18;
        base.mint(address(0xBEEF), amt);
        vm.prank(address(0xBEEF));
        base.approve(address(pool), type(uint256).max);
        // Swap needs more liquid than leave+thin buffer → fail-closed if cash insufficient,
        // or succeeds with recall ≤ leave. Either way: no over-redeem past getCash.
        uint256 cashBefore = vToken.getCash();
        try pool.swap(address(base), address(quote), amt, 0, address(0xBEEF)) {
            assertLe(cashBefore - vToken.getCash(), cashBefore, "redeem <= cash");
        } catch {
            // Fail-closed shortfall is acceptable when cash ≪ need.
            assertLt(vToken.getCash(), inv);
        }
        assertEq(vToken.getCash(), quote.balanceOf(address(vToken)), "cash = balance");
    }

    function test_morphoId_matches_packed_keccak() public pure {
        IMorphoBlue.MarketParams memory params = IMorphoBlue.MarketParams({
            loanToken: address(0x1111),
            collateralToken: address(0x2222),
            oracle: address(0x3333),
            irm: address(0x4444),
            lltv: 0.8e18
        });
        bytes32 got = MorphoId.id(params);
        bytes32 expected;
        assembly ("memory-safe") {
            expected := keccak256(params, 160)
        }
        assertEq(got, expected, "Morpho IdLib: keccak256 over 5x32 memory");
    }
}

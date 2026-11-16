// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./utils/BaseTest.sol";
import {BondingCurveEngine} from "../src/BondingCurveEngine.sol";
import {TreasuryToken} from "../src/TreasuryToken.sol";
import {LiquidityVault} from "../src/LiquidityVault.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title BondingCurveTest
/// @notice Unit tests for pricing, trading, fee scaling, access control, and migration behaviour.
contract BondingCurveTest is BaseTest {
    uint256 internal constant THOUSAND = 1_000e18;

    // -----------------------------------------------------------------------------------
    // Deployment invariants
    // -----------------------------------------------------------------------------------

    function test_InitialState() public view {
        assertEq(token.totalSupply(), 0);
        assertEq(engine.reserveBalance(), 0);
        assertEq(engine.currentFeeBps(), BASE_FEE_BPS);
        assertEq(engine.spotPrice(0), PRICE_BASE);
        assertFalse(engine.migrated());
        assertEq(address(engine.vault()), address(vault));
    }

    function test_ConstructorRejectsInvalidFees() public {
        BondingCurveEngine.CurveConfig memory cfg = BondingCurveEngine.CurveConfig({
            priceBase: PRICE_BASE,
            priceSlope: PRICE_SLOPE,
            migrationCapSupply: SUPPLY_CAP,
            migrationReserveThreshold: HIGH_THRESHOLD,
            baseFeeBps: 200,
            maxFeeBps: 100,
            exitFeeBps: EXIT_FEE_BPS
        });

        vm.expectRevert(BondingCurveEngine.InvalidParameter.selector);
        new BondingCurveEngine(owner, token, usdc, cfg);
    }

    function test_ConstructorRejectsExcessiveMaxFee() public {
        BondingCurveEngine.CurveConfig memory cfg = BondingCurveEngine.CurveConfig({
            priceBase: PRICE_BASE,
            priceSlope: PRICE_SLOPE,
            migrationCapSupply: SUPPLY_CAP,
            migrationReserveThreshold: HIGH_THRESHOLD,
            baseFeeBps: 10,
            maxFeeBps: 1_001,
            exitFeeBps: EXIT_FEE_BPS
        });

        vm.expectRevert(BondingCurveEngine.InvalidParameter.selector);
        new BondingCurveEngine(owner, token, usdc, cfg);
    }

    // -----------------------------------------------------------------------------------
    // Purchases
    // -----------------------------------------------------------------------------------

    function test_BuyMintsTokensAndCollectsReserve() public {
        uint256 cost = _buy(alice, THOUSAND);

        assertEq(cost, 1_003_501_500, "cost includes 30 bps fee on the curve integral");
        assertEq(token.balanceOf(alice), THOUSAND);
        assertEq(engine.reserveBalance(), cost);
        assertEq(usdc.balanceOf(alice), 5_000_000e6 - cost);
        assertEq(engine.spotPrice(token.totalSupply()), 1_001_000);
        assertEq(engine.redeemableValue(THOUSAND), 1_000_500_000);
        assertGe(engine.reserveBalance(), engine.redeemableValue(token.totalSupply()));
    }

    function test_QuoteBuyMatchesExecution() public {
        (uint256 quoted,) = engine.quoteBuy(12_345e18);
        uint256 spent = _buy(alice, 12_345e18);
        assertEq(spent, quoted);
        assertEq(engine.reserveBalance(), quoted);
    }

    function test_BuyRevertsOnSlippage() public {
        (uint256 quoted,) = engine.quoteBuy(THOUSAND);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                BondingCurveEngine.SlippageExceeded.selector, quoted, quoted - 1
            )
        );
        engine.buy(THOUSAND, quoted - 1);
    }

    function test_BuyZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(BondingCurveEngine.ZeroAmount.selector);
        engine.buy(0, type(uint256).max);
    }

    function test_SupplyCapEnforced() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                BondingCurveEngine.SupplyCapExceeded.selector, SUPPLY_CAP + 1, SUPPLY_CAP
            )
        );
        engine.quoteBuy(SUPPLY_CAP + 1);
    }

    function test_FeeInterpolatesWithSupply() public {
        assertEq(engine.currentFeeBps(), 30);

        _buy(alice, 250_000e18);
        // 30 + (300 - 30) * 25% = 97.5, rounded down by integer division.
        assertEq(engine.currentFeeBps(), 97);

        (uint256 grossAtQuarter,) = engine.quoteBuy(1e18);
        _buy(alice, SUPPLY_CAP - token.totalSupply());
        assertEq(engine.currentFeeBps(), MAX_FEE_BPS);
        assertGt(engine.spotPrice(token.totalSupply()), engine.spotPrice(250_000e18));
        assertGt(grossAtQuarter, PRICE_BASE);
    }

    // -----------------------------------------------------------------------------------
    // Sales
    // -----------------------------------------------------------------------------------

    function test_SellReturnsReserveMinusExitFee() public {
        _buy(alice, THOUSAND);
        uint256 reserveBefore = engine.reserveBalance();

        (uint256 quoted, uint256 fee) = engine.quoteSell(500e18);
        assertEq(quoted, 495_371_250);
        assertEq(fee, 5_003_750);

        uint256 refund = _sell(alice, 500e18);
        assertEq(refund, quoted);
        assertEq(reserveBefore - engine.reserveBalance(), refund);
        assertEq(token.balanceOf(alice), 500e18);
        assertEq(engine.reserveBalance(), 1_003_501_500 - refund);
    }

    function test_SellRevertsOnSlippage() public {
        _buy(alice, THOUSAND);
        (uint256 quoted,) = engine.quoteSell(100e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                BondingCurveEngine.SlippageExceeded.selector, quoted, quoted + 1
            )
        );
        engine.sell(100e18, quoted + 1);
    }

    function test_SellAboveCirculatingSupplyReverts() public {
        _buy(alice, THOUSAND);
        vm.expectRevert(BondingCurveEngine.InsufficientBalance.selector);
        engine.quoteSell(THOUSAND + 1);
    }

    function test_SolvencyHoldsAcrossBuyAndSell() public {
        _buy(alice, 5_000e18);
        _sell(alice, 2_500e18);
        _buy(bob, 12_500e18);
        _sell(bob, 10_000e18);

        assertGe(engine.reserveBalance(), engine.redeemableValue(token.totalSupply()));
        assertEq(engine.totalBacking(), engine.reserveBalance());
    }

    // -----------------------------------------------------------------------------------
    // Access control
    // -----------------------------------------------------------------------------------

    function test_MintAndBurnRestrictedToEngine() public {
        bytes32 minterRole = token.MINTER_ROLE();
        bytes32 burnerRole = token.BURNER_ROLE();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                alice,
                minterRole
            )
        );
        token.mint(alice, 1e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                alice,
                burnerRole
            )
        );
        token.burn(alice, 1e18);
    }

    function test_OnlyOwnerCanAdministerEngine() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        engine.setMigrationThreshold(1);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        engine.pause();
    }

    function test_VaultCanOnlyBeConfiguredOnce() public {
        LiquidityVault replacement = new LiquidityVault(address(engine), address(usdc));

        vm.prank(owner);
        vm.expectRevert(BondingCurveEngine.VaultAlreadySet.selector);
        engine.setVault(replacement);
    }

    function test_VaultOperationsRestrictedToEngine() public {
        vm.prank(alice);
        vm.expectRevert(LiquidityVault.OnlyEngine.selector);
        vault.lock(1, 1);

        vm.prank(alice);
        vm.expectRevert(LiquidityVault.OnlyEngine.selector);
        vault.settleRedemption(alice, 1);
    }

    function test_PauseBlocksTrading() public {
        _buy(alice, THOUSAND);

        vm.prank(owner);
        engine.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        engine.buy(1e18, type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        engine.sell(1e18, 0);

        vm.prank(owner);
        engine.unpause();

        _buy(alice, 1e18);
    }

    // -----------------------------------------------------------------------------------
    // Migration
    // -----------------------------------------------------------------------------------

    function test_MigrationRequiresThreshold() public {
        _buy(alice, 100e18);
        uint256 balance = engine.reserveBalance();

        vm.expectRevert(
            abi.encodeWithSelector(
                BondingCurveEngine.ThresholdNotReached.selector, balance, HIGH_THRESHOLD
            )
        );
        engine.migrateLiquidity();

        assertFalse(engine.migrated());
    }

    function test_ManualMigrationLocksReserve() public {
        _buy(alice, 1_000e18);
        uint256 reserveLocked = engine.reserveBalance();

        vm.prank(owner);
        engine.setMigrationThreshold(500e6);
        assertTrue(engine.migrationReady());

        engine.migrateLiquidity();

        assertTrue(engine.migrated());
        assertEq(engine.reserveBalance(), 0);
        assertEq(vault.lockedReserve(), reserveLocked);
        assertEq(vault.reserveBalance(), reserveLocked);
        assertEq(vault.balanceOf(address(engine)), reserveLocked, "1:1 LP receipts");
        assertEq(vault.redeemableSupply(), token.totalSupply());
        assertEq(engine.totalBacking(), reserveLocked);
    }

    function test_AutoMigrationOnThresholdCrossing() public {
        vm.prank(owner);
        engine.setMigrationThreshold(1_000e6);

        _buy(alice, THOUSAND);

        assertTrue(engine.migrated(), "buy must migrate automatically at the threshold");
        assertEq(engine.reserveBalance(), 0);
        assertGt(vault.lockedReserve(), 1_000e6);
    }

    function test_CurveClosedAfterMigration() public {
        _buy(alice, 1_000e18);
        vm.prank(owner);
        engine.setMigrationThreshold(1);
        engine.migrateLiquidity();

        vm.prank(alice);
        vm.expectRevert(BondingCurveEngine.CurveClosed.selector);
        engine.buy(1e18, type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(BondingCurveEngine.CurveClosed.selector);
        engine.sell(1e18, 0);

        vm.expectRevert(BondingCurveEngine.AlreadyMigrated.selector);
        engine.migrateLiquidity();
    }

    // -----------------------------------------------------------------------------------
    // Post-migration redemption
    // -----------------------------------------------------------------------------------

    function test_RedeemBeforeMigrationReverts() public {
        _buy(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(BondingCurveEngine.NotMigrated.selector);
        engine.redeem(1e18);

        vm.expectRevert(BondingCurveEngine.NotMigrated.selector);
        engine.previewRedeem(1e18);
    }

    function test_RedeemProRata() public {
        _buy(alice, 500e18);
        _buy(bob, 500e18);
        uint256 locked = engine.reserveBalance();

        vm.prank(owner);
        engine.setMigrationThreshold(1);
        engine.migrateLiquidity();

        uint256 expected = vault.previewRedemption(500e18);
        assertEq(expected, locked / 2);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = engine.redeem(500e18);

        assertEq(payout, expected);
        assertEq(usdc.balanceOf(alice), aliceBefore + payout);
        assertEq(token.balanceOf(alice), 0);
        assertEq(vault.redeemableSupply(), 500e18);
        assertGe(vault.lockedReserve(), engine.redeemableValue(token.totalSupply()));
    }

    function test_RedeemAllReleasesEntireReserve() public {
        _buy(alice, 1_000e18);
        uint256 locked = engine.reserveBalance();

        vm.prank(owner);
        engine.setMigrationThreshold(1);
        engine.migrateLiquidity();

        vm.prank(alice);
        uint256 payout = engine.redeem(THOUSAND);

        assertEq(payout, locked);
        assertEq(vault.lockedReserve(), 0);
        assertEq(vault.redeemableSupply(), 0);
        assertEq(token.totalSupply(), 0);
    }

    function test_RedeemAboveBalanceReverts() public {
        _buy(alice, 1_000e18);
        vm.prank(owner);
        engine.setMigrationThreshold(1);
        engine.migrateLiquidity();

        vm.prank(alice);
        vm.expectRevert(BondingCurveEngine.InsufficientBalance.selector);
        engine.redeem(THOUSAND + 1);
    }
}

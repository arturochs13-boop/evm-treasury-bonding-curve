// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {BondingCurveEngine} from "../src/BondingCurveEngine.sol";
import {TreasuryToken} from "../src/TreasuryToken.sol";
import {LiquidityVault} from "../src/LiquidityVault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

/// @title CurveHandler
/// @notice Bounded action handler driving randomized mint, burn, migration, and redemption sequences.
contract CurveHandler is Test {
    BondingCurveEngine public immutable engine;
    TreasuryToken public immutable token;
    MockUSDC public immutable usdc;
    LiquidityVault public immutable vault;

    address[] public actors;

    uint256 public buys;
    uint256 public sells;
    uint256 public redemptions;

    constructor(
        BondingCurveEngine engine_,
        TreasuryToken token_,
        MockUSDC usdc_,
        LiquidityVault vault_,
        address[2] memory seededActors
    ) {
        engine = engine_;
        token = token_;
        usdc = usdc_;
        vault = vault_;

        actors.push(seededActors[0]);
        actors.push(seededActors[1]);
        address carol = makeAddr("carol");
        actors.push(carol);

        usdc.mint(carol, 5_000_000e6);
        vm.prank(carol);
        usdc.approve(address(engine), type(uint256).max);
    }

    /// @notice Randomly mints tokens for a random actor within a bounded size.
    function buy(uint256 actorSeed, uint256 tokenOut) external {
        if (engine.migrated()) return;

        address actor = actors[actorSeed % actors.length];
        tokenOut = bound(tokenOut, 1e15, 20_000e18);
        if (token.totalSupply() + tokenOut > engine.migrationCapSupply()) return;

        (uint256 cost,) = engine.quoteBuy(tokenOut);
        if (usdc.balanceOf(actor) < cost) return;

        vm.startPrank(actor);
        usdc.approve(address(engine), cost);
        engine.buy(tokenOut, cost);
        vm.stopPrank();

        buys++;
    }

    /// @notice Randomly burns tokens held by a random actor.
    function sell(uint256 actorSeed, uint256 tokenIn) external {
        if (engine.migrated()) return;

        address actor = actors[actorSeed % actors.length];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;

        tokenIn = bound(tokenIn, 1, balance);

        vm.startPrank(actor);
        token.approve(address(engine), tokenIn);
        engine.sell(tokenIn, 0);
        vm.stopPrank();

        sells++;
    }

    /// @notice Migrates the curve as soon as the reserve threshold is reached.
    function migrate() external {
        if (engine.migrationReady()) {
            engine.migrateLiquidity();
        }
    }

    /// @notice Redeems a random balance through the migration vault after migration.
    function redeem(uint256 actorSeed, uint256 tokenAmount) external {
        if (!engine.migrated()) return;

        address actor = actors[actorSeed % actors.length];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;

        tokenAmount = bound(tokenAmount, 1, balance);

        vm.startPrank(actor);
        token.approve(address(engine), tokenAmount);
        engine.redeem(tokenAmount);
        vm.stopPrank();

        redemptions++;
    }

    /// @notice Number of tracked actors.
    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

/// @title BondingCurveInvariantTest
/// @notice Stateful invariants proving the protocol can never become undercollateralized.
contract BondingCurveInvariantTest is BaseTest {
    CurveHandler internal handler;

    function setUp() public override {
        super.setUp();

        // A reachable threshold so the randomized sequence exercises both curve and vault paths.
        vm.prank(owner);
        engine.setMigrationThreshold(500e6);

        handler = new CurveHandler(engine, token, usdc, vault, [alice, bob]);
        targetContract(address(handler));
    }

    /// @notice The reserve controlled by the protocol always covers every outstanding token.
    function invariant_reserveSolvency() public view {
        uint256 backing = usdc.balanceOf(address(engine)) + vault.lockedReserve();
        assertGe(
            backing,
            engine.redeemableValue(token.totalSupply()),
            "reserve undercollateralized"
        );
    }

    /// @notice Supply can never exceed the configured migration cap.
    function invariant_supplyWithinCap() public view {
        assertLe(token.totalSupply(), engine.migrationCapSupply());
    }

    /// @notice Migration is a one-way transition: reserve can only move into the vault once.
    function invariant_migrationIsTerminal() public view {
        if (engine.migrated()) {
            assertEq(engine.reserveBalance(), 0, "engine must not retain reserve after migration");
        } else {
            assertEq(vault.lockedReserve(), 0, "vault must stay empty before migration");
        }
    }

    /// @notice Solvency is preserved when a large single trade crosses the migration threshold.
    function testFuzz_MigrationPreservesSolvency(uint256 buyAmount) public {
        buyAmount = bound(buyAmount, 1_000e18, 200_000e18);

        (uint256 cost,) = engine.quoteBuy(buyAmount);
        usdc.mint(alice, cost);
        vm.startPrank(alice);
        usdc.approve(address(engine), cost);
        engine.buy(buyAmount, cost);
        vm.stopPrank();

        assertTrue(engine.migrated());
        assertGe(
            usdc.balanceOf(address(engine)) + vault.lockedReserve(),
            engine.redeemableValue(token.totalSupply())
        );

        uint256 redeemable = token.balanceOf(alice);
        uint256 payout = engine.previewRedeem(redeemable);
        vm.prank(alice);
        engine.redeem(redeemable);

        assertGt(payout, 0);
        assertGe(vault.lockedReserve(), engine.redeemableValue(token.totalSupply()));
    }
}

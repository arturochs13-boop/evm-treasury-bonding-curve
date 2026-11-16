// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {BondingCurveEngine} from "../../src/BondingCurveEngine.sol";
import {TreasuryToken} from "../../src/TreasuryToken.sol";
import {LiquidityVault} from "../../src/LiquidityVault.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";

/// @title BaseTest
/// @notice Shared deployment fixture for the bonding curve test suites.
abstract contract BaseTest is Test {
    uint256 internal constant PRICE_BASE = 1e6; // 1.000000 USDC per whole token
    uint256 internal constant PRICE_SLOPE = 1; // linear slope, in reserve units per token^2
    uint256 internal constant SUPPLY_CAP = 1_000_000e18;
    uint256 internal constant HIGH_THRESHOLD = 10_000_000e6;
    uint256 internal constant BASE_FEE_BPS = 30;
    uint256 internal constant MAX_FEE_BPS = 300;
    uint256 internal constant EXIT_FEE_BPS = 100;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MockUSDC internal usdc;
    TreasuryToken internal token;
    BondingCurveEngine internal engine;
    LiquidityVault internal vault;

    function setUp() public virtual {
        usdc = new MockUSDC();
        token = new TreasuryToken(owner);

        engine = new BondingCurveEngine(
            owner,
            token,
            usdc,
            BondingCurveEngine.CurveConfig({
                priceBase: PRICE_BASE,
                priceSlope: PRICE_SLOPE,
                migrationCapSupply: SUPPLY_CAP,
                migrationReserveThreshold: HIGH_THRESHOLD,
                baseFeeBps: BASE_FEE_BPS,
                maxFeeBps: MAX_FEE_BPS,
                exitFeeBps: EXIT_FEE_BPS
            })
        );

        vault = new LiquidityVault(address(engine), address(usdc));

        vm.startPrank(owner);
        token.grantRole(token.MINTER_ROLE(), address(engine));
        token.grantRole(token.BURNER_ROLE(), address(engine));
        engine.setVault(vault);
        vm.stopPrank();

        vm.prank(alice);
        usdc.approve(address(engine), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(engine), type(uint256).max);

        vm.prank(alice);
        token.approve(address(engine), type(uint256).max);
        vm.prank(bob);
        token.approve(address(engine), type(uint256).max);

        usdc.mint(alice, 5_000_000e6);
        usdc.mint(bob, 5_000_000e6);
    }

    /// @dev Buys `tokenOut` for `actor`, approving exactly the quoted cost.
    function _buy(address actor, uint256 tokenOut) internal returns (uint256 cost) {
        (cost,) = engine.quoteBuy(tokenOut);
        vm.prank(actor);
        engine.buy(tokenOut, cost);
    }

    /// @dev Sells `tokenIn` for `actor` with zero slippage protection (tests only).
    function _sell(address actor, uint256 tokenIn) internal returns (uint256 refund) {
        vm.prank(actor);
        refund = engine.sell(tokenIn, 0);
    }
}

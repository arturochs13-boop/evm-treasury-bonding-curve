// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondingCurveEngine} from "../src/BondingCurveEngine.sol";
import {TreasuryToken} from "../src/TreasuryToken.sol";
import {LiquidityVault} from "../src/LiquidityVault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

/// @title Deploy
/// @notice Deploys and wires a complete treasury bonding curve instance.
/// @dev On testnets without a stablecoin, set `USE_MOCK_RESERVE=true` and seed the deployer with
///      mock reserve using `MockUSDC.mint`. On production networks, pass an existing reserve asset.
contract Deploy is Script {
    struct Deployment {
        address token;
        address engine;
        address vault;
        address reserve;
    }

    function run() external returns (Deployment memory deployment) {
        address owner = vm.envOr("OWNER", msg.sender);
        bool useMockReserve = vm.envOr("USE_MOCK_RESERVE", true);
        address reserve = vm.envOr("RESERVE_ASSET", address(0));

        vm.startBroadcast();

        if (useMockReserve && reserve == address(0)) {
            reserve = address(new MockUSDC());
            console2.log("Deployed MockUSDC reserve:", reserve);
        }

        TreasuryToken token = new TreasuryToken(owner);
        BondingCurveEngine engine = new BondingCurveEngine(
            owner,
            token,
            IERC20(reserve),
            BondingCurveEngine.CurveConfig({
                priceBase: vm.envOr("PRICE_BASE", uint256(1e6)),
                priceSlope: vm.envOr("PRICE_SLOPE", uint256(1)),
                migrationCapSupply: vm.envOr("MIGRATION_CAP_SUPPLY", uint256(1_000_000e18)),
                migrationReserveThreshold: vm.envOr(
                    "MIGRATION_RESERVE_THRESHOLD", uint256(100_000e6)
                ),
                baseFeeBps: vm.envOr("BASE_FEE_BPS", uint256(30)),
                maxFeeBps: vm.envOr("MAX_FEE_BPS", uint256(300)),
                exitFeeBps: vm.envOr("EXIT_FEE_BPS", uint256(100))
            })
        );
        LiquidityVault vault = new LiquidityVault(address(engine), reserve);

        token.grantRole(token.MINTER_ROLE(), address(engine));
        token.grantRole(token.BURNER_ROLE(), address(engine));
        engine.setVault(vault);

        vm.stopBroadcast();

        deployment = Deployment({
            token: address(token),
            engine: address(engine),
            vault: address(vault),
            reserve: reserve
        });

        console2.log("TreasuryToken:", deployment.token);
        console2.log("BondingCurveEngine:", deployment.engine);
        console2.log("LiquidityVault:", deployment.vault);
        console2.log("Reserve asset:", deployment.reserve);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice Six-decimal ERC-20 used as the reserve asset in local and testnet deployments.
/// @dev This contract is intentionally unrestricted: it exists only to emulate a stablecoin
///      reserve in non-production environments. Production deployments must point the bonding
///      curve engine at a real, audited stablecoin instead.
contract MockUSDC is ERC20 {
    /// @notice Thrown when a mint or burn is requested for the zero address or zero amount.
    error InvalidAmount();

    constructor() ERC20("Mock USD Coin", "mUSDC") {}

    /// @notice Returns the number of decimals used to represent reserve balances.
    /// @return The fixed decimal precision of the reserve asset.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mints reserve tokens to an arbitrary account.
    /// @dev Test fixture only. Never deployed to production.
    /// @param to Recipient of the newly minted reserve tokens.
    /// @param amount Amount to mint, denominated in reserve base units (6 decimals).
    function mint(address to, uint256 amount) external {
        if (to == address(0) || amount == 0) revert InvalidAmount();
        _mint(to, amount);
    }

    /// @notice Burns reserve tokens held by the caller.
    /// @dev Test fixture only. Never deployed to production.
    /// @param amount Amount to burn, denominated in reserve base units (6 decimals).
    function burn(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        _burn(msg.sender, amount);
    }
}

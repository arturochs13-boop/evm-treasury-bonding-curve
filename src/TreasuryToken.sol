// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title TreasuryToken
/// @notice ERC-20 representation of a claim on the treasury reserve held by the bonding curve.
/// @dev Supply is controlled exclusively by holders of `MINTER_ROLE` and `BURNER_ROLE`, which are
///      granted to the bonding curve engine and never to end users. The token has no transfer
///      restrictions: secondary market transfers do not alter the protocol's collateral backing.
contract TreasuryToken is ERC20, AccessControl {
    /// @notice Role permitted to mint new supply, held exclusively by the bonding curve engine.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role permitted to burn supply, held exclusively by the bonding curve engine.
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice Thrown when a required address argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when a required amount argument is zero.
    error ZeroAmount();

    /// @param admin Account that administers role assignment. Expected to be a multisig or timelock.
    constructor(address admin) ERC20("Treasury Bond Token", "TBT") {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Mints new supply to a recipient.
    /// @dev Restricted to `MINTER_ROLE`. The engine must only call this after collecting reserve.
    /// @param to Recipient of the minted supply.
    /// @param amount Amount of tokens to mint, denominated in 18-decimal base units.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _mint(to, amount);
    }

    /// @notice Burns supply held by an account.
    /// @dev Restricted to `BURNER_ROLE`. The engine burns tokens it has already pulled back.
    /// @param from Account whose balance is destroyed.
    /// @param amount Amount of tokens to burn, denominated in 18-decimal base units.
    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        if (from == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _burn(from, amount);
    }
}

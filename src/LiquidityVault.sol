// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title LiquidityVault
/// @notice Deterministic custody vault that receives the reserve and issues LP receipts at migration.
/// @dev The vault is deployed once per curve, knows its engine immutably, and never allows the
///      engine to withdraw more than the pro-rata claim of the tokens being redeemed. All state
///      transitions follow checks-effects-interactions ordering and are reentrancy guarded.
contract LiquidityVault is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The bonding curve engine authorized to lock reserve and settle redemptions.
    address public immutable engine;

    /// @notice The reserve asset custodied by this vault.
    IERC20 public immutable reserveAsset;

    /// @notice Amount of reserve currently backing unredeemed supply, in reserve base units.
    uint256 public lockedReserve;

    /// @notice Token supply entitled to the `lockedReserve`, in token base units.
    uint256 public redeemableSupply;

    /// @notice True once the engine has locked the reserve and disabled curve trading.
    bool public migrated;

    /// @notice Thrown when a caller other than the engine invokes an engine-only function.
    error OnlyEngine();

    /// @notice Thrown when an address argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when a zero amount or zero supply is supplied.
    error ZeroAmount();

    /// @notice Thrown when the vault has already been funded by the engine.
    error AlreadyMigrated();

    /// @notice Thrown when the vault has not been funded yet.
    error NotMigrated();

    /// @notice Thrown when a redemption exceeds the recorded redeemable supply.
    error InsufficientClaim();

    /// @notice Emitted when the reserve is locked and LP receipts are issued.
    event ReserveLocked(address indexed engine, uint256 reserveAmount, uint256 supply, uint256 lpShares);

    /// @notice Emitted when a redemption is settled and reserve is released.
    event RedemptionSettled(address indexed to, uint256 tokenAmount, uint256 payout);

    /// @param engine_ Address of the bonding curve engine authorized over this vault.
    /// @param reserveAsset_ Reserve asset custodied by the vault.
    constructor(address engine_, address reserveAsset_)
        ERC20("Treasury Migration LP", "tmLP")
    {
        if (engine_ == address(0) || reserveAsset_ == address(0)) revert ZeroAddress();
        engine = engine_;
        reserveAsset = IERC20(reserveAsset_);
    }

    modifier onlyEngine() {
        if (msg.sender != engine) revert OnlyEngine();
        _;
    }

    /// @notice Locks reserve transferred by the engine and mints 1:1 LP receipts to the engine.
    /// @dev The engine must transfer the reserve before calling, or approve this vault first.
    ///      LP receipts are held by the engine forever and act as an on-chain liquidity proof.
    /// @param reserveAmount Amount of reserve being locked, in reserve base units.
    /// @param supply Total token supply entitled to the locked reserve, in token base units.
    function lock(uint256 reserveAmount, uint256 supply) external nonReentrant onlyEngine {
        if (migrated) revert AlreadyMigrated();
        if (reserveAmount == 0 || supply == 0) revert ZeroAmount();

        // Effects.
        migrated = true;
        lockedReserve = reserveAmount;
        redeemableSupply = supply;

        // Interactions.
        reserveAsset.safeTransferFrom(msg.sender, address(this), reserveAmount);
        _mint(engine, reserveAmount);

        emit ReserveLocked(engine, reserveAmount, supply, reserveAmount);
    }

    /// @notice Settles a post-migration redemption by releasing the pro-rata reserve claim.
    /// @dev The engine must burn the redeemed tokens before calling. The payout rounds down so the
    ///      vault can never become insolvent; residual dust stays with the final redeemer.
    /// @param to Recipient of the released reserve.
    /// @param tokenAmount Amount of tokens being redeemed, in token base units.
    /// @return payout Amount of reserve released, in reserve base units.
    function settleRedemption(address to, uint256 tokenAmount)
        external
        nonReentrant
        onlyEngine
        returns (uint256 payout)
    {
        if (!migrated) revert NotMigrated();
        if (tokenAmount == 0) revert ZeroAmount();
        if (tokenAmount > redeemableSupply) revert InsufficientClaim();
        if (to == address(0)) revert ZeroAddress();

        uint256 remainingSupply = redeemableSupply - tokenAmount;
        payout = remainingSupply == 0
            ? lockedReserve
            : (lockedReserve * tokenAmount) / redeemableSupply;

        // Effects.
        redeemableSupply = remainingSupply;
        lockedReserve -= payout;

        // Interactions.
        if (payout != 0) {
            reserveAsset.safeTransfer(to, payout);
        }

        emit RedemptionSettled(to, tokenAmount, payout);
    }

    /// @notice Previews the reserve payout for a post-migration redemption.
    /// @param tokenAmount Amount of tokens that would be redeemed, in token base units.
    /// @return The reserve that would be released, rounded down like `settleRedemption`.
    function previewRedemption(uint256 tokenAmount) external view returns (uint256) {
        if (!migrated) revert NotMigrated();
        if (tokenAmount == 0) revert ZeroAmount();
        if (tokenAmount > redeemableSupply) revert InsufficientClaim();
        if (tokenAmount == redeemableSupply) return lockedReserve;
        return (lockedReserve * tokenAmount) / redeemableSupply;
    }

    /// @notice Returns the reserve currently custodied by the vault.
    /// @return The vault's reserve balance in reserve base units.
    function reserveBalance() external view returns (uint256) {
        return reserveAsset.balanceOf(address(this));
    }
}

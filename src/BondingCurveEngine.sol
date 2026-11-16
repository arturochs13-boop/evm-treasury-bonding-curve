// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TreasuryToken} from "./TreasuryToken.sol";
import {LiquidityVault} from "./LiquidityVault.sol";

/// @title BondingCurveEngine
/// @notice Deterministic, reserve-backed bonding curve that mints and burns `TreasuryToken`.
/// @dev Pricing is a linear curve `p(s) = priceBase + priceSlope * s / 1e18`, where `p` is
///      denominated in reserve base units (6 decimals) per whole token (1e18 base units). The
///      cost of a trade is the exact integral of `p` over the traded supply interval, so the
///      reserve always covers the redeemable value of every outstanding token.
///
///      Invariant: `reserve.balanceOf(engine) + vault.lockedReserve >= redeemableValue(totalSupply)`
///      for the entire lifetime of the protocol, including after migration.
contract BondingCurveEngine is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Denominator for basis-point fee values.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Fixed-point scale used by the pricing curve.
    uint256 public constant WAD = 1e18;

    /// @notice Hard ceiling on total supply to keep curve arithmetic inside uint256 bounds.
    uint256 public constant MAX_SUPPLY_CAP = 1e27;

    /// @notice Largest fee any curve operation may charge, in basis points (10%).
    uint256 public constant MAX_FEE_BPS = 1_000;

    /// @notice Immutable curve and fee parameters supplied at deployment.
    /// @param priceBase Reserve-denominated price of the first whole token (6 decimals).
    /// @param priceSlope Reserve-denominated slope of the price curve per whole token.
    /// @param migrationCapSupply Supply at which the dynamic fee reaches its maximum.
    /// @param migrationReserveThreshold Reserve balance that triggers automatic liquidity migration.
    /// @param baseFeeBps Protocol fee applied to purchases at zero supply.
    /// @param maxFeeBps Protocol fee applied to purchases once supply reaches the migration cap.
    /// @param exitFeeBps Protocol fee retained on redemptions through the curve.
    struct CurveConfig {
        uint256 priceBase;
        uint256 priceSlope;
        uint256 migrationCapSupply;
        uint256 migrationReserveThreshold;
        uint256 baseFeeBps;
        uint256 maxFeeBps;
        uint256 exitFeeBps;
    }

    /// @notice ERC-20 reserve asset that collateralizes the curve (6 decimals expected).
    IERC20 public immutable reserve;

    /// @notice Token minted and burned exclusively by this engine.
    TreasuryToken public immutable token;

    /// @notice Price of the first whole token, in reserve base units.
    uint256 public immutable priceBase;

    /// @notice Linear price slope, in reserve base units per whole token per whole token.
    uint256 public immutable priceSlope;

    /// @notice Supply at which the dynamic fee reaches `maxFeeBps`.
    uint256 public immutable migrationCapSupply;

    /// @notice Fee charged on purchases at zero supply, in basis points.
    uint256 public immutable baseFeeBps;

    /// @notice Fee charged on purchases at the migration cap, in basis points.
    uint256 public immutable maxFeeBps;

    /// @notice Fee retained on curve redemptions, in basis points.
    uint256 public immutable exitFeeBps;

    /// @notice Reserve balance that triggers automated migration into the vault.
    uint256 public migrationReserveThreshold;

    /// @notice Custody vault that receives reserve once the threshold is reached.
    LiquidityVault public vault;

    /// @notice True once the reserve has been locked and curve trading is permanently disabled.
    bool public migrated;

    /// @notice Emitted when a buyer mints tokens through the curve.
    event TokensPurchased(
        address indexed buyer, uint256 tokenAmount, uint256 reservePaid, uint256 feePaid
    );

    /// @notice Emitted when a seller burns tokens through the curve.
    event TokensSold(
        address indexed seller, uint256 tokenAmount, uint256 reserveReceived, uint256 feePaid
    );

    /// @notice Emitted when the reserve is locked and curve trading is disabled.
    event LiquidityMigrated(
        address indexed vault, uint256 reserveLocked, uint256 tokenSupply, uint256 lpShares
    );

    /// @notice Emitted when a holder redeems tokens against the migration vault.
    event Redeemed(address indexed holder, uint256 tokenAmount, uint256 reserveReceived);

    /// @notice Emitted when the migration threshold is updated.
    event MigrationThresholdUpdated(uint256 previousThreshold, uint256 newThreshold);

    /// @notice Emitted when the migration vault is configured.
    event VaultConfigured(address indexed vault);

    /// @notice Thrown when a required address argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when a required amount argument is zero.
    error ZeroAmount();

    /// @notice Thrown when a configuration value is outside its permitted range.
    error InvalidParameter();

    /// @notice Thrown when the token or reserve asset uses unexpected decimals.
    error UnsupportedDecimals();

    /// @notice Thrown when curve trading is attempted after migration.
    error CurveClosed();

    /// @notice Thrown when a migration is attempted more than once.
    error AlreadyMigrated();

    /// @notice Thrown when migration is attempted before a vault has been configured.
    error VaultNotSet();

    /// @notice Thrown when the vault has already been configured.
    error VaultAlreadySet();

    /// @notice Thrown when the reserve balance is below the migration threshold.
    /// @param current Current reserve balance held by the engine.
    /// @param required Reserve balance required to migrate.
    error ThresholdNotReached(uint256 current, uint256 required);

    /// @notice Thrown when a trade violates the caller's slippage bound.
    /// @param actual Amount the trade would cost or return.
    /// @param limit Caller-supplied bound.
    error SlippageExceeded(uint256 actual, uint256 limit);

    /// @notice Thrown when a purchase would push supply past the migration cap.
    /// @param requested Supply after the purchase.
    /// @param cap Configured maximum supply.
    error SupplyCapExceeded(uint256 requested, uint256 cap);

    /// @notice Thrown when redemption is attempted before migration.
    error NotMigrated();

    /// @notice Thrown when an amount exceeds the caller's available balance.
    error InsufficientBalance();

    /// @notice Restricts a function to the pre-migration trading phase.
    modifier onlyWhileOpen() {
        if (migrated) revert CurveClosed();
        _;
    }

    /// @param owner_ Initial owner, expected to be a multisig or timelock.
    /// @param token_ Treasury token whose mint and burn roles are held by this engine.
    /// @param reserve_ Reserve asset used to collateralize the curve.
    /// @param config_ Curve shape, fee schedule, and migration parameters.
    constructor(address owner_, TreasuryToken token_, IERC20 reserve_, CurveConfig memory config_)
        Ownable(owner_)
    {
        if (
            owner_ == address(0) || address(token_) == address(0) || address(reserve_) == address(0)
        ) {
            revert ZeroAddress();
        }
        if (token_.decimals() != 18 || IERC20Metadata(address(reserve_)).decimals() != 6) {
            revert UnsupportedDecimals();
        }
        if (config_.priceBase == 0 && config_.priceSlope == 0) revert InvalidParameter();
        if (config_.migrationCapSupply == 0 || config_.migrationCapSupply > MAX_SUPPLY_CAP) {
            revert InvalidParameter();
        }
        if (config_.migrationReserveThreshold == 0) revert InvalidParameter();
        if (config_.maxFeeBps > MAX_FEE_BPS) revert InvalidParameter();
        if (config_.baseFeeBps > config_.maxFeeBps) revert InvalidParameter();
        if (config_.exitFeeBps > MAX_FEE_BPS) revert InvalidParameter();

        token = token_;
        reserve = reserve_;
        priceBase = config_.priceBase;
        priceSlope = config_.priceSlope;
        migrationCapSupply = config_.migrationCapSupply;
        migrationReserveThreshold = config_.migrationReserveThreshold;
        baseFeeBps = config_.baseFeeBps;
        maxFeeBps = config_.maxFeeBps;
        exitFeeBps = config_.exitFeeBps;
    }

    // ---------------------------------------------------------------------------------------
    // Pricing
    // ---------------------------------------------------------------------------------------

    /// @notice Spot price of the next whole token at a given supply.
    /// @param supply Supply to evaluate, in token base units.
    /// @return The marginal price, in reserve base units per whole token.
    function spotPrice(uint256 supply) public view returns (uint256) {
        return priceBase + Math.mulDiv(priceSlope, supply, WAD);
    }

    /// @notice Total reserve value redeemable by a given supply, rounded down.
    /// @param supply Supply to evaluate, in token base units.
    /// @return The area under the price curve from zero to `supply`, in reserve base units.
    function redeemableValue(uint256 supply) public view returns (uint256) {
        return _curveIntegral(0, supply, Math.Rounding.Floor);
    }

    /// @notice Dynamic purchase fee at the current supply, in basis points.
    /// @return The linearly interpolated fee between `baseFeeBps` and `maxFeeBps`.
    function currentFeeBps() public view returns (uint256) {
        uint256 supply = token.totalSupply();
        if (supply >= migrationCapSupply) return maxFeeBps;
        return baseFeeBps
            + Math.mulDiv(maxFeeBps - baseFeeBps, supply, migrationCapSupply);
    }

    /// @notice Quotes the reserve cost of minting a given amount of tokens.
    /// @dev The quote rounds the curve integral up, so the engine never under-collects reserve.
    /// @param tokenOut Amount of tokens the buyer wishes to mint.
    /// @return reserveIn Total reserve the buyer must transfer, including the protocol fee.
    /// @return fee Portion of `reserveIn` retained as the protocol fee.
    function quoteBuy(uint256 tokenOut) public view returns (uint256 reserveIn, uint256 fee) {
        if (tokenOut == 0) revert ZeroAmount();
        uint256 supply = token.totalSupply();
        uint256 newSupply = supply + tokenOut;
        if (newSupply > migrationCapSupply) {
            revert SupplyCapExceeded(newSupply, migrationCapSupply);
        }
        uint256 gross = _curveIntegral(supply, newSupply, Math.Rounding.Ceil);
        fee = Math.mulDiv(gross, currentFeeBps(), BPS_DENOMINATOR);
        reserveIn = gross + fee;
    }

    /// @notice Quotes the reserve refunded for burning a given amount of tokens.
    /// @dev The quote rounds the curve integral down and deducts the exit fee.
    /// @param tokenIn Amount of tokens the seller wishes to burn.
    /// @return reserveOut Net reserve the seller receives.
    /// @return fee Portion of the gross refund retained as the protocol fee.
    function quoteSell(uint256 tokenIn) public view returns (uint256 reserveOut, uint256 fee) {
        if (tokenIn == 0) revert ZeroAmount();
        uint256 supply = token.totalSupply();
        if (tokenIn > supply) revert InsufficientBalance();
        uint256 gross = _curveIntegral(supply - tokenIn, supply, Math.Rounding.Floor);
        fee = Math.mulDiv(gross, exitFeeBps, BPS_DENOMINATOR);
        reserveOut = gross - fee;
    }

    /// @notice Returns the reserve currently held by the engine.
    /// @return The engine's reserve balance, in reserve base units.
    function reserveBalance() public view returns (uint256) {
        return reserve.balanceOf(address(this));
    }

    /// @notice Returns true once the reserve has reached the migration threshold.
    /// @return Whether the curve is eligible for migration.
    function migrationReady() public view returns (bool) {
        return !migrated && reserveBalance() >= migrationReserveThreshold;
    }

    // ---------------------------------------------------------------------------------------
    // Trading
    // ---------------------------------------------------------------------------------------

    /// @notice Mints tokens against the curve, pulling reserve from the caller.
    /// @dev Reverts if the required reserve exceeds `maxReserveIn`. Automatically migrates the
    ///      reserve into the configured vault when the threshold is reached.
    /// @param tokenOut Amount of tokens to mint, in token base units.
    /// @param maxReserveIn Maximum reserve the caller is willing to pay.
    /// @return reserveIn Reserve actually transferred from the caller.
    function buy(uint256 tokenOut, uint256 maxReserveIn)
        external
        nonReentrant
        whenNotPaused
        onlyWhileOpen
        returns (uint256 reserveIn)
    {
        uint256 fee;
        (reserveIn, fee) = quoteBuy(tokenOut);
        if (reserveIn > maxReserveIn) revert SlippageExceeded(reserveIn, maxReserveIn);

        reserve.safeTransferFrom(msg.sender, address(this), reserveIn);
        token.mint(msg.sender, tokenOut);

        emit TokensPurchased(msg.sender, tokenOut, reserveIn, fee);

        if (reserveBalance() >= migrationReserveThreshold) {
            _migrate();
        }
    }

    /// @notice Burns tokens against the curve, returning reserve to the caller.
    /// @dev Reverts if the net refund is below `minReserveOut`.
    /// @param tokenIn Amount of tokens to burn, in token base units.
    /// @param minReserveOut Minimum reserve the caller accepts.
    /// @return reserveOut Net reserve transferred to the caller.
    function sell(uint256 tokenIn, uint256 minReserveOut)
        external
        nonReentrant
        whenNotPaused
        onlyWhileOpen
        returns (uint256 reserveOut)
    {
        uint256 fee;
        (reserveOut, fee) = quoteSell(tokenIn);
        if (reserveOut < minReserveOut) revert SlippageExceeded(reserveOut, minReserveOut);

        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), tokenIn);
        token.burn(address(this), tokenIn);
        reserve.safeTransfer(msg.sender, reserveOut);

        emit TokensSold(msg.sender, tokenIn, reserveOut, fee);
    }

    /// @notice Locks the reserve into the migration vault and disables curve trading.
    /// @dev Permissionless. Also triggered automatically by `buy` when the threshold is reached.
    function migrateLiquidity() external nonReentrant {
        if (migrated) revert AlreadyMigrated();
        uint256 balance = reserveBalance();
        if (balance < migrationReserveThreshold) {
            revert ThresholdNotReached(balance, migrationReserveThreshold);
        }
        _migrate();
    }

    /// @notice Redeems tokens for their pro-rata share of the migrated reserve.
    /// @dev Only available after migration. The engine burns the redeemed tokens before
    ///      instructing the vault to release the corresponding reserve.
    /// @param tokenAmount Amount of tokens to redeem, in token base units.
    /// @return payout Reserve released to the caller.
    function redeem(uint256 tokenAmount) external nonReentrant returns (uint256 payout) {
        if (!migrated) revert NotMigrated();
        if (tokenAmount == 0) revert ZeroAmount();
        if (tokenAmount > token.balanceOf(msg.sender)) revert InsufficientBalance();

        uint256 supplyBefore = token.totalSupply();

        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), tokenAmount);
        token.burn(address(this), tokenAmount);

        payout = vault.previewRedemption(tokenAmount);
        emit Redeemed(msg.sender, tokenAmount, payout);

        uint256 settled = vault.settleRedemption(msg.sender, tokenAmount);

        // Defensive accounting check: the quote and settlement must agree exactly.
        assert(token.totalSupply() == supplyBefore - tokenAmount);
        assert(settled == payout);
    }

    // ---------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------

    /// @notice Previews the reserve payout for redeeming tokens after migration.
    /// @param tokenAmount Amount of tokens to redeem, in token base units.
    /// @return The reserve that would be released to the redeemer.
    function previewRedeem(uint256 tokenAmount) external view returns (uint256) {
        if (!migrated) revert NotMigrated();
        return vault.previewRedemption(tokenAmount);
    }

    /// @notice Returns the reserve plus migrated liquidity backing the current supply.
    /// @return The total protocol-controlled reserve across engine and vault.
    function totalBacking() external view returns (uint256) {
        return reserveBalance() + (address(vault) == address(0) ? 0 : vault.lockedReserve());
    }

    // ---------------------------------------------------------------------------------------
    // Administration
    // ---------------------------------------------------------------------------------------

    /// @notice Configures the migration vault. Can only be called once, before migration.
    /// @param vault_ Vault authorized to custody the reserve.
    function setVault(LiquidityVault vault_) external onlyOwner {
        if (migrated) revert AlreadyMigrated();
        if (address(vault) != address(0)) revert VaultAlreadySet();
        if (address(vault_) == address(0)) revert ZeroAddress();
        vault = vault_;
        emit VaultConfigured(address(vault_));
    }

    /// @notice Updates the reserve threshold that triggers migration.
    /// @param newThreshold New threshold, in reserve base units.
    function setMigrationThreshold(uint256 newThreshold) external onlyOwner {
        if (migrated) revert AlreadyMigrated();
        if (newThreshold == 0) revert InvalidParameter();
        emit MigrationThresholdUpdated(migrationReserveThreshold, newThreshold);
        migrationReserveThreshold = newThreshold;
    }

    /// @notice Pauses purchases, sales, and migration.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resumes normal operation.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ---------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------

    /// @dev Locks the entire reserve balance into the vault at 1:1 LP receipts.
    function _migrate() internal {
        if (address(vault) == address(0)) revert VaultNotSet();

        uint256 reserveLocked = reserve.balanceOf(address(this));
        uint256 supply = token.totalSupply();

        migrated = true;

        reserve.forceApprove(address(vault), reserveLocked);
        vault.lock(reserveLocked, supply);
        reserve.forceApprove(address(vault), 0);

        emit LiquidityMigrated(address(vault), reserveLocked, supply, reserveLocked);
    }

    /// @dev Exact integral of `priceBase + priceSlope * s / 1e18` over `[from, to]`.
    ///      Cost = priceBase * (to - from) / 1e18
    ///           + priceSlope * (to^2 - from^2) / (2 * 1e36).
    function _curveIntegral(uint256 from, uint256 to, Math.Rounding rounding)
        internal
        view
        returns (uint256)
    {
        uint256 delta = to - from;
        uint256 linear = Math.mulDiv(priceBase, delta, WAD, rounding);
        uint256 squares = to * to - from * from;
        uint256 quadratic = Math.mulDiv(priceSlope, squares, 2 * WAD * WAD, rounding);
        return linear + quadratic;
    }
}

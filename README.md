# evm-treasury-bonding-curve

Deterministic 1:1 treasury-backed bonding curve protocol with automated reserve migration and
Foundry invariant testing.

The protocol sells `TreasuryToken` (TBT) along a deterministic linear price curve collateralized by
an ERC-20 reserve asset. Every unit of circulating supply is backed by reserve collected at or above
the curve integral, so the reserve can always cover the redeemable value of the entire supply. When
the reserve reaches a configured threshold, the curve closes permanently, the reserve is migrated
into an isolated vault, and holders redeem pro-rata against that vault.

---

## Architecture

| File | Responsibility |
| --- | --- |
| `src/TreasuryToken.sol` | ERC-20 with role-gated mint/burn, held exclusively by the engine. |
| `src/BondingCurveEngine.sol` | Pricing, purchases, sales, dynamic fees, migration trigger, redemption. |
| `src/LiquidityVault.sol` | Custody of migrated reserve, 1:1 LP receipts, pro-rata redemption settlement. |
| `src/MockUSDC.sol` | Six-decimal reserve asset for local and testnet deployments only. |
| `test/BondingCurve.t.sol` | Unit tests for pricing, fees, slippage, access control, migration. |
| `test/BondingCurveInvariant.t.sol` | Stateful invariant handler and fuzz tests for solvency. |
| `script/Deploy.s.sol` | End-to-end deployment and role wiring. |

### State machine

```
                 buy()                          reserve >= threshold
  ┌──────────┐  ──────────────►  ┌──────────┐  ─────────────────────►  ┌─────────────┐
  │  CURVE   │                   │  CURVE   │                          │  MIGRATED   │
  │  OPEN    │  ◄──────────────  │  OPEN    │                          │  (terminal) │
  └──────────┘      sell()       └──────────┘                          └─────────────┘
       │                              │                                      │
       │ reserve += cost + fee        │ reserve -= refund                    │ redeem()
       │ supply  += tokenOut          │ supply  -= tokenIn                   │ supply  -= burned
       ▼                              ▼                                      ▼
  solvency: R >= V(S)            solvency: R >= V(S)         vault releases pro-rata reserve
                                                                  solvency: L >= V(S)
       │
       └── migrateLiquidity() ──► reserve moves to LiquidityVault, LP receipts minted 1:1,
                                  curve mint/burn permanently disabled
```

---

## Pricing mathematics

Reserve amounts use 6 decimals; token amounts use 18 decimals. Let `S` be the circulating supply in
token base units (1e18 = one whole token). The marginal price in reserve base units per whole token is

```
p(S) = priceBase + priceSlope * S / 1e18
```

The reserve cost of moving supply from `a` to `b` is the exact integral of `p`:

```
Cost(a, b) = priceBase * (b - a) / 1e18
           + priceSlope * (b^2 - a^2) / (2 * 1e36)
```

The total redeemable value of a supply `S` is the same integral from zero:

```
V(S) = priceBase * S / 1e18 + priceSlope * S^2 / (2 * 1e36)
```

### Dynamic purchase fee

The protocol fee grows linearly from `baseFeeBps` at zero supply to `maxFeeBps` at the migration cap:

```
feeBps(S) = baseFeeBps + (maxFeeBps - baseFeeBps) * S / migrationCapSupply
```

Purchases round the integral **up** (`Math.Rounding.Ceil`) and sales round it **down**
(`Math.Rounding.Floor`). Rounding always favours the reserve.

### Solvency invariant

```
reserve.balanceOf(engine) + vault.lockedReserve >= V(token.totalSupply())
```

Proof sketch:

1. A purchase adds `ceil(Cost(a,b)) + fee >= Cost(a,b)` to the reserve while increasing `V` by
   exactly `Cost(a,b)`.
2. A sale removes `floor(Cost(a,b)) * (1 - exitFee)` while decreasing `V` by `Cost(a,b)`, so the
   reserve decreases by at most the value removed.
3. At migration the vault receives the entire reserve, and every redemption releases
   `floor(L * delta / S)` — a proportional share that is never larger than the value of the burned
   supply for a linear curve. The final redeemer receives all remaining reserve.

The invariant therefore holds before, during, and after migration. It is enforced continuously by
`invariant_reserveSolvency` across randomized sequences of buys, sells, migrations, and redemptions.

---

## Security assumptions

- **No oracle.** Pricing depends only on supply and immutable curve parameters, so there is no
  external price feed to manipulate.
- **Access control.** `MINTER_ROLE` and `BURNER_ROLE` are granted only to the engine. The token has no
  other privileged paths. Engine administration is two-step `Ownable`; the owner should be a
  multisig behind a timelock.
- **Reentrancy.** Every state-changing external entry point is `nonReentrant`; the vault is guarded
  independently. All token movements use `SafeERC20`.
- **Checks-Effects-Interactions.** Migration marks `migrated` before moving funds. Redemption burns
  supply before releasing reserve, and asserts that the quoted and settled payouts match.
- **Determinism.** Curve parameters and the migration cap are immutable. Changing the curve after
  launch would invalidate the solvency proof, so no setter exists.
- **Rounding.** All rounding favours the protocol; residual dust accrues to the reserve and is
  distributed to the final redeemer.
- **Trust boundaries.** `MockUSDC` is unrestricted and must never be used in production. The reserve
  asset must be a non-rebasing, non-fee-on-transfer ERC-20 with 6 decimals.
- **Migration is terminal.** There is no path back to curve trading, and the vault exposes no
  withdrawal function other than engine-driven pro-rata settlement.

---

## Build and test

```bash
forge build
forge test -vvv
```

Run the heavier CI profile:

```bash
FOUNDRY_PROFILE=ci forge test -vvv
```

Run only the solvency invariants with a summary table:

```bash
forge test --match-contract BondingCurveInvariantTest -vv
```

Current suite: **28 passing tests**, including 3 stateful invariants over 12,288 handler calls and
a 512-run fuzz campaign crossing the migration boundary.

---

## Deployment

```bash
# Local / testnet with an unrestricted mock reserve
PRIVATE_KEY=0x... OWNER=0x... USE_MOCK_RESERVE=true \
  forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast

# Production: point at an audited six-decimal stablecoin
PRIVATE_KEY=0x... OWNER=0x... USE_MOCK_RESERVE=false RESERVE_ASSET=0x... \
  forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast --verify
```

Deployment order enforced by the wiring step:

1. Deploy `TreasuryToken` with the admin address.
2. Deploy `BondingCurveEngine` with curve parameters and the reserve asset.
3. Deploy `LiquidityVault` with the engine and reserve addresses.
4. Grant `MINTER_ROLE` and `BURNER_ROLE` to the engine.
5. Call `engine.setVault(vault)` once. Migration is impossible until the vault is configured.

### Operational notes

- `buy` and `sell` require an ERC-20 allowance to the engine; quotes are exposed through
  `quoteBuy` and `quoteSell` for front-end slippage bounds.
- Migration fires automatically inside `buy` once the reserve crosses the threshold, and can also be
  triggered permissionlessly through `migrateLiquidity()`.
- After migration, holders call `redeem(tokenAmount)`; previews are available via `previewRedeem`.
- The owner can pause trading and adjust only the migration threshold. Pausing does not affect
  redemption.

---

## License

MIT

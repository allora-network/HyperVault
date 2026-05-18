# Architecture

## Why a HyperEVM vault instead of a legacy HyperCore vault?

Legacy native vaults charge a 10,000 USDC creation fee and are perps-only. HyperEVM contracts can:

- Open positions on any perp **and** any spot market, including HIP-3 markets in non-USDC quote
- Pay only gas to deploy (~0.1 USDC equivalent)
- Encode arbitrary off-chain agreements (fees, lockups, whitelists) as solidity
- Tokenize shares as a standard ERC-4626 — composable with the rest of the DeFi stack

The trade-off: NAV must be derived from precompiles, and the strategy must run from a contract account rather than an EOA. Both are net wins for transparency.

## Layering

```
            ┌─────────────────────────────────────────────────┐
            │  Operator (EOA)                                 │
            │  Emergency Admin (EOA / multisig)               │
            │  Timelock (24h) ─ admin role                    │
            └────────────┬────────────────────────────────────┘
                         │ calls
            ┌────────────▼────────────────────────────────────┐
            │  HyperCoreVault (one per strategy)              │
            │  - ERC4626 share token (12 dp)                  │
            │  - AccessControl: OPERATOR / EMERGENCY / ADMIN  │
            │  - Pausable, ReentrancyGuard                    │
            │  - Whitelist (perps + spots)                    │
            │  - Leverage cap, slippage band, fees            │
            │  - cloid counter                                │
            │  - Withdrawal queue escape hatch                │
            └───────┬─────────────────────┬───────────────────┘
                    │ writes              │ reads
                    ▼                     ▼
            ┌───────────────────┐ ┌────────────────────────┐
            │ CoreWriter        │ │ L1 read precompiles    │
            │ 0x333…3333        │ │ 0x0800 … 0x0810        │
            └───────┬───────────┘ └────────────────────────┘
                    │ async dispatch
                    ▼
            ┌──────────────────────────────────────────────┐
            │  HyperCore matching engine                   │
            │  Position / balance state per account        │
            └──────────────────────────────────────────────┘
```

## NAV — "exitable equity"

```
totalAssets = idleUsdc                       // ERC20 balance on EVM
            + coreSpotUsdc                   // Core spot balance, normalized 8dp → 6dp
            + perpWithdrawable               // HL's own conservative perp equity (6dp)
```

We **do not** sum positions at mark price because an operator can briefly mark a thin perp at an off-market price and inflate NAV for a single block. `withdrawable` is HL's conservative redeemable-equity figure and is the safest input.

## Fee accounting

**Management fee** — continuously accrued each state-changing call. Dilutive mint of fee shares to `feeRecipient`:

```
feeAssets  = nav * mgmtBps * dt / (BPS * YEAR)
feeShares  = feeAssets * supply / (nav - feeAssets)
```

**Performance fee** — per-LP cost basis, crystallized on redeem. Each LP carries `_costBasisPerShare[lp]` set on entry and weighted-averaged on subsequent entries / transfers. At redemption:

```
gainPerShare = max(0, currentPpS - costBasis)
gainAssets   = gainPerShare * sharesRedeemed / WAD
feeAssets    = gainAssets * perfBps / BPS
feeShares    = feeAssets * supply / (nav - feeAssets)
```

No global high-water mark. Each LP pays perf fee only on their realized gain at exit.

## Roles

| Role | Holder (recommended) | Powers |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | `TimelockController` (24h) | Whitelist, leverage cap, fees, slippage band, deposit caps, sweep non-asset, grant/revoke roles |
| `OPERATOR_ROLE` | Strategy hot wallet (could rotate) | Place / cancel orders, bridge moves, USD class transfers |
| `EMERGENCY_ROLE` | Multisig (2-of-3 or 3-of-5) | Pause, cancel-all, close-positions, emergency shutdown |
| `feeRecipient` | Multisig | Receives mgmt + perf fee shares; immutable, set at construction |

## Asset bridging

```
EVM USDC               ERC20.transfer →                Core spot
(6dp)            ───────────────────────────────────→  (8dp, scaled ×100 by bridge)


                  CoreWriter spot_send →
Core spot       ───────────────────────────────────→   EVM USDC
(8dp)               (dest = USDC system addr)          (6dp, scaled /100 by bridge)


                  CoreWriter usd_class_transfer →
Core spot USDC  ───────────────────────────────────→   Core perp USD margin
(6dp USD, ntl arg)
```

The USDC bridge / system address is `0x20...00` (token index 0 in last 8 bytes BE).

## Cloid management

The vault assigns cloids from a monotonic `uint128` counter starting at 1. Cloid 0 is reserved by HL convention as "no cloid".

The operator does not pick cloids. This guarantees no cloid collisions across vault orders and keeps the live runner's reconciliation simple.

`cancel_order_by_cloid` is the primary cancel path. `cancel_order_by_oid` is exposed only to `EMERGENCY_ROLE` as an escape hatch for orders not originating from the vault (e.g., legacy orders if the same Core address was previously used by an EOA).

## Big blocks

Normal operator calls fit comfortably in HyperEVM small blocks (2M gas). The emergency fan-out functions (`emergencyCancelByCloid` over many assets) may exceed that. Operators should opt the vault address into big blocks via the HL API after deploy:

```python
ex.update_evm_user_modify(using_big_blocks=True)
```

## What's intentionally NOT in v1

- Multi-quote vault support (one quote = USDC)
- HIP-3 perp deployer logic (vaults can trade HIP-3 perps in v1; they cannot create them)
- Subaccount support (one Core account per vault)
- Operator-reported NAV override
- Frontend write surface — discovery only
- Native HYPE deposits (`receive()` is intentionally absent)
- `vault_transfer` wrapper (vault contract IS its own Core account; nothing to delegate to)

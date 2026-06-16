# Integration Guide — Live Runner

This document describes how the existing Python live runner (the one that talks to Hyperliquid via the HL Python SDK today) integrates with a HyperCoreVault contract.

The vault is **a thin wrapper over CoreWriter** — every operator call submits the same action that the SDK would have submitted, just from the contract address instead of the operator's EOA. Reconciliation against the HL API stays largely the same; the only difference is that order submission flows through an EVM transaction.

## Operator key model

| Today (legacy) | With vault |
|---|---|
| Live runner signs HL API actions with the strategy account's API wallet key | Live runner signs EVM transactions with the **operator** wallet's key, calling vault functions |
| Account = strategy account directly | Account on Core = **vault contract address** |
| Funds custodied on Core | Funds custodied on EVM (idle) + Core (deployed) |

The operator wallet only has `OPERATOR_ROLE`. It can place / cancel orders and move funds between EVM and Core, but it cannot withdraw to itself, change fees, or modify the whitelist. Compromise of the operator key is bounded by the whitelist and slippage band.

## After deploy: enable big blocks

The deploy script does not currently opt the vault into big blocks. Run this once per vault, signed by an API wallet authorized for the vault address:

```python
from hyperliquid.exchange import Exchange
from hyperliquid.utils.types import Cloid

# API wallet authorized for the vault address
ex = Exchange(api_wallet, base_url=BASE_URL, vault_address=VAULT_ADDRESS)
ex.update_evm_user_modify(using_big_blocks=True)
```

Big blocks are required for the emergency fan-out paths (`emergencyCancelByCloid` over many assets, `emergencyClosePositions`).

## Calling trade-execution functions

### Place a limit order

```python
from web3 import Web3
w3 = Web3(Web3.HTTPProvider(HYPEREVM_RPC))
vault = w3.eth.contract(address=VAULT_ADDRESS, abi=VAULT_ABI)

tx = vault.functions.placeLimitOrder(
    asset=0,                # BTC perp index
    isBuy=True,
    limitPx=5_000_000_000_000, # encoded price = round(human_px * 10^8); 50000.0 -> 5e12
    sz=20_000,                 # encoded size  = round(human_sz * 10^8); 0.0002 BTC -> 20000
    reduceOnly=False,
    tif=2                    # GTC  (TIF: 1=ALO post-only, 2=GTC, 3=IOC)
).build_transaction({
    "from": operator_addr,
    "nonce": w3.eth.get_transaction_count(operator_addr),
})
signed = operator_acct.sign_transaction(tx)
receipt = w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(signed.rawTransaction))
```

> **Price/size encoding (critical).** `limitPx` and `sz` are each `round(human × 10^8)` — a **uniform 10^8 scale, NOT szDecimals-based**. (HL docs: "limitPx and sz should be sent as 10^8 * the human readable value"; verified on mainnet — an order encoded as `human × 10^(8−szDecimals)` is **silently dropped** by HyperCore, a `10^8` order rests.) Use `hl_helpers.PerpAssetMeta.encode_px/encode_sz`, and respect HL's rules on the *human* values: perp price ≤5 significant figures and ≤(6−szDecimals) decimals; size ≤szDecimals decimals; order notional ≥ $10.

> **TIF encoding (critical).** `tif` is the raw HyperCore value and is **1-indexed**: `1 = ALO` (post-only), `2 = GTC`, `3 = IOC`. There is no FOK. A `tif` of `0` is invalid — HyperCore silently drops the action (the EVM tx still succeeds and the event still fires, but no order rests). Prefer the on-chain `Constants.TIF_*` names; if passing raw integers, use 1/2/3.

The transaction emits `LimitOrderSubmitted(asset, isBuy, limitPx, sz, reduceOnly, tif, cloid, navSnapshot)`. The `cloid` is auto-assigned by the vault (monotonic counter). Capture it from the event log and use for subsequent `cancelOrderByCloid`.

### Cancel by cloid

```python
tx = vault.functions.cancelOrderByCloid(asset=0, cloid=42).build_transaction(...)
```

### Move funds: EVM USDC ⇄ Core spot ⇄ Perp margin

```python
# EVM → Core spot. v1.5 (G2): internally approve + deposit on Circle's
# CoreDepositWallet (the ERC20 Transfer goes to the wallet, not 0x2000…);
# the vault's Core SPOT balance is credited within ~1 Core block.
vault.functions.pushToCore(amount=50_000_000000).transact()  # 50k USDC at 6dp

# Core spot → perp margin
vault.functions.usdSpotToPerp(ntl=50_000_000000).transact()

# Perp → spot
vault.functions.usdPerpToSpot(ntl=50_000_000000).transact()

# Core spot → EVM. The Core-side action is CoreWriter `send_asset` (action 13) to the
# USDC system address; HyperCore debits the vault's Core spot and the CoreDepositWallet
# pays native USDC from its reserve to the CALLER (this vault). NEVER pass the exact full
# Core balance — see the fee note below.
vault.functions.pullFromCore(amountWei=49_900_00000000).transact()  # ~49.9k at 8dp (under the balance)
```

⚠ `pullFromCore` takes **Core wei** (8dp for USDC), not EVM wei (6dp). All other operator functions use 6dp.

⚠ **Never pull the EXACT full Core balance.** HyperCore deducts a small withdrawal fee
(~0.00134 USDC, proven live) from the Core account *on top of* the requested amount. If you
request the full balance there is nothing to cover the fee and HyperCore **silently drops**
the `send_asset` (the EVM tx still succeeds and emits `BridgeWithdraw` — fire-and-forget — but
Core never debits). Pull strictly under the balance (the keeper loop uses `balance × 0.998`).
A vault's **first** push also costs a one-time **1.0 USDC** account-activation gas.

⚠ **`spot_send` (action 6) does NOT work** for these accounts — unified HyperCore accounts
silently drop it. The vault uses `send_asset` (action 13) for every Core-side move
(`pullFromCore`, `operatorRecoverSpot`, `emergencyRepatriate`).

⚠ **G2 operational notes:** the CoreDepositWallet is Circle-operated and pausable — if
`wallet.paused()` is true, BOTH `pushToCore` and the pull payout stall until Circle
unpauses (monitor it; `e2e_runner.py --steps wallet_status` prints it). The vault leaves
zero standing allowance to the wallet between pushes.

## Reconciliation

The vault's event log is the canonical record of intent. **It is NOT the canonical record of fills** — `sendRawAction` is fire-and-forget and HL may reject (insufficient margin, post-only crossed, asset paused, etc.).

The live runner should:

1. **Index `LimitOrderSubmitted` events** as they fire (push-based via WS subscription, or pull-based via `eth_getLogs`).
2. **For each cloid, query the HL `info` endpoint** (`openOrders` or `historicalOrders`) keyed by the vault address to confirm acceptance. If the cloid does not appear in HL's view, the action was rejected.
3. **Map cloid → oid** once the order is resting. Store both for the reconciliation DB.
4. **For fills, subscribe to `userFills`** on the HL WS API for the vault address. Each fill has both `cloid` and `oid`. Match back to vault events by cloid.
5. **Tap `NavSnapshot` events** to update the strategy's view of vault NAV without re-reading every precompile each cycle.

### Event → SDK response field map

| Vault event | SDK equivalent | Notes |
|---|---|---|
| `LimitOrderSubmitted(.., cloid, ..)` | `response.data.statuses[i].resting.oid` / `.filled.oid` | The oid comes from HL post-acceptance; vault knows only the cloid at submission |
| `OrderCancelByCloidSubmitted` | `response.data.statuses[i].success` | HL returns `{"status": "ok"}` per-cancel |
| `OrderCancelByOidSubmitted` | same as above | Emergency path |
| `UsdClassTransferSubmitted` | `response.status` for `usdClassTransfer` action | |
| `BridgeDeposit` | ERC20 `Transfer` from vault → **CoreDepositWallet** (v1.5 G2; legacy mode: → bridge address) | Core spot credit driven by the wallet's synthetic Transfer log; confirm via HL API / `coreSpotUsdc()` |
| `BridgeWithdraw` | A `send_asset` action (id 13) of `(systemAddr, spot→spot, USDC, amount)` | Settled by HL within ~1 block — but DROPPED if `amount` == full Core balance (fee uncovered) |
| `NavSnapshot` | computed off-chain previously | Now emitted directly |

## Reading NAV / position state on-chain

The vault exposes view helpers (all gas-free on RPC):

```python
nav = vault.functions.nav().call()                 # total assets, 6dp USD
pps = vault.functions.pricePerShare().call()       # 1e18-scaled
idle = vault.functions.idleUsdc().call()           # 6dp
spot = vault.functions.coreSpotUsdc().call()       # 6dp (normalized from Core 8dp)
perp = vault.functions.perpWithdrawable().call()   # 6dp
```

These read directly from the precompiles. No off-chain caching needed for accuracy.

For finer-grained position state (per-asset szi, mark px, oracle px, etc.), the live runner should continue to use the existing HL API path — those reads are cheaper and richer than wrapping each precompile in a view function.

## Withdrawal queue

LPs can request an exit via `requestWithdraw(shares)`. The shares move to the vault as escrow and emit `WithdrawalRequested(lp, shares)`. The live runner should:

1. Watch for `WithdrawalRequested` events.
2. If aggregate pending shares are material, rebalance EVM idle USDC by pulling from Core.
3. Call `fulfillWithdraw(lp)` for each LP. Partial fills are supported when idle is short.

The fulfillment is permissionless — anyone (including the LP themselves) can call it. Keepers welcome.

## Soft redemption barriers (explicit ERC-4626 deviations)

> **STATUS (M4 / SOLU-3366):** SHIPPED. The barriers are stacked on the M5
> emergency-extraction split (SOLU-3369), where the vault has headroom, and fit under
> the EIP-170 24576-byte limit (vault **23,569 B, +1,007 B margin**). Proven on real
> HyperEVM bytecode (`test/fork/HyperVaultBarriers.fork.t.sol`, B0-B9, 10/10). To fit,
> the three on-chain barrier-state **view getters were dropped** — integrators read the
> state off-chain instead (see below). The state + branchy logic live in the external
> delegatecall library `src/libraries/VaultBarrierLib.sol`.

The vault supports four **admin-configured soft barriers** that add *friction* to the
**synchronous** exit paths (`withdraw` / `redeem`). They are `require`-checks, set via a
single timelock call:

```python
# admin (TimelockController): lockup seconds, cooldown seconds, gate bps (of NAV)
vault.functions.setRedemptionBarriers(7*24*3600, 24*3600, 5000).transact()
# Each call emits RedemptionBarriersUpdated(lockup, cooldown, gateBps) — index that
# event for the live config (all 0 = OFF, the deploy default).
```

**Reading barrier state off-chain (the view getters were dropped — EIP-170).** To keep
the vault under the 24576-byte limit, the on-chain getters `redemptionBarriers()`,
`lastDepositAt(lp)`, and `lastRedeemAt(lp)` are **not** exposed. The state is unchanged —
it lives in `VaultBarrierLib`'s ERC-7201 namespaced slot — so read it with
`eth_getStorageAt` (or index `RedemptionBarriersUpdated`):

```python
SLOT = 0x77baf71947acbe45a89d2c84006fb2f1cbe1654c8023f6853f43b8e463ccc600  # VaultBarrierLib.SLOT
# config word at SLOT: lockup = bits[0:64], cooldown = [64:128], gateBps = [128:144]
word = int.from_bytes(w3.eth.get_storage_at(vault.address, SLOT), "big")
lockup, cooldown, gateBps = word & (2**64-1), (word >> 64) & (2**64-1), (word >> 128) & (2**16-1)
# per-LP clocks (uint64 unix ts, 0 = none): mapping(address=>uint64) at SLOT+1 / SLOT+2
last_deposit = int.from_bytes(w3.eth.get_storage_at(vault.address, w3.keccak(abi.encode(["address","uint256"], [lp, SLOT+1]))), "big")
last_redeem  = int.from_bytes(w3.eth.get_storage_at(vault.address, w3.keccak(abi.encode(["address","uint256"], [lp, SLOT+2]))), "big")
```

**They all default to 0 (OFF).** A vault that never calls `setRedemptionBarriers` behaves
**exactly** as a vault without this feature — the sync paths are unchanged. They are
explicitly **NOT** a freeze and **NOT** pausability: redeems are never pausable, and the
barriers gate the *instant* path only. The `requestWithdraw` queue, the emergency surface
(`pause`, `emergencyClosePositions`, `emergencyShutdown`, `emergencyRepatriate`), and every
Core→EVM repatriation mover (`pullFromCore`, `usdPerpToSpot`, `operatorRecoverSpot`) are
**never barrier-gated**, so deployed-capital liveness (assessment Findings A/B) is preserved.

Each is a deliberate deviation from a strict drop-in ERC-4626 that an integrator (router /
money-market adapter / aggregator) MUST account for. The sync view functions (`maxWithdraw`,
`maxRedeem`, `previewRedeem`) are already best-effort once capital is on Core (see above);
the barriers add timing/size states they do not express:

| Barrier | Knob | What it gates (sync `withdraw`/`redeem` only) | Reverts with | ERC-4626 deviation an integrator must handle |
|---|---|---|---|---|
| **Lockup** | `lockupPeriod` (seconds) | A sync exit is blocked until `lastDepositAt[owner] + lockupPeriod`. The clock is keyed on the **share owner** and stamped on **every deposit/mint**, so the **most-recent** deposit governs — a re-deposit **refreshes** the lockup on the whole position (simplest, safest; a dust top-up cannot dodge the lockup). | `LockupNotElapsed(unlockAt)` | `withdraw`/`redeem` revert for a freshly-deposited owner even when `maxWithdraw`/`maxRedeem` are positive. `maxRedeem` does **not** subtract a locked balance. Route via `requestWithdraw` (never lockup-gated). |
| **Cooldown** | `redeemCooldown` (seconds) | After a successful sync exit, the owner's next sync exit is blocked until `lastRedeemAt[owner] + redeemCooldown`. Stamped on every value-moving `withdraw`/`redeem`. | `RedeemCooldownActive(readyAt)` | A second `withdraw`/`redeem` in the cooldown window reverts even though the owner still holds redeemable shares. Not reflected in `maxRedeem`. Use the queue for the rest. |
| **Gate** | `redeemGateBps` (bps of NAV) | A **single** sync exit may move at most `redeemGateBps * totalAssets() / 10000`. The bound is on the **requested gross** (pre-partial-fill), so it cannot be dodged by relying on a partial fill. It is **per-transaction**, NOT a global/rolling cap — it does not aggregate across txs or LPs (splitting across txs is throttled by the cooldown instead). | `RedeemGateExceeded(requested, cap)` | A large `withdraw`/`redeem` reverts even with ample idle. `maxWithdraw`/`maxRedeem` do **not** cap to the gate. Split into ≤cap chunks (subject to cooldown) or route the remainder via `requestWithdraw`. |
| **Notice** | *(no new timer)* | "Notice" is expressed via the **existing `requestWithdraw` queue**, not a separate barrier. Exits blocked by lockup/cooldown/gate, or simply larger than current idle, go through `requestWithdraw` → `fulfillWithdraw`, which carries the on-chain `fulfillmentDeadline` SLA (`setRequestFulfillmentWindow`) and the permissionless `prioritizeOverdue` fairness crank. | — | The queue is the always-available, **ungated** escape and the documented "notice period" mechanism. Reusing it (rather than a second timer) keeps the vault's scarce EIP-170 bytecode for the checks that need it. |

**Why express notice via the queue (not a new timer):** the queue already *is* a notice
path — it escrows shares, carries an SLA deadline, and is permissionless to fulfill. Adding
a distinct notice timer would duplicate that machinery and cost bytecode the vault does not
have. So "give notice for a large/blocked exit" == "call `requestWithdraw`".

**Barriers are keyed on the share `owner`, not `msg.sender`.** A router or approved spender
redeeming on an owner's behalf inherits that owner's lockup/cooldown. The gate is global
(a fraction of NAV) and applies to whoever calls.

**Implementation note (EIP-170):** the barrier state + comparison logic live in the external
delegatecall library `src/libraries/VaultBarrierLib.sol` (ERC-7201 namespaced storage),
mirroring the audit-G2 `VaultTradeLib` split — the vault carries only thin wrappers
(`setRedemptionBarriers` → `VaultBarrierLib.setBarriers`; the per-exit `enforce`) plus the
inline deposit/mint lockup stamp. Stacked on the M5 emergency-extraction split (SOLU-3369)
the feature fits with **+1,007 B** of runtime-size margin, after two trims: (1) the three
on-chain barrier-state **view getters were dropped** (read the namespaced slot / events
off-chain, as above — they cost ~235 B the vault did not have); and (2) the audit-M6
`suggestedSpotPxScaleFactor` calibration helper was hoisted into `VaultTradeLib` (its
`10 ** x` had dragged the full runtime-exponentiation routine, ~1.2 KB, into the vault;
the library already carries that routine, so the move is behaviour-identical and frees
the room). Neither trim changes any barrier semantics or any value-moving path.

## Emergency runbook

If the strategy must be shut down (operator key suspected compromised, market dislocation, contract bug suspected):

```python
# 1. Pause (no further deposits or trades; redeems remain open)
vault.functions.pause().transact({"from": EMERGENCY_ADMIN})

# 2. Cancel all known cloids in one tx (big blocks helpful here)
vault.functions.emergencyCancelByCloid([asset_id_array], [[cloid_array_per_asset]]).transact()

# 3. Close positions at mark ± slippage (caller-supplied limit pxs)
vault.functions.emergencyClosePositions([asset_id_array], [limit_px_array]).transact()

# 4. Rebalance everything to EVM idle USDC. Pull UNDER the Core balance so the
#    ~0.00134 USDC withdrawal fee is covered (full balance is silently dropped).
vault.functions.usdPerpToSpot(total_perp).transact()
vault.functions.pullFromCore(int(core_spot_wei * 0.998)).transact()  # send_asset, leave fee buffer

# 5. (Optional) one-way emergencyShutdown — blocks deposits forever
vault.functions.emergencyShutdown().transact()
```

LPs can then exit cleanly via `redeem` or `fulfillWithdraw`.

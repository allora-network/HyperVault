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

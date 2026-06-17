#!/usr/bin/env python3
"""Live mainnet test harness for HyperCoreVault.

This is the project's automated integration coverage: it drives a vault through
the full lifecycle on HyperEVM **mainnet** and asserts each step against both
the vault's on-chain state and the HL info endpoint. (Mock-based forge tests
were retired — real CoreWriter / precompile behaviour is what matters here.)

Default flow:
    preflight → deposit → push → spot→perp → place → cancel → fill → perp→spot → pull → redeem

`place` rests a post-only order; `fill` crosses the book with a marketable IOC,
confirms the fill via HL `userFills`, then flattens reduce-only. `fill` and the
bridge steps move real funds / pay fees — scope with `--steps` as needed.

Usage:
    ARTIFACT=deployments/mainnet/<strategy>.json \\
    HYPEREVM_RPC_MAINNET=https://rpc.hyperliquid.xyz/evm \\
    ALICE_PRIVATE_KEY=0x... \\
    OPERATOR_PRIVATE_KEY=0x... \\
    python e2e_runner.py [--deposit-usdc 10] [--asset 0] [--steps deposit,place,...]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional

from eth_account import Account
from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from web3 import Web3
from web3.types import TxReceipt

import hl_helpers as hl
from hl_helpers import PerpAssetMeta
# SOLU-3368 (TODO-10 part 2): Core-settlement reconciliation for fire-and-forget sends.
from reconcile import core_wei_to_human, reconcile_core_send


# -----------------------------------------------------------------------------
# Loading
# -----------------------------------------------------------------------------

@dataclass
class Ctx:
    w3: Web3
    info: Any  # hyperliquid.info.Info
    vault: Any  # web3 contract
    usdc: Any   # web3 contract
    vault_addr: str
    usdc_addr: str
    operator: Account
    alice: Account
    asset_idx: int
    asset_meta: PerpAssetMeta
    deposit_usdc: float
    network: str
    console: Console = field(default_factory=Console)
    failures: list[str] = field(default_factory=list)
    # SOLU-3368 (TODO-10 part 2): reconcile-after-recover controls. Live funded send is a
    # HUMAN GATE — default off (the reconcile step runs read-only/DRY-RUN unless enabled).
    reconcile_live: bool = False
    reconcile_dest: Optional[str] = None


def load_abi(name: str) -> list[dict]:
    out_dir = Path("out") / f"{name}.sol" / f"{name}.json"
    return json.loads(out_dir.read_text())["abi"]


def build_ctx(args: argparse.Namespace) -> Ctx:
    artifact = json.loads(Path(args.artifact).read_text())
    vault_addr = Web3.to_checksum_address(artifact["vault"])
    usdc_addr = Web3.to_checksum_address(artifact["asset"])

    rpc = args.rpc_url or os.environ["HYPEREVM_RPC_MAINNET"]
    w3 = Web3(Web3.HTTPProvider(rpc))
    assert w3.is_connected(), f"RPC not reachable: {rpc}"

    vault_abi = load_abi("HyperCoreVault")
    # Minimal ERC20 ABI for USDC
    erc20_abi = [
        {"type": "function", "name": "balanceOf", "stateMutability": "view",
         "inputs": [{"name": "a", "type": "address"}], "outputs": [{"type": "uint256"}]},
        {"type": "function", "name": "approve", "stateMutability": "nonpayable",
         "inputs": [{"name": "s", "type": "address"}, {"name": "v", "type": "uint256"}],
         "outputs": [{"type": "bool"}]},
        {"type": "function", "name": "decimals", "stateMutability": "view",
         "inputs": [], "outputs": [{"type": "uint8"}]},
        {"type": "function", "name": "allowance", "stateMutability": "view",
         "inputs": [{"name": "o", "type": "address"}, {"name": "s", "type": "address"}],
         "outputs": [{"type": "uint256"}]},
    ]
    vault = w3.eth.contract(address=vault_addr, abi=vault_abi)
    usdc = w3.eth.contract(address=usdc_addr, abi=erc20_abi)

    operator = Account.from_key(args.operator_key or os.environ["OPERATOR_PRIVATE_KEY"])
    alice = Account.from_key(args.alice_key or os.environ["ALICE_PRIVATE_KEY"])

    info = hl.make_info(args.network)
    asset_meta = hl.get_perp_meta(info, args.asset)

    # SOLU-3368: reconcile-after-recover dest (checksummed if provided). getattr keeps this
    # robust if the arg is absent on a differently-parsed invocation.
    reconcile_dest = getattr(args, "reconcile_dest", None)
    if reconcile_dest:
        reconcile_dest = Web3.to_checksum_address(reconcile_dest)

    return Ctx(
        w3=w3, info=info, vault=vault, usdc=usdc,
        vault_addr=vault_addr, usdc_addr=usdc_addr,
        operator=operator, alice=alice,
        asset_idx=args.asset, asset_meta=asset_meta,
        deposit_usdc=args.deposit_usdc, network=args.network,
        reconcile_live=bool(getattr(args, "reconcile_live", False)),
        reconcile_dest=reconcile_dest,
    )


# -----------------------------------------------------------------------------
# Tx helpers
# -----------------------------------------------------------------------------

def send_tx(ctx: Ctx, account: Account, fn, *, gas: int = 600_000, value: int = 0) -> TxReceipt:
    tx = fn.build_transaction({
        "from": account.address,
        "nonce": ctx.w3.eth.get_transaction_count(account.address),
        "gas": gas,
        "gasPrice": ctx.w3.eth.gas_price,
        "value": value,
        "chainId": ctx.w3.eth.chain_id,
    })
    signed = account.sign_transaction(tx)
    h = ctx.w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = ctx.w3.eth.wait_for_transaction_receipt(h)
    if receipt.status != 1:
        raise RuntimeError(f"tx reverted: {h.hex()}")
    return receipt


def parse_event(ctx: Ctx, receipt: TxReceipt, event_name: str) -> Optional[dict]:
    ev = getattr(ctx.vault.events, event_name)()
    logs = ev.process_receipt(receipt)
    if not logs:
        return None
    return dict(logs[0]["args"])


# Minimal ABI for Circle's CoreDepositWallet (audit G2) — read-only surface.
WALLET_ABI = [
    {"type": "function", "name": "token", "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "address"}]},
    {"type": "function", "name": "tokenSystemAddress", "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "address"}]},
    {"type": "function", "name": "paused", "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "bool"}]},
]

TOKEN_INFO_PRECOMPILE = "0x000000000000000000000000000000000000080C"


def core_deposit_wallet(ctx: Ctx):
    """The vault's configured CoreDepositWallet contract handle, or None (legacy mode)."""
    addr = ctx.vault.functions.coreDepositWallet().call()
    if int(addr, 16) == 0:
        return None
    return ctx.w3.eth.contract(address=Web3.to_checksum_address(addr), abi=WALLET_ABI)


def token_info_evm_contract(ctx: Ctx, token_index: int = 0) -> str:
    """Raw tokenInfo(index).evmContract via the live precompile (word 4 of the tuple body)."""
    data = "0x" + format(token_index, "064x")
    ret = ctx.w3.eth.call({"to": TOKEN_INFO_PRECOMPILE, "data": data})
    return "0x" + ret[32 + 4 * 32 + 12 : 32 + 5 * 32].hex()


def usdc_units(human: float) -> int:
    return int(round(human * 1e6))


def core_wei_usdc(human: float) -> int:
    """USDC on Core has 8 decimals."""
    return int(round(human * 1e8))


def _order_size(ctx: "Ctx", mark: float, target_usd: float = 12.0) -> float:
    """Smallest size (respecting szDecimals) whose notional clears HL's ~$10 min."""
    step = 10 ** (-ctx.asset_meta.sz_decimals)
    return max(step, round((target_usd / mark) / step) * step)


# -----------------------------------------------------------------------------
# Wait helper for async bridge / Core settlement
# -----------------------------------------------------------------------------

def wait_for(predicate: Callable[[], bool], *, timeout_s: int = 30, poll_s: float = 1.5,
             label: str = "settlement") -> bool:
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return True
        time.sleep(poll_s)
    return False


# -----------------------------------------------------------------------------
# Steps
# -----------------------------------------------------------------------------

def step_preflight(ctx: Ctx) -> bool:
    ctx.console.rule("[bold]preflight")
    chain_id = ctx.w3.eth.chain_id
    alice_bal_eth = ctx.w3.eth.get_balance(ctx.alice.address)
    op_bal_eth = ctx.w3.eth.get_balance(ctx.operator.address)
    alice_bal_usdc = ctx.usdc.functions.balanceOf(ctx.alice.address).call()

    tbl = Table(show_header=False, box=None)
    tbl.add_row("chain id", str(chain_id))
    tbl.add_row("network", ctx.network)
    tbl.add_row("vault", ctx.vault_addr)
    tbl.add_row("usdc", ctx.usdc_addr)
    tbl.add_row("operator", ctx.operator.address)
    tbl.add_row("operator HYPE", str(ctx.w3.from_wei(op_bal_eth, "ether")))
    tbl.add_row("alice", ctx.alice.address)
    tbl.add_row("alice HYPE", str(ctx.w3.from_wei(alice_bal_eth, "ether")))
    tbl.add_row("alice USDC", f"{alice_bal_usdc / 1e6:,.6f}")
    tbl.add_row("asset", f"{ctx.asset_meta.name} (index {ctx.asset_idx}, szDec {ctx.asset_meta.sz_decimals})")
    ctx.console.print(tbl)

    ok = True
    if alice_bal_eth == 0:
        ctx.console.print("[red]alice has no HYPE for gas — drip from faucet[/red]")
        ok = False
    if op_bal_eth == 0:
        ctx.console.print("[red]operator has no HYPE for gas — drip from faucet[/red]")
        ok = False
    if alice_bal_usdc < usdc_units(ctx.deposit_usdc):
        ctx.console.print(f"[red]alice needs ≥ {ctx.deposit_usdc} USDC — drip from faucet[/red]")
        ok = False

    # Audit G2: wallet-mode vaults must agree with the live chain before any push.
    wallet = core_deposit_wallet(ctx)
    if wallet is not None:
        w_token = wallet.functions.token().call()
        w_paused = wallet.functions.paused().call()
        w_sys = wallet.functions.tokenSystemAddress().call()
        reserve = ctx.usdc.functions.balanceOf(wallet.address).call() / 1e6
        linked = token_info_evm_contract(ctx, 0).lower()
        ctx.console.print(
            f"coreDepositWallet: {wallet.address}  paused={w_paused}  reserve={reserve:,.2f} USDC"
        )
        if w_token.lower() != ctx.usdc_addr.lower():
            ctx.console.print(f"[red]wallet.token() {w_token} != asset {ctx.usdc_addr}[/red]")
            ok = False
        if w_paused:
            ctx.console.print("[red]CoreDepositWallet is PAUSED — both bridge directions stalled[/red]")
            ok = False
        if w_sys.lower() != "0x2000000000000000000000000000000000000000":
            ctx.console.print(f"[red]wallet.tokenSystemAddress() unexpected: {w_sys}[/red]")
            ok = False
        if linked != wallet.address.lower():
            ctx.console.print(f"[red]tokenInfo(0).evmContract {linked} != wallet — push/pull would diverge[/red]")
            ok = False
    else:
        ctx.console.print("[yellow]legacy-mode vault (no CoreDepositWallet) — direct system-address route[/yellow]")
    return ok


def step_deposit(ctx: Ctx) -> bool:
    ctx.console.rule("[bold]deposit")
    amount = usdc_units(ctx.deposit_usdc)

    nav_before = ctx.vault.functions.totalAssets().call()
    shares_before = ctx.vault.functions.balanceOf(ctx.alice.address).call()

    send_tx(ctx, ctx.alice, ctx.usdc.functions.approve(ctx.vault_addr, amount), gas=80_000)
    receipt = send_tx(ctx, ctx.alice, ctx.vault.functions.deposit(amount, ctx.alice.address))
    ev = parse_event(ctx, receipt, "Deposit")
    ctx.console.print(f"Deposit event: {ev}")

    nav_after = ctx.vault.functions.totalAssets().call()
    shares_after = ctx.vault.functions.balanceOf(ctx.alice.address).call()
    ctx.console.print(f"NAV: {nav_before/1e6} → {nav_after/1e6} USDC")
    ctx.console.print(f"alice shares: {shares_before} → {shares_after}")

    ok = (nav_after - nav_before) >= amount - 1 and shares_after > shares_before
    if not ok:
        ctx.failures.append("deposit did not update NAV/shares as expected")
    return ok


def step_core_status(ctx: Ctx) -> bool:
    """Read-only: report the vault's Core account state. Useful when running
    with --skip-bridge (testnet MockUSDC), to verify you've manually funded
    the vault's Core address via `seed_vault_core.py` before placing orders."""
    ctx.console.rule("[bold]vault Core account status")
    spot = hl.spot_balance(ctx.info, ctx.vault_addr, 0)
    perp_summary = hl.user_state(ctx.info, ctx.vault_addr).get("marginSummary", {})
    perp_value = float(perp_summary.get("accountValue", 0))
    on_chain_spot = ctx.vault.functions.coreSpotUsdc().call() / 1e6
    on_chain_perp = ctx.vault.functions.perpWithdrawable().call() / 1e6
    ctx.console.print(f"HL API spot USDC : {spot:.6f}")
    ctx.console.print(f"HL API perp value: {perp_value:.6f}")
    ctx.console.print(f"vault.coreSpotUsdc()    : {on_chain_spot:.6f}")
    ctx.console.print(f"vault.perpWithdrawable(): {on_chain_perp:.6f}")
    if spot == 0 and perp_value == 0:
        ctx.console.print("[yellow]vault Core account is empty — fund it via:[/yellow]")
        ctx.console.print(f"  VAULT_ADDRESS={ctx.vault_addr} OPERATOR_PRIVATE_KEY=... "
                          f"USDC_AMOUNT=5 NETWORK={ctx.network} python scripts/python/seed_vault_core.py")
    return True


def step_wallet_status(ctx: Ctx) -> bool:
    """Read-only: the CoreDepositWallet's live state + the vault's standing
    allowance to it (must be 0 at rest — the push leaves none behind)."""
    ctx.console.rule("[bold]CoreDepositWallet status (audit G2)")
    wallet = core_deposit_wallet(ctx)
    if wallet is None:
        ctx.console.print("[yellow]legacy-mode vault — no CoreDepositWallet configured[/yellow]")
        return True
    reserve = ctx.usdc.functions.balanceOf(wallet.address).call() / 1e6
    allowance = ctx.usdc.functions.allowance(ctx.vault_addr, wallet.address).call()
    ctx.console.print(f"wallet:            {wallet.address}")
    ctx.console.print(f"wallet.token():    {wallet.functions.token().call()}")
    ctx.console.print(f"wallet.paused():   {wallet.functions.paused().call()}")
    ctx.console.print(f"wallet reserve:    {reserve:,.2f} USDC")
    ctx.console.print(f"vault->wallet allowance: {allowance} (must be 0 at rest)")
    if allowance != 0:
        ctx.failures.append("wallet_status: standing allowance to the wallet is non-zero")
        return False
    return True


def step_push(ctx: Ctx) -> bool:
    ctx.console.rule("[bold]push to Core (EVM USDC → Core spot, via CoreDepositWallet in wallet mode)")
    push_amount = int(usdc_units(ctx.deposit_usdc) * 0.8)

    wallet = core_deposit_wallet(ctx)
    wallet_before = ctx.usdc.functions.balanceOf(wallet.address).call() if wallet else 0
    spot_before = hl.spot_balance(ctx.info, ctx.vault_addr, 0)
    receipt = send_tx(ctx, ctx.operator, ctx.vault.functions.pushToCore(push_amount))
    ev = parse_event(ctx, receipt, "BridgeDeposit")
    ctx.console.print(f"BridgeDeposit event: {ev}")

    if wallet:
        wallet_after = ctx.usdc.functions.balanceOf(wallet.address).call()
        ctx.console.print(
            f"wallet reserve: {wallet_before/1e6:,.2f} → {wallet_after/1e6:,.2f} "
            f"(+{(wallet_after-wallet_before)/1e6:.6f})"
        )
        if wallet_after - wallet_before != push_amount:
            ctx.failures.append("push: wallet reserve delta != pushed amount")
        idle_after_push = ctx.usdc.functions.balanceOf(ctx.vault_addr).call()
        ctx.console.print(f"vault idle after push: {idle_after_push/1e6:.6f}")

    # First credit to a fresh Core account can take a little longer (audit G2).
    expected_spot = spot_before + push_amount / 1e6
    ok = wait_for(
        lambda: hl.spot_balance(ctx.info, ctx.vault_addr, 0) >= expected_spot - 0.001,
        timeout_s=60, label="core spot credit",
    )
    spot_after = hl.spot_balance(ctx.info, ctx.vault_addr, 0)
    ctx.console.print(f"Core spot USDC: {spot_before:.6f} → {spot_after:.6f}")
    on_chain_spot = ctx.vault.functions.coreSpotUsdc().call()
    ctx.console.print(f"vault.coreSpotUsdc(): {on_chain_spot/1e6:.6f}")
    # The on-chain NAV leg (precompile) must agree with the HL API view.
    if ok and abs(on_chain_spot / 1e6 - spot_after) > 0.01:
        ctx.failures.append("push: coreSpotUsdc() precompile disagrees with HL API spot balance")
        ok = False
    if not ok:
        ctx.failures.append("Core spot credit did not appear within timeout")
    return ok


def step_spot_to_perp(ctx: Ctx) -> bool:
    ctx.console.rule("[bold]spot → perp class transfer")
    amount = int(usdc_units(ctx.deposit_usdc) * 0.5)
    spot_now_human = hl.spot_balance(ctx.info, ctx.vault_addr, 0)
    if spot_now_human * 1e6 < amount:
        ctx.console.print(
            f"[red]vault Core spot has {spot_now_human} USDC, need ≥ {amount/1e6} for transfer[/red]"
        )
        ctx.console.print(
            f"[yellow]fund the vault Core address ({ctx.vault_addr}) via:[/yellow]\n"
            f"  USDC_AMOUNT={ctx.deposit_usdc} VAULT_ADDRESS={ctx.vault_addr} "
            f"OPERATOR_PRIVATE_KEY=$YOUR_HL_KEY NETWORK={ctx.network} "
            f"python scripts/python/seed_vault_core.py"
        )
        ctx.failures.append("vault Core spot underfunded for spot_to_perp")
        return False
    perp_before = float(hl.user_state(ctx.info, ctx.vault_addr).get("marginSummary", {}).get("accountValue", 0))

    receipt = send_tx(ctx, ctx.operator, ctx.vault.functions.usdSpotToPerp(amount))
    ev = parse_event(ctx, receipt, "UsdClassTransferSubmitted")
    ctx.console.print(f"UsdClassTransfer event: {ev}")

    expected_perp = perp_before + amount / 1e6
    ok = wait_for(
        lambda: float(hl.user_state(ctx.info, ctx.vault_addr).get("marginSummary", {}).get("accountValue", 0))
                >= expected_perp - 0.01,
        timeout_s=20, label="perp class transfer",
    )
    perp_after = float(hl.user_state(ctx.info, ctx.vault_addr).get("marginSummary", {}).get("accountValue", 0))
    on_chain_perp = ctx.vault.functions.perpWithdrawable().call() / 1e6
    ctx.console.print(f"Perp account value: {perp_before:.6f} → {perp_after:.6f}")
    ctx.console.print(f"vault.perpWithdrawable(): {on_chain_perp:.6f}")
    if not ok:
        ctx.failures.append("perp class transfer did not settle within timeout")
    return ok


def step_place(ctx: Ctx) -> tuple[bool, Optional[int]]:
    ctx.console.rule(f"[bold]place limit order ({ctx.asset_meta.name})")

    oracle = hl.perp_oracle_px(ctx.info, ctx.asset_idx)
    mark = hl.perp_mark_px(ctx.info, ctx.asset_idx)
    # 1% below mark, post-only — should rest, not cross
    human_px = ctx.asset_meta.round_to_tick(mark * 0.99)
    human_sz = _order_size(ctx, mark)  # ~$12 notional — clears HL's $10 minimum, under the leverage cap
    enc_px = ctx.asset_meta.encode_px(human_px)
    enc_sz = ctx.asset_meta.encode_sz(human_sz)
    ctx.console.print(f"oracle: {oracle}  mark: {mark}  limit: {human_px} (enc {enc_px})")
    ctx.console.print(f"size: {human_sz} {ctx.asset_meta.name} (enc {enc_sz})")

    TIF_ALO = 1  # HL CoreWriter tif: 1=Alo (post-only), 2=Gtc, 3=Ioc. 0 is invalid → silently dropped.
    receipt = send_tx(ctx, ctx.operator,
                      ctx.vault.functions.placeLimitOrder(
                          ctx.asset_idx, True, enc_px, enc_sz, False, TIF_ALO),
                      gas=800_000)
    ev = parse_event(ctx, receipt, "LimitOrderSubmitted")
    if ev is None:
        ctx.failures.append("LimitOrderSubmitted event missing")
        return False, None
    cloid = int(ev["cloid"])
    ctx.console.print(f"submitted with cloid {cloid} (0x{cloid:032x})")

    ok = wait_for(
        lambda: hl.find_resting_by_cloid(ctx.info, ctx.vault_addr, cloid) is not None,
        timeout_s=20, label="order resting on HL book",
    )
    if ok:
        order = hl.find_resting_by_cloid(ctx.info, ctx.vault_addr, cloid)
        ctx.console.print(f"resting on HL: {order}")
    else:
        ctx.failures.append(f"cloid {cloid} did not appear in open orders (rejected by HL?)")
    return ok, cloid


def step_cancel(ctx: Ctx, cloid: int) -> bool:
    ctx.console.rule("[bold]cancel by cloid")
    receipt = send_tx(ctx, ctx.operator, ctx.vault.functions.cancelOrderByCloid(ctx.asset_idx, cloid))
    ev = parse_event(ctx, receipt, "OrderCancelByCloidSubmitted")
    ctx.console.print(f"cancel event: {ev}")

    ok = wait_for(
        lambda: hl.find_resting_by_cloid(ctx.info, ctx.vault_addr, cloid) is None,
        timeout_s=20, label="cancel reflected on HL",
    )
    if not ok:
        ctx.failures.append(f"cloid {cloid} still on book after cancel timeout")
    return ok


def step_fill(ctx: Ctx) -> bool:
    """Confirm an order actually FILLS (not just rests): a marketable IOC buy
    that crosses the book, verified via HL `userFills`, then flattened with a
    reduce-only IOC. Opens a real position briefly and pays taker fees."""
    TIF_IOC = 3
    ctx.console.rule(f"[bold]fill-confirmation ({ctx.asset_meta.name})")
    mark = hl.perp_mark_px(ctx.info, ctx.asset_idx)
    human_sz = _order_size(ctx, mark)
    buy_px = ctx.asset_meta.round_to_tick(mark * 1.005)  # 0.5% through the ask — crosses
    fills_before = len(hl.user_fills(ctx.info, ctx.vault_addr))

    receipt = send_tx(ctx, ctx.operator,
                      ctx.vault.functions.placeLimitOrder(
                          ctx.asset_idx, True,
                          ctx.asset_meta.encode_px(buy_px), ctx.asset_meta.encode_sz(human_sz),
                          False, TIF_IOC),
                      gas=1_500_000)
    parse_event(ctx, receipt, "LimitOrderSubmitted")
    filled = wait_for(
        lambda: len(hl.user_fills(ctx.info, ctx.vault_addr)) > fills_before,
        timeout_s=20, label="taker fill on HL",
    )
    ctx.console.print(f"filled: {filled}")
    if not filled:
        ctx.failures.append("marketable IOC did not fill")

    # Flatten: reduce-only IOC on the opposite side, sized to the open position.
    szi = hl.perp_position_szi(ctx.info, ctx.vault_addr, ctx.asset_meta.name)
    if abs(szi) > 0:
        close_px = ctx.asset_meta.round_to_tick(mark * (0.995 if szi > 0 else 1.005))
        send_tx(ctx, ctx.operator,
                ctx.vault.functions.placeLimitOrder(
                    ctx.asset_idx, szi < 0,
                    ctx.asset_meta.encode_px(close_px), ctx.asset_meta.encode_sz(abs(szi)),
                    True, TIF_IOC),
                gas=1_500_000)
        flat = wait_for(
            lambda: abs(hl.perp_position_szi(ctx.info, ctx.vault_addr, ctx.asset_meta.name)) < abs(szi),
            timeout_s=20, label="position flattened",
        )
        ctx.console.print(f"flattened: {flat}")
        if not flat:
            ctx.failures.append("position not flattened after fill test")
    return filled


def step_perp_to_spot(ctx: Ctx) -> bool:
    ctx.console.rule("[bold]perp → spot class transfer")
    amount = int(usdc_units(ctx.deposit_usdc) * 0.5)
    receipt = send_tx(ctx, ctx.operator, ctx.vault.functions.usdPerpToSpot(amount))
    parse_event(ctx, receipt, "UsdClassTransferSubmitted")
    # Settlement check: perp value drops
    ok = wait_for(
        lambda: ctx.vault.functions.perpWithdrawable().call() < amount,
        timeout_s=20, label="perp→spot transfer reflected",
    )
    perp_after = ctx.vault.functions.perpWithdrawable().call() / 1e6
    ctx.console.print(f"vault.perpWithdrawable() after: {perp_after}")
    return True  # don't gate test pass on exact values — HL precision varies


def step_pull(ctx: Ctx) -> bool:
    ctx.console.rule("[bold]pull from Core (Core spot → EVM USDC)")
    spot_balance_core_wei = int(hl.spot_balance(ctx.info, ctx.vault_addr, 0) * 1e8)
    # Audit G2 (proven live 2026-06-15): the pull is a CoreWriter `send_asset`
    # (action 13) to the token system address — unified HyperCore accounts SILENTLY
    # DROP the legacy `spot_send` (action 6). HyperCore charges a small withdrawal
    # fee (~0.00134 USDC observed) deducted from the Core account ON TOP of the
    # requested amount, so requesting the EXACT full balance leaves nothing to
    # cover the fee and the action is dropped (Core never debits). Pull slightly
    # under the balance so the fee is always covered.
    pull_amount_wei = int(spot_balance_core_wei * 0.998)
    if pull_amount_wei == 0:
        ctx.console.print("[yellow]nothing to pull[/yellow]")
        return True

    # Audit G2 (wallet mode): the Core-side send to the system address triggers the
    # CoreDepositWallet's system-guarded transfer() — native USDC paid from its
    # reserve to the vault. Record the reserve to prove payout provenance.
    wallet = core_deposit_wallet(ctx)
    wallet_before = ctx.usdc.functions.balanceOf(wallet.address).call() if wallet else 0

    idle_before = ctx.usdc.functions.balanceOf(ctx.vault_addr).call()
    receipt = send_tx(ctx, ctx.operator, ctx.vault.functions.pullFromCore(pull_amount_wei))
    ev = parse_event(ctx, receipt, "BridgeWithdraw")
    ctx.console.print(f"BridgeWithdraw event: {ev}")

    expected_evm = pull_amount_wei // 100  # Core 8dp wei -> EVM 6dp units
    ok = wait_for(
        lambda: ctx.usdc.functions.balanceOf(ctx.vault_addr).call() > idle_before,
        timeout_s=60, label="ERC20 credit to vault from bridge",
    )
    idle_after = ctx.usdc.functions.balanceOf(ctx.vault_addr).call()
    ctx.console.print(
        f"vault idle USDC: {idle_before/1e6:.6f} → {idle_after/1e6:.6f} "
        f"(expected +{expected_evm/1e6:.6f})"
    )
    if ok and abs((idle_after - idle_before) - expected_evm) > 10_000:  # $0.01 dust tolerance
        ctx.failures.append("pull: idle delta != floor(amountWei/100)")
        ok = False
    if wallet:
        wallet_after = ctx.usdc.functions.balanceOf(wallet.address).call()
        ctx.console.print(
            f"wallet reserve: {wallet_before/1e6:,.2f} → {wallet_after/1e6:,.2f} "
            f"({(wallet_after-wallet_before)/1e6:+.6f}) — payout provenance"
        )
    if not ok:
        ctx.failures.append("bridge did not credit ERC20 within timeout")
    return ok


def step_redeem(ctx: Ctx) -> bool:
    ctx.console.rule("[bold]redeem all shares")
    shares = ctx.vault.functions.balanceOf(ctx.alice.address).call()
    if shares == 0:
        ctx.console.print("[yellow]alice has no shares[/yellow]")
        return True

    usdc_before = ctx.usdc.functions.balanceOf(ctx.alice.address).call()
    receipt = send_tx(ctx, ctx.alice,
                      ctx.vault.functions.redeem(shares, ctx.alice.address, ctx.alice.address),
                      gas=400_000)
    ev = parse_event(ctx, receipt, "Withdraw")
    ctx.console.print(f"Withdraw event: {ev}")

    usdc_after = ctx.usdc.functions.balanceOf(ctx.alice.address).call()
    delta = (usdc_after - usdc_before) / 1e6
    ctx.console.print(f"alice USDC: {usdc_before/1e6:.6f} → {usdc_after/1e6:.6f}  (+{delta:.6f})")

    final_shares = ctx.vault.functions.balanceOf(ctx.alice.address).call()
    ok = final_shares == 0 and delta > 0
    if not ok:
        ctx.failures.append("redeem did not zero shares or no USDC returned")
    return ok


# -----------------------------------------------------------------------------
# Withdrawal-queue / redemption-loop steps (live confirmation of the fork findings)
#
# These exercise the bespoke escrow queue on a REAL deployed vault and confirm the
# residuals the fork suite cannot reach (NAV > idle, real Core repatriation). Run them
# as an explicit sequence, e.g.:
#   --steps deposit,push,spot_to_perp,request_withdraw,fulfill_withdraw,operator_repatriate,fulfill_withdraw,cancel_withdraw
# The middle fulfill_withdraw is expected to be a NO-OP (Finding E) while capital is on
# Core; the one after operator_repatriate is where the LP actually gets paid — IF the
# asset's Core bridge is usable (see Finding G / operator_repatriate).
# -----------------------------------------------------------------------------


def step_request_withdraw(ctx: Ctx) -> bool:
    ctx.console.rule("[bold]request withdrawal (escrow shares)")
    shares = ctx.vault.functions.balanceOf(ctx.alice.address).call()
    if shares == 0:
        ctx.console.print("[yellow]alice has no shares to request[/yellow]")
        return True
    receipt = send_tx(ctx, ctx.alice, ctx.vault.functions.requestWithdraw(shares), gas=300_000)
    parse_event(ctx, receipt, "WithdrawalRequested")
    pending = ctx.vault.functions.pendingWithdrawalShares(ctx.alice.address).call()
    free = ctx.vault.functions.balanceOf(ctx.alice.address).call()
    ctx.console.print(f"escrowed {pending} shares; alice free balance now {free}")
    ok = pending == shares and free == 0
    if not ok:
        ctx.failures.append("requestWithdraw did not escrow shares correctly")
    return ok


def step_fulfill_withdraw(ctx: Ctx) -> bool:
    ctx.console.rule("[bold]fulfill withdrawal (keeper; pays from idle ONLY)")
    pending = ctx.vault.functions.pendingWithdrawalShares(ctx.alice.address).call()
    if pending == 0:
        ctx.console.print("[yellow]no pending withdrawal[/yellow]")
        return True
    idle = ctx.vault.functions.idleUsdc().call()
    usdc_before = ctx.usdc.functions.balanceOf(ctx.alice.address).call()
    ctx.console.print(f"vault idle USDC: {idle/1e6:.6f}  (fulfill can only pay from this)")
    # Anyone may call (permissionless); the operator acts as the keeper here.
    receipt = send_tx(ctx, ctx.operator, ctx.vault.functions.fulfillWithdraw(ctx.alice.address), gas=400_000)
    parse_event(ctx, receipt, "WithdrawalFulfilled")
    paid = (ctx.usdc.functions.balanceOf(ctx.alice.address).call() - usdc_before) / 1e6
    pending_after = ctx.vault.functions.pendingWithdrawalShares(ctx.alice.address).call()
    ctx.console.print(f"alice paid {paid:.6f} USDC; pending {pending} → {pending_after}")
    if idle == 0 and paid == 0:
        ctx.console.print("[cyan]no-op as expected — value is off idle (Finding E)[/cyan]")
    return True  # a no-op with idle==0 is a legitimate, expected outcome


def step_cancel_withdraw(ctx: Ctx) -> bool:
    ctx.console.rule("[bold]cancel withdrawal (return escrowed shares)")
    pending = ctx.vault.functions.pendingWithdrawalShares(ctx.alice.address).call()
    if pending == 0:
        ctx.console.print("[yellow]no pending withdrawal to cancel[/yellow]")
        return True
    free_before = ctx.vault.functions.balanceOf(ctx.alice.address).call()
    send_tx(ctx, ctx.alice, ctx.vault.functions.cancelWithdrawRequest(), gas=300_000)
    free_after = ctx.vault.functions.balanceOf(ctx.alice.address).call()
    pending_after = ctx.vault.functions.pendingWithdrawalShares(ctx.alice.address).call()
    ctx.console.print(f"alice free shares: {free_before} → {free_after}; pending now {pending_after}")
    ok = free_after == free_before + pending and pending_after == 0
    if not ok:
        ctx.failures.append("cancelWithdrawRequest did not return escrowed shares")
    return ok


def step_operator_repatriate(ctx: Ctx) -> bool:
    ctx.console.rule("[bold]operator repatriate (perp → spot → EVM idle)")
    amount = int(usdc_units(ctx.deposit_usdc) * 0.5)
    try:
        send_tx(ctx, ctx.operator, ctx.vault.functions.usdPerpToSpot(amount))
    except Exception as e:
        ctx.console.print(f"[yellow]usdPerpToSpot reverted/failed: {e}[/yellow]")
    spot_core_wei = int(hl.spot_balance(ctx.info, ctx.vault_addr, 0) * 1e8)
    if spot_core_wei == 0:
        ctx.console.print("[yellow]no Core spot to pull[/yellow]")
        return True
    idle_before = ctx.usdc.functions.balanceOf(ctx.vault_addr).call()
    try:
        send_tx(ctx, ctx.operator, ctx.vault.functions.pullFromCore(spot_core_wei))
    except Exception as e:
        # Audit G2: for a wallet-mode vault this should NOT revert (the Core-side
        # send is fire-and-forget; the CoreDepositWallet pays the EVM side). A
        # revert here is only expected for a LEGACY vault on a blacklisted asset
        # (the original Finding-G posture) or an unrelated tx failure.
        ctx.console.print(f"[red]pullFromCore reverted (legacy/blacklisted asset, or tx failure): {e}[/red]")
        ctx.failures.append(f"repatriate: pullFromCore reverted: {e}")
        return False
    ok = wait_for(lambda: ctx.usdc.functions.balanceOf(ctx.vault_addr).call() > idle_before,
                  timeout_s=60, label="bridge credit to vault idle")
    idle_after = ctx.usdc.functions.balanceOf(ctx.vault_addr).call()
    ctx.console.print(f"vault idle USDC: {idle_before/1e6:.6f} → {idle_after/1e6:.6f}")
    if not ok:
        ctx.failures.append("repatriate: bridge did not credit idle (wallet paused? legacy asset?)")
    return ok


def step_reconcile_after_recover(ctx: Ctx) -> bool:
    """SOLU-3368 (TODO-10 part 2): reconcile Core state after the fire-and-forget
    `operatorRecoverSpot` (or any Core-side send) and signal a retry if Core never settled.

    CoreWriter actions are fire-and-forget — the EVM tx succeeds and `OperatorSpotRecovered`
    fires *even if HyperCore drops the action* (fee uncovered, wallet paused, wrong action id).
    A keeper therefore can't trust the receipt; it must read the vault's Core USDC balance, send,
    then poll until the Core balance actually falls by ~the sent amount. If it doesn't, the action
    was dropped and the keeper must RETRY (recorded into ctx.failures here).

    Read-only / DRY-RUN by default (the harness default): observes the vault's live Core balance
    and logs the intended reconciliation WITHOUT moving funds, so it's fully exercisable now.
    Live funded execution is a HUMAN GATE — pass `--reconcile-live` (and an allowlisted
    `--reconcile-dest`) to actually submit `operatorRecoverSpot` and reconcile its settlement.
    """
    dry_run = not ctx.reconcile_live
    mode = "DRY-RUN (read-only)" if dry_run else "LIVE (funded send)"
    ctx.console.rule(f"[bold]reconcile after operatorRecoverSpot — fire-and-forget settlement [{mode}]")

    # The vault's Core USDC, normalized to 6dp human (reads the spotBalance precompile on-chain).
    read_core = lambda: ctx.vault.functions.coreSpotUsdc().call() / 1e6
    core_now = read_core()
    ctx.console.print(f"vault.coreSpotUsdc(): {core_now:,.6f} USDC (Core spot, 6dp-normalized)")

    # Recover a small slice — bounded under the balance so the ~0.00134 USDC withdrawal fee is
    # always covered (a send of the EXACT balance is silently dropped — see docs/INTEGRATION.md).
    recover_human = min(ctx.deposit_usdc * 0.5, core_now * 0.5)
    amount_wei = core_wei_usdc(recover_human)  # Core 8dp wei
    expected_dec = core_wei_to_human(amount_wei)  # human USDC the send should remove from Core

    if dry_run:
        res = reconcile_core_send(
            read_core_usdc=read_core, expected_decrease_usdc=expected_dec,
            send=None, wait_for=wait_for, log=ctx.console.print,
            label="operatorRecoverSpot", dry_run=True,
        )
        ctx.console.print(
            f"[cyan]intended live action:[/cyan] operatorRecoverSpot(dest, token=0, "
            f"amountWei={amount_wei}) → would reconcile a Core decrease of ~{expected_dec:,.6f} USDC"
        )
        ctx.console.print(
            "[yellow]DRY-RUN — no funds moved. Re-run with --reconcile-live --reconcile-dest <allowlisted "
            "addr> to submit + reconcile for real (HUMAN GATE).[/yellow]"
        )
        ctx.console.print(f"[dim]{res.note}[/dim]")
        return True

    # ---- LIVE path (human-gated) ----
    dest = ctx.reconcile_dest
    if not dest:
        ctx.console.print("[red]--reconcile-live requires --reconcile-dest <allowlisted address>[/red]")
        ctx.failures.append("reconcile: live mode requested without --reconcile-dest")
        return False
    if not ctx.vault.functions.spotRecoverDest(dest).call():
        ctx.console.print(f"[red]{dest} is NOT on the spotRecoverDest allowlist (C-2) — would revert[/red]")
        ctx.failures.append("reconcile: dest not allowlisted (spotRecoverDest)")
        return False
    if amount_wei == 0:
        ctx.console.print("[yellow]nothing on Core to recover — skipping live reconcile[/yellow]")
        return True

    def _send() -> None:
        receipt = send_tx(ctx, ctx.operator,
                          ctx.vault.functions.operatorRecoverSpot(dest, 0, amount_wei))
        ev = parse_event(ctx, receipt, "OperatorSpotRecovered")
        ctx.console.print(f"OperatorSpotRecovered event (intent, not settlement): {ev}")

    res = reconcile_core_send(
        read_core_usdc=read_core, expected_decrease_usdc=expected_dec,
        send=_send, wait_for=wait_for, log=ctx.console.print,
        timeout_s=60, poll_s=2.0, label="operatorRecoverSpot", dry_run=False,
    )
    if res.needs_retry:
        ctx.failures.append(
            "reconcile: operatorRecoverSpot did not settle on Core within timeout — fire-and-forget "
            "action dropped; keeper must RETRY")
    return res.settled


def step_pause_freeze_check(ctx: Ctx) -> bool:
    ctx.console.rule("[bold]pause posture check (H2: paused vault CAN repatriate; deploy stays blocked)")
    # Pre-H2 this step proved Finding A (pull reverting EnforcedPause, live 2026-06-03).
    # Post-remediation the expectation FLIPS: pullFromCore (Core->EVM, no market risk)
    # must SUCCEED while paused; usdSpotToPerp (deploys risk) must still revert.
    # Needs the caller to hold EMERGENCY_ROLE (throwaway configs: operator == emergency).
    try:
        send_tx(ctx, ctx.operator, ctx.vault.functions.pause())
    except Exception as e:
        ctx.console.print(f"[yellow]pause failed (operator lacks EMERGENCY_ROLE?): {e}[/yellow]")
        return True
    pull_ok = True
    deploy_blocked = False
    try:
        send_tx(ctx, ctx.operator, ctx.vault.functions.pullFromCore(1))
    except Exception as e:
        pull_ok = False
        ctx.console.print(f"[red]pullFromCore reverted while paused (H2 regression): {e}[/red]")
    try:
        send_tx(ctx, ctx.operator, ctx.vault.functions.usdSpotToPerp(1))
    except Exception:
        deploy_blocked = True
    send_tx(ctx, ctx.operator, ctx.vault.functions.unpause())
    ctx.console.print(f"pullFromCore while paused succeeded: {pull_ok}")
    ctx.console.print(f"usdSpotToPerp while paused blocked:  {deploy_blocked}")
    if not pull_ok:
        ctx.failures.append("pause posture: pullFromCore reverted while paused (H2 regression)")
    if not deploy_blocked:
        ctx.failures.append("pause posture: usdSpotToPerp was NOT blocked while paused")
    return pull_ok and deploy_blocked


def step_keeper(ctx: Ctx, args: argparse.Namespace) -> bool:
    """Assessment TODO-4: automated redemption-fulfillment keeper loop.

    Watches WithdrawalRequested, repatriates the material pending claim via the
    fee-guarded send_asset pull (Core->EVM), then calls fulfillWithdraw — recording
    fulfilled LPs + residuals and monitoring the CoreDepositWallet paused() state.
    DRY-RUN by default (reads live state, logs intended actions, sends nothing);
    --keeper-execute opts into the tx-sending (funded, human-gated) mode. The loop
    lives in keeper.py to keep this file focused; it reuses send_tx/wait_for/parse_event.
    """
    import keeper
    config = keeper.KeeperConfig(
        execute=args.keeper_execute,
        poll_s=args.keeper_poll,
        max_iterations=args.keeper_max_iter,
        timeout_s=args.keeper_timeout,
        start_block=args.keeper_start_block,
    )
    return keeper.run_keeper(ctx, config)


# -----------------------------------------------------------------------------
# Orchestration
# -----------------------------------------------------------------------------

ALL_STEPS = ["preflight", "deposit", "core_status", "wallet_status", "push", "spot_to_perp",
             "place", "cancel", "fill", "perp_to_spot", "pull", "redeem"]

# Redemption-loop steps — selected explicitly via --steps (not part of the default run).
# `keeper` (TODO-4) is the automated fulfillment loop; dry-run by default, --keeper-execute to send.
QUEUE_STEPS = ["request_withdraw", "fulfill_withdraw", "operator_repatriate",
               "reconcile_after_recover", "cancel_withdraw", "pause_freeze_check", "keeper"]

# Steps that require a real EVM-side USDC ↔ Core bridge. Skipped automatically
# when the asset has no linked bridge (testnet MockUSDC case).
BRIDGE_STEPS = {"push", "pull"}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact", default=os.environ.get("ARTIFACT"),
                        help="path to deployments/<chain>/<strategy>.json")
    parser.add_argument("--rpc-url", default=os.environ.get("HYPEREVM_RPC_MAINNET"))
    parser.add_argument("--operator-key", default=os.environ.get("OPERATOR_PRIVATE_KEY"))
    parser.add_argument("--alice-key", default=os.environ.get("ALICE_PRIVATE_KEY"))
    parser.add_argument("--deposit-usdc", type=float, default=10.0)
    parser.add_argument("--asset", type=int, default=0, help="perp asset id (default BTC=0)")
    parser.add_argument("--network", default="mainnet", choices=["mainnet", "testnet"])
    parser.add_argument("--steps", default=",".join(ALL_STEPS),
                        help="comma-separated step names or 'all' (lifecycle steps; plus "
                             "redemption-queue steps: request_withdraw, fulfill_withdraw, "
                             "operator_repatriate, cancel_withdraw, pause_freeze_check; and "
                             "'keeper' = the TODO-4 automated fulfillment loop, dry-run unless "
                             "--keeper-execute)")
    parser.add_argument("--skip-bridge", action="store_true",
                        help="omit push/pull steps (use for testnet MockUSDC)")
    # SOLU-3368 (TODO-10 part 2): reconcile_after_recover defaults to read-only/DRY-RUN.
    # Live funded send is a HUMAN GATE — must be explicitly enabled.
    parser.add_argument("--reconcile-live", action="store_true",
                        help="reconcile_after_recover: actually submit operatorRecoverSpot and "
                             "reconcile Core settlement (HUMAN GATE; default is read-only DRY-RUN)")
    parser.add_argument("--reconcile-dest", default=os.environ.get("RECONCILE_DEST"),
                        help="reconcile_after_recover: allowlisted (spotRecoverDest) destination "
                             "for the live operatorRecoverSpot send")
    # Keeper loop (Assessment TODO-4) — runs via `--steps keeper`. DRY-RUN by default:
    # it reads live state and logs intended actions WITHOUT sending txs. Sending txs
    # (the funded battle-test) is a human gate behind the explicit --keeper-execute flag.
    parser.add_argument("--keeper-execute", action="store_true",
                        help="keeper: actually SEND repatriation/fulfill txs (default: dry-run "
                             "reads + logs only). The funded run is human-gated — use with care.")
    parser.add_argument("--keeper-poll", type=float, default=5.0,
                        help="keeper: seconds between passes (default 5)")
    parser.add_argument("--keeper-max-iter", type=int, default=12,
                        help="keeper: max passes before stopping (0 = until --keeper-timeout)")
    parser.add_argument("--keeper-timeout", type=int, default=600,
                        help="keeper: overall wall-clock bound in seconds (default 600)")
    parser.add_argument("--keeper-start-block", type=int, default=None,
                        help="keeper: WithdrawalRequested scan start block (default: head - 5000)")
    args = parser.parse_args()

    if not args.artifact:
        print("--artifact (or $ARTIFACT) required", file=sys.stderr)
        return 2

    ctx = build_ctx(args)
    steps = ALL_STEPS if args.steps == "all" else args.steps.split(",")
    if args.skip_bridge:
        steps = [s for s in steps if s not in BRIDGE_STEPS]

    ctx.console.print(Panel.fit(
        f"HyperCoreVault {ctx.network} e2e\nvault={ctx.vault_addr}\nsteps={steps}",
        title="setup"))

    cloid: Optional[int] = None
    for step in steps:
        try:
            if step == "preflight":
                if not step_preflight(ctx):
                    ctx.console.print("[red]preflight failed[/red]")
                    return 1
            elif step == "deposit":
                step_deposit(ctx)
            elif step == "core_status":
                step_core_status(ctx)
            elif step == "wallet_status":
                step_wallet_status(ctx)
            elif step == "push":
                step_push(ctx)
            elif step == "spot_to_perp":
                step_spot_to_perp(ctx)
            elif step == "place":
                _, cloid = step_place(ctx)
            elif step == "cancel":
                if cloid is None:
                    ctx.console.print("[yellow]no cloid from place step — skipping cancel[/yellow]")
                else:
                    step_cancel(ctx, cloid)
            elif step == "fill":
                step_fill(ctx)
            elif step == "perp_to_spot":
                step_perp_to_spot(ctx)
            elif step == "pull":
                step_pull(ctx)
            elif step == "redeem":
                step_redeem(ctx)
            elif step == "request_withdraw":
                step_request_withdraw(ctx)
            elif step == "fulfill_withdraw":
                step_fulfill_withdraw(ctx)
            elif step == "operator_repatriate":
                step_operator_repatriate(ctx)
            elif step == "reconcile_after_recover":
                step_reconcile_after_recover(ctx)
            elif step == "cancel_withdraw":
                step_cancel_withdraw(ctx)
            elif step == "pause_freeze_check":
                step_pause_freeze_check(ctx)
            elif step == "keeper":
                step_keeper(ctx, args)
            else:
                ctx.console.print(f"[yellow]unknown step: {step}[/yellow]")
        except Exception as e:
            ctx.console.print(f"[red]step {step} raised: {e}[/red]")
            ctx.failures.append(f"{step}: {e}")

    ctx.console.rule("[bold]summary")
    if ctx.failures:
        ctx.console.print(f"[red]{len(ctx.failures)} failure(s):[/red]")
        for f in ctx.failures:
            ctx.console.print(f"  - {f}")
        return 1
    ctx.console.print("[green]all steps passed[/green]")
    return 0


if __name__ == "__main__":
    sys.exit(main())

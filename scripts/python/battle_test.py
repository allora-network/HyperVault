#!/usr/bin/env python3
"""HyperVault 10-account live battle-test orchestrator.

Drives ten throwaway LPs (+ an unprivileged "trigger" caller) through the full
redemption / escape / fee matrix on HyperEVM mainnet, in load-bearing phases.

DRY-RUN-FIRST: without ``--execute`` NO transaction is ever sent — every
state-changing call routes through `send()`, which in dry-run only reads live
state and logs the intended action (mirrors keeper.py's ``--keeper-execute``).
This lets the whole matrix be validated against live read-state before a single
dollar moves. Funds only move with ``--execute`` (a human gate).

It REUSES e2e_runner's stateless helpers (send_tx/parse_event/wait_for/usdc_units)
and the multi-account layer in accounts.py; it does not modify the audited
single-lifecycle harness.

Coverage matrix (account -> scenarios), see --plan:
  A  happy-path deposit + idle-capped redeem (full LP1 / partial LP2); mgmt accrual; NAV-moving concurrency (LP8)
  B  withdraw>idle -> request -> keeper fulfill (full LP3 / partial+re-prioritize LP4); Finding-F race (LP5 vs LP6); cancel+re-request (LP7); perf-fee realize (LP3)
  C  soft barriers ON then OFF (LP7 lockup/cooldown, LP8 gate); queue path proven ungated
  D  emergencyShutdown (deposits blocked, redeems work) + pause/repatriate-while-paused + withdrawal-fee edge
  E  overdue -> permissionless prioritizeOverdue -> fulfill (LP9 + trigger)
  F  permissionless escape brake end-to-end (LP10 + trigger): triggerEscape -> 4 legs -> fulfill -> exitEscape  [LAST]
  Z  wind-down: recover all funds, decommission

Pre-reqs driven OUT OF BAND via admin_timelock.py under the 24h timelock:
  setRequestFulfillmentWindow(short) before B/E/F; setEscapeGraceSeconds(4h) before F;
  setRedemptionBarriers(...) on for C then back to 0. See docs/LIVE_SPIKE_RUNBOOK.md.

Usage (run from repo root):
    python3 scripts/python/battle_test.py --plan                 # print matrix, run nothing
    ARTIFACT=deployments/mainnet/spike.json \\
      python3 scripts/python/battle_test.py --phase A            # DRY-RUN (no funds)
    ... --phase A --execute                                      # funds move (human gate)
    ... --scenario b --resume
"""
from __future__ import annotations

import argparse
import time
from typing import Callable, Optional

import hl_helpers as hl
import journal
import state_store
from accounts import LP_NAMES, add_common_args, build_battle_ctx, BattleCtx
from e2e_runner import (core_deposit_wallet, core_wei_usdc, parse_event, send_tx,
                        usdc_units, wait_for)

DEFAULT_STATE = "scripts/python/.battle_state.json"
ESCAPE_CRANK_S = 60  # hard on-chain constant (escapeCrankInterval)


# -----------------------------------------------------------------------------
# Send gate (DRY-RUN-first) + small readers
# -----------------------------------------------------------------------------

def send(ctx: BattleCtx, actor: str, fn, *, gas: int = 600_000, label: str = "", value: int = 0):
    """The ONLY path to a state change. In dry-run logs intent and returns None."""
    acct = ctx.actor(actor)
    desc = label or getattr(fn, "fn_name", "tx")
    if not ctx.execute:
        ctx.console.print(f"  [cyan][DRY-RUN][/cyan] {desc}  (as {actor} {acct.address})")
        return None
    ctx.console.print(f"  [green][SEND][/green] {desc}  (as {actor})")
    return send_tx(ctx, acct, fn, gas=gas, value=value)


def _v(ctx: BattleCtx):
    return ctx.vault.functions


def _shares(ctx: BattleCtx, addr: str) -> int:
    return _v(ctx).balanceOf(addr).call()


def _read(ctx: BattleCtx, name: str, *args):
    try:
        return getattr(_v(ctx), name)(*args).call()
    except Exception as exc:  # noqa: BLE001
        ctx.console.print(f"  [dim](read {name} failed: {exc})[/dim]")
        return None


def _usdc_bal(ctx: BattleCtx, addr: str) -> int:
    return ctx.usdc.functions.balanceOf(addr).call()


def _ctx_state(ctx: BattleCtx) -> str:
    idle = _read(ctx, "idleUsdc"); avail = _read(ctx, "availableIdleUsdc")
    reserved = _read(ctx, "reservedIdleUsdc"); core = _read(ctx, "coreSpotUsdc")
    total = _read(ctx, "totalAssets")
    def u(x): return "n/a" if x is None else f"{x/1e6:.4f}"
    return f"total={u(total)} idle={u(idle)} avail={u(avail)} reserved={u(reserved)} coreSpot={u(core)}"


def _deposit(ctx: BattleCtx, name: str, human: float) -> None:
    acct = ctx.actor(name)
    amt = usdc_units(human)
    send(ctx, name, ctx.usdc.functions.approve(ctx.vault_addr, amt), gas=120_000,
         label=f"approve {human:g} USDC")
    send(ctx, name, _v(ctx).deposit(amt, acct.address), gas=400_000,
         label=f"deposit {human:g} USDC")


def _redeem_all(ctx: BattleCtx, name: str, *, label_extra: str = "") -> None:
    acct = ctx.actor(name)
    sh = _shares(ctx, acct.address) if ctx.execute else _shares(ctx, acct.address)
    send(ctx, name, _v(ctx).redeem(sh, acct.address, acct.address), gas=500_000,
         label=f"redeem {sh} shares{(' ' + label_extra) if label_extra else ''}")


# -----------------------------------------------------------------------------
# Scenarios — each is gated through send(); reads are best-effort for dry-run.
# Signature: scenario(ctx, st) -> None. Idempotent: read on-chain, then act.
# -----------------------------------------------------------------------------

def sc_a_happy(ctx: BattleCtx, st: dict) -> None:
    """(a) LP1 full idle-capped redeem; (l) LP8 deposits at a moved NAV."""
    ctx.console.print(f"[bold]A.happy[/bold] {_ctx_state(ctx)}")
    _deposit(ctx, "lp1", ctx.tiers["lp1"])
    _redeem_all(ctx, "lp1", label_extra="(idle fully covers -> full)")
    # (l) NAV-moving concurrency: LP8 enters after LP1's round-trip, at whatever PPS now holds.
    _deposit(ctx, "lp8", ctx.tiers["lp8"])
    state_store.set_lp(st, "lp1", "exited"); state_store.set_lp(st, "lp8", "deposited")


def sc_a_partial(ctx: BattleCtx, st: dict) -> None:
    """(a-partial) LP2 deposits; operator pushes part to Core; sync redeem partial-fills to idle."""
    ctx.console.print(f"[bold]A.partial[/bold] {_ctx_state(ctx)}")
    _deposit(ctx, "lp2", ctx.tiers["lp2"])
    # Operator deploys ~60% to Core so maxWithdraw(LP2) < owned -> redeem partial-fills.
    push = core_wei_usdc(ctx.tiers["lp2"] * 0.6)
    send(ctx, "operator", _v(ctx).pushToCore(push), gas=500_000,
         label=f"operator push {ctx.tiers['lp2']*0.6:g} USDC to Core (idle<claim)")
    _redeem_all(ctx, "lp2", label_extra="(idle-capped -> PARTIAL; remainder stays as shares)")
    state_store.set_lp(st, "lp2", "partial-redeemed (residual shares)")


def sc_b_queue_full(ctx: BattleCtx, st: dict) -> None:
    """(b-full) LP3 request -> keeper repatriates -> fulfill (full). Perf-fee realized (h)."""
    ctx.console.print(f"[bold]B.queue-full[/bold] {_ctx_state(ctx)}")
    _deposit(ctx, "lp3", ctx.tiers["lp3"])
    # Operator deploys most of LP3 to Core so the claim exceeds idle -> must queue.
    send(ctx, "operator", _v(ctx).pushToCore(core_wei_usdc(ctx.tiers["lp3"] * 0.9)), gas=500_000,
         label="operator push 90% of LP3 to Core")
    acct = ctx.actor("lp3")
    sh = _shares(ctx, acct.address)
    fee0 = _usdc_bal(ctx, ctx.fee_recipient) if ctx.fee_recipient else None
    send(ctx, "lp3", _v(ctx).requestWithdraw(sh), gas=300_000, label=f"requestWithdraw {sh} shares")
    # Keeper (operator) repatriates balance*0.998 then fulfills (see keeper.py for the live loop).
    ctx.console.print("  [dim]-> run the keeper (e2e_runner --steps keeper --keeper-execute) to "
                      "repatriate + fulfill; or drive manually below[/dim]")
    send(ctx, "operator", _v(ctx).usdPerpToSpot(0), gas=400_000, label="(if perp) class-transfer to spot")
    send(ctx, "operator", _v(ctx).fulfillWithdraw(acct.address), gas=500_000,
         label="fulfillWithdraw LP3 (after repatriation)")
    if fee0 is not None and ctx.execute:
        fee1 = _usdc_bal(ctx, ctx.fee_recipient)
        ctx.console.print(f"  perf-fee to feeRecipient: {(fee1-fee0)/1e6:.6f} USDC (per-LP cost basis, no mint)")
    state_store.set_lp(st, "lp3", "exited via queue (perf-fee realized)")


def sc_b_queue_partial(ctx: BattleCtx, st: dict) -> None:
    """(b-partial + k) LP4 request -> partial fulfill -> re-prioritize remainder; 0.998 fee edge."""
    ctx.console.print(f"[bold]B.queue-partial[/bold] {_ctx_state(ctx)}")
    _deposit(ctx, "lp4", ctx.tiers["lp4"])
    send(ctx, "operator", _v(ctx).pushToCore(core_wei_usdc(ctx.tiers["lp4"] * 0.95)), gas=500_000,
         label="operator push 95% of LP4 to Core (idle covers only part)")
    acct = ctx.actor("lp4")
    sh = _shares(ctx, acct.address)
    send(ctx, "lp4", _v(ctx).requestWithdraw(sh), gas=300_000, label=f"requestWithdraw {sh} shares")
    send(ctx, "operator", _v(ctx).fulfillWithdraw(acct.address), gas=500_000,
         label="fulfillWithdraw LP4 (PARTIAL — idle short)")
    ctx.console.print("  [dim](k) keeper pulls balance*0.998 — NEVER the exact full Core balance "
                      "(the ~0.00134 USDC fee on a full send is silently dropped)[/dim]")
    # Repatriate the rest, then fulfill the remainder (re-prioritize if it had been reserved).
    send(ctx, "operator", _v(ctx).pullFromCore(int(core_wei_usdc(ctx.tiers["lp4"] * 0.95) * 0.998)),
         gas=600_000, label="pullFromCore balance*0.998 (fee guard)")
    send(ctx, "operator", _v(ctx).fulfillWithdraw(acct.address), gas=500_000,
         label="fulfillWithdraw LP4 (remainder)")
    state_store.set_lp(st, "lp4", "exited via queue (partial loop + fee edge)")


def sc_c_finding_f(ctx: BattleCtx, st: dict) -> None:
    """(c) Finding-F: LP5 queued request vs LP6 front-running direct redeem draining idle."""
    ctx.console.print(f"[bold]C.finding-F[/bold] {_ctx_state(ctx)}")
    _deposit(ctx, "lp5", ctx.tiers["lp5"])
    _deposit(ctx, "lp6", ctx.tiers["lp6"])
    a5 = ctx.actor("lp5")
    send(ctx, "lp5", _v(ctx).requestWithdraw(_shares(ctx, a5.address)), gas=300_000,
         label="LP5 requestWithdraw (queued)")
    # LP6 front-runs with a direct redeem -> drains free idle ahead of the queued request.
    _redeem_all(ctx, "lp6", label_extra="(front-runs LP5: drains FREE idle first)")
    ctx.console.print("  [dim]-> after SLA lapses, prioritizeOverdue(LP5) RESERVES its claim so a "
                      "second LP6-style redeem can't drain it; then fulfillWithdraw(LP5)[/dim]")
    send(ctx, "trigger", _v(ctx).prioritizeOverdue(a5.address), gas=300_000,
         label="permissionless prioritizeOverdue(LP5) [needs SLA elapsed]")
    send(ctx, "operator", _v(ctx).fulfillWithdraw(a5.address), gas=500_000, label="fulfillWithdraw LP5 (from reserve)")
    state_store.set_lp(st, "lp5", "exited from reserve"); state_store.set_lp(st, "lp6", "exited (front-ran)")


def sc_d_cancel(ctx: BattleCtx, st: dict) -> None:
    """(d) LP7 requestWithdraw -> cancelWithdrawRequest (shares + cost basis restored) -> re-request."""
    ctx.console.print(f"[bold]D.cancel[/bold] {_ctx_state(ctx)}")
    _deposit(ctx, "lp7", ctx.tiers["lp7"])
    a7 = ctx.actor("lp7")
    sh = _shares(ctx, a7.address)
    send(ctx, "lp7", _v(ctx).requestWithdraw(sh), gas=300_000, label="LP7 requestWithdraw")
    send(ctx, "lp7", _v(ctx).cancelWithdrawRequest(), gas=200_000, label="LP7 cancelWithdrawRequest (shares restored)")
    send(ctx, "lp7", _v(ctx).requestWithdraw(sh), gas=300_000, label="LP7 requestWithdraw again (re-request)")
    state_store.set_lp(st, "lp7", "re-requested (cancel proven)")


def sc_barriers(ctx: BattleCtx, st: dict) -> None:
    """(g) Soft barriers: with barriers ON (set out-of-band via timelock), a SYNC redeem
    reverts (lockup/cooldown/gate) while the queue path stays ungated. With barriers OFF,
    the same sync redeem succeeds. This scenario EXERCISES + observes; the on/off toggle is a
    24h-timelock action driven by admin_timelock.py per the runbook."""
    ctx.console.print(f"[bold]C.barriers[/bold] {_ctx_state(ctx)}")
    ctx.console.print("  [dim]Prereq: admin_timelock.py set_barriers(...) executed (24h timelock).[/dim]")
    a8 = ctx.actor("lp8")
    # Attempt a small SYNC redeem — expect a barrier revert when ON (LockupNotElapsed /
    # RedeemCooldownActive / RedeemGateExceeded). In dry-run we just log the probe.
    sh = max(1, _shares(ctx, a8.address) // 4)
    send(ctx, "lp8", _v(ctx).redeem(sh, a8.address, a8.address), gas=500_000,
         label=f"LP8 SYNC redeem {sh} (expect barrier revert when ON; per-tx GATE when gate set)")
    # Prove the queue path is NEVER barrier-gated:
    send(ctx, "lp8", _v(ctx).requestWithdraw(sh), gas=300_000,
         label="LP8 requestWithdraw (ungated even under barriers)")
    send(ctx, "lp8", _v(ctx).cancelWithdrawRequest(), gas=200_000, label="LP8 cancel (restore for later)")
    ctx.console.print("  [dim]After C: admin_timelock.py set_barriers(0,0,0) to turn barriers OFF "
                      "before phase D.[/dim]")
    state_store.set_lp(st, "lp8", "barrier-probed (shares intact)")


def sc_d_emergency(ctx: BattleCtx, st: dict) -> None:
    """(j) emergencyShutdown blocks deposits but NOT redeems; pause + repatriate-while-paused."""
    ctx.console.print(f"[bold]D.emergency[/bold] {_ctx_state(ctx)}")
    send(ctx, "emergency", _v(ctx).pause(), gas=200_000, label="pause()")
    ctx.console.print("  [dim]while paused: pullFromCore / usdPerpToSpot / emergencyRepatriate still work "
                      "(NOT whenNotPaused); redeems still work[/dim]")
    send(ctx, "emergency", _v(ctx).emergencyRepatriate(ctx.vault_addr, 0, 0), gas=600_000,
         label="emergencyRepatriate (proves refill works while paused)")
    send(ctx, "emergency", _v(ctx).unpause(), gas=200_000, label="unpause()")
    send(ctx, "emergency", _v(ctx).emergencyShutdown(), gas=200_000,
         label="emergencyShutdown() [ONE-WAY — blocks deposits only]")
    ctx.console.print("  [dim]post-shutdown: a deposit reverts (maxDeposit==0) but redeem/queue still work[/dim]")
    state_store.mark_scenario(st, "d_emergency", "RUNNING")


def sc_e_overdue(ctx: BattleCtx, st: dict) -> None:
    """(e) LP9 request with idle<claim + SLA set; deadline lapses; permissionless prioritizeOverdue -> fulfill."""
    ctx.console.print(f"[bold]E.overdue[/bold] {_ctx_state(ctx)}")
    _deposit(ctx, "lp9", ctx.tiers["lp9"])
    send(ctx, "operator", _v(ctx).pushToCore(core_wei_usdc(ctx.tiers["lp9"] * 0.9)), gas=500_000,
         label="operator push 90% of LP9 to Core")
    a9 = ctx.actor("lp9")
    send(ctx, "lp9", _v(ctx).requestWithdraw(_shares(ctx, a9.address)), gas=300_000, label="LP9 requestWithdraw")
    overdue = _read(ctx, "requestIsOverdue", a9.address)
    ctx.console.print(f"  [dim]requestIsOverdue(LP9)={overdue} — wait for SLA window to lapse, then:[/dim]")
    send(ctx, "trigger", _v(ctx).prioritizeOverdue(a9.address), gas=300_000,
         label="permissionless prioritizeOverdue(LP9)")
    send(ctx, "operator", _v(ctx).pullFromCore(int(core_wei_usdc(ctx.tiers["lp9"] * 0.9) * 0.998)),
         gas=600_000, label="repatriate balance*0.998")
    send(ctx, "trigger", _v(ctx).fulfillWithdraw(a9.address), gas=500_000,
         label="fulfillWithdraw(LP9) [permissionless]")
    state_store.set_lp(st, "lp9", "exited via overdue->prioritize->fulfill")


def sc_f_escape(ctx: BattleCtx, st: dict) -> None:
    """(f) Permissionless escape brake end-to-end. LP10 request; operator 'dark' (keeper scoped off
    LP10) so claim>idle persists past deadline+grace; trigger arms + runs 4 legs + fulfill + exitEscape."""
    ctx.console.print(f"[bold]F.escape[/bold] {_ctx_state(ctx)}")
    _deposit(ctx, "lp10", ctx.tiers["lp10"])
    send(ctx, "operator", _v(ctx).pushToCore(core_wei_usdc(ctx.tiers["lp10"] * 0.95)), gas=500_000,
         label="operator push 95% of LP10 to Core")
    a10 = ctx.actor("lp10")
    send(ctx, "lp10", _v(ctx).requestWithdraw(_shares(ctx, a10.address)), gas=300_000, label="LP10 requestWithdraw")
    ctx.console.print("  [dim]OPERATOR GOES DARK for LP10 (keeper scoped off it). Wait deadline+grace "
                      f"(4h floor). Then ANYONE (trigger) arms the brake:[/dim]")
    send(ctx, "trigger", _v(ctx).triggerEscape(a10.address), gas=400_000,
         label="triggerEscape(LP10) [permissionless; needs overdue+grace AND claim>idle]")
    # Leg 1: cancel resting orders (cloids from the HL book).
    cloids = []
    if ctx.info is not None:
        try:
            cloids = [int(o["cloid"], 16) for o in hl.open_orders(ctx.info, ctx.vault_addr) if o.get("cloid")]
        except Exception:  # noqa: BLE001
            pass
    send(ctx, "trigger", _v(ctx).escapeCancelOrders(ctx.asset_idx, cloids), gas=600_000,
         label=f"escape leg1: cancel {len(cloids)} resting orders")
    _escape_wait(ctx)
    # Leg 2: flatten perps (reduce-only IOC + mandatory markPx band). limitPx from mark.
    px = _flatten_px(ctx)
    send(ctx, "trigger", _v(ctx).escapeFlattenPerps([ctx.asset_idx], [px]), gas=800_000,
         label=f"escape leg2: flatten perps (limitPx={px})")
    _escape_wait(ctx)
    # Leg 3: consolidate spot.
    send(ctx, "trigger", _v(ctx).escapeConsolidateToSpot(), gas=600_000, label="escape leg3: consolidate to spot")
    _escape_wait(ctx)
    # Leg 4a: pull Core spot -> EVM (send_asset, chunked). escapePullToEvm(maxChunkWei)
    # is a per-crank CAP in 8dp Core wei; the CONTRACT applies the 99.8% fee cushion
    # internally (do NOT pre-discount, and do NOT pass the 6dp coreSpotUsdc() value as
    # an 8dp cap). Live-spike RUN-1: the Core->EVM bridge silently DROPS a single
    # withdrawal above a per-tx cap (~55-95 USDC observed), so bound the chunk under it
    # and crank repeatedly for a larger balance. 45 USDC covers the per-LP scale here.
    BRIDGE_CHUNK_WEI = 45 * 10**8  # 45 USDC in 8dp Core wei
    send(ctx, "trigger", _v(ctx).escapePullToEvm(BRIDGE_CHUNK_WEI), gas=700_000,
         label="escape leg4a: escapePullToEvm(45e8 cap=45 USDC; contract applies *0.998; repeat cranks for a larger Core balance)")
    _escape_wait(ctx)
    send(ctx, "trigger", _v(ctx).fulfillWithdraw(a10.address), gas=500_000, label="fulfillWithdraw(LP10)")
    send(ctx, "trigger", _v(ctx).exitEscape([a10.address]), gas=400_000,
         label="exitEscape([LP10]) [clears latch once backlog gone]")
    state_store.set_lp(st, "lp10", "exited via escape brake")


def _escape_wait(ctx: BattleCtx) -> None:
    """Respect the 60s on-chain crank cooldown between legs (execute mode only)."""
    if not ctx.execute:
        ctx.console.print(f"  [dim](would wait >= {ESCAPE_CRANK_S}s crank cooldown)[/dim]")
        return
    start = ctx.w3.eth.get_block("latest")["timestamp"]
    wait_for(lambda: ctx.w3.eth.get_block("latest")["timestamp"] >= start + ESCAPE_CRANK_S,
             timeout_s=ESCAPE_CRANK_S + 60, poll_s=5, label="escape crank cooldown")


def _flatten_px(ctx: BattleCtx) -> int:
    """A reduce-only IOC limit px inside the emergency-close band: mark crossed by a few %."""
    if ctx.info is None or ctx.asset_meta is None:
        return 0
    try:
        mark = hl.perp_mark_px(ctx.info, ctx.asset_idx)
        # Cross aggressively so the reduce-only IOC fills; band-gated on-chain.
        return ctx.asset_meta.encode_px(ctx.asset_meta.round_to_tick(mark * 0.95))
    except Exception:  # noqa: BLE001
        return 0


def sc_z_winddown(ctx: BattleCtx, st: dict) -> None:
    """(Z) Wind-down: lift escape, drain queue, bring Core->EVM, redeem all, sweep, decommission."""
    ctx.console.print(f"[bold]Z.winddown[/bold] {_ctx_state(ctx)}")
    ctx.console.print("  [dim]1) exitEscape if latched; 2) keeper drains every pending request; "
                      "3) usdPerpToSpot + pullFromCore(balance*0.998) + operatorRecoverSpot for dust;[/dim]")
    # Redeem any LP that still holds shares (barriers confirmed OFF).
    for name in LP_NAMES:
        acct = ctx.actor(name)
        sh = _shares(ctx, acct.address)
        if ctx.execute and sh == 0:
            continue
        send(ctx, name, _v(ctx).redeem(sh, acct.address, acct.address), gas=500_000,
             label=f"{name} final redeem {sh} shares")
    ctx.console.print("  [dim]4) operator redeems accrued mgmt-fee shares; sweep feeRecipient USDC; "
                      "5) sweep residual USDC + HYPE from all 12 accounts; 6) pause()/leave shutdown.[/dim]")
    state_store.mark_scenario(st, "z_winddown", "RUNNING")


# -----------------------------------------------------------------------------
# Scenario registry + phases
# -----------------------------------------------------------------------------

class Scenario:
    def __init__(self, sid: str, name: str, phase: str, accounts: list[str],
                 fn: Callable[[BattleCtx, dict], None]):
        self.id = sid; self.name = name; self.phase = phase
        self.accounts = accounts; self.fn = fn


SCENARIOS: list[Scenario] = [
    Scenario("a_happy", "happy-path full redeem + NAV-moving entry", "A", ["lp1", "lp8"], sc_a_happy),
    Scenario("a_partial", "idle-capped partial sync redeem", "A", ["lp2", "operator"], sc_a_partial),
    Scenario("b_full", "request -> keeper fulfill (full) + perf-fee", "B", ["lp3", "operator"], sc_b_queue_full),
    Scenario("b_partial", "request -> partial fulfill + re-prioritize + fee edge", "B", ["lp4", "operator"], sc_b_queue_partial),
    Scenario("c_finding_f", "Finding-F race (queued vs front-running redeem)", "B", ["lp5", "lp6", "trigger"], sc_c_finding_f),
    Scenario("d_cancel", "cancelWithdrawRequest then re-request", "B", ["lp7"], sc_d_cancel),
    Scenario("barriers", "soft barriers ON/OFF + queue ungated", "C", ["lp8"], sc_barriers),
    Scenario("d_emergency", "emergencyShutdown + pause/repatriate-while-paused", "D", ["emergency"], sc_d_emergency),
    Scenario("e_overdue", "overdue -> prioritizeOverdue -> fulfill", "E", ["lp9", "trigger", "operator"], sc_e_overdue),
    Scenario("f_escape", "permissionless escape brake end-to-end", "F", ["lp10", "trigger", "operator"], sc_f_escape),
    Scenario("z_winddown", "wind-down + recover all funds", "Z", LP_NAMES + ["operator", "emergency"], sc_z_winddown),
]

PHASE_ORDER = ["A", "B", "C", "D", "E", "F", "Z"]


def _by_id(sid: str) -> Optional[Scenario]:
    return next((s for s in SCENARIOS if s.id == sid), None)


def print_plan(console) -> None:
    from rich.table import Table
    t = Table(title="HyperVault 10-account battle-test — coverage matrix (phase order is load-bearing)")
    t.add_column("phase"); t.add_column("scenario"); t.add_column("accounts"); t.add_column("what it proves")
    for ph in PHASE_ORDER:
        for s in [s for s in SCENARIOS if s.phase == ph]:
            t.add_row(ph, s.id, ",".join(s.accounts), s.name)
    console.print(t)
    console.print("[dim]Pre-reqs via admin_timelock.py (24h timelock): SLA window before B/E/F; "
                  "escapeGraceSeconds=4h before F; barriers ON for C then OFF before D. "
                  "F is LAST (escape blocks deposits vault-wide).[/dim]")


# -----------------------------------------------------------------------------
# Runner
# -----------------------------------------------------------------------------

def run_scenario(ctx: BattleCtx, s: Scenario, st: dict, state_path: str, journal_out: Optional[str]) -> bool:
    ctx.console.rule(f"[bold]{s.phase}.{s.id}[/bold] — {s.name}  ({'EXECUTE' if ctx.execute else 'DRY-RUN'})")
    try:
        s.fn(ctx, st)
        state_store.mark_scenario(st, s.id, "PASS")
        ok = True
    except Exception as exc:  # noqa: BLE001 — record + continue; never strand the run
        ctx.console.print(f"[red]scenario {s.id} raised: {exc}[/red]")
        state_store.mark_scenario(st, s.id, "FAIL")
        ok = False
    state_store.save(state_path, st)
    if journal_out is not None:
        try:
            snap = journal.snapshot(ctx)
            journal.write_snapshot(journal_out, snap)
            for v in journal.check_invariants(snap):
                ctx.console.print(f"[red]INVARIANT: {v}[/red]")
        except Exception as exc:  # noqa: BLE001
            ctx.console.print(f"[dim]journal snapshot failed: {exc}[/dim]")
    return ok


def main(argv: Optional[list[str]] = None) -> int:
    p = argparse.ArgumentParser(description="HyperVault 10-account battle-test orchestrator (DRY-RUN-first).")
    add_common_args(p)
    p.add_argument("--plan", action="store_true", help="print the coverage matrix and exit (no chain)")
    p.add_argument("--phase", default=None, help="run a phase (A..F,Z) or 'all'")
    p.add_argument("--scenario", default=None, help="run a single scenario id")
    p.add_argument("--account", default=None, help="filter to scenarios involving this account")
    p.add_argument("--execute", action="store_true", help="ACTUALLY SEND TXS (default: dry-run)")
    p.add_argument("--resume", action="store_true", help="skip scenarios already marked PASS")
    p.add_argument("--state", default=DEFAULT_STATE, help="resumable checkpoint file")
    p.add_argument("--journal-out", default=None, help="append a NAV snapshot after each scenario")
    args = p.parse_args(argv)

    from rich.console import Console
    console = Console()

    if args.plan:
        print_plan(console)
        return 0
    if not (args.phase or args.scenario):
        console.print("[yellow]nothing to do: pass --plan, --phase, or --scenario[/yellow]")
        return 2

    ctx = build_battle_ctx(args)
    st = state_store.load(args.state)

    # Build the ordered scenario list.
    if args.scenario:
        s = _by_id(args.scenario)
        if not s:
            raise SystemExit(f"unknown scenario: {args.scenario}")
        todo = [s]
    elif args.phase == "all":
        todo = [s for ph in PHASE_ORDER for s in SCENARIOS if s.phase == ph]
    else:
        todo = [s for s in SCENARIOS if s.phase == args.phase.upper()]
        if not todo:
            raise SystemExit(f"no scenarios in phase {args.phase}")
    if args.account:
        todo = [s for s in todo if args.account in s.accounts]

    mode = "EXECUTE (funds move!)" if ctx.execute else "DRY-RUN (no funds)"
    console.print(f"[bold]battle-test[/bold] vault={ctx.vault_addr} mode={mode} "
                  f"scenarios={[s.id for s in todo]}")

    failures = 0
    for s in todo:
        if args.resume and state_store.is_done(st, s.id):
            console.print(f"[dim]skip {s.id} (already PASS)[/dim]")
            continue
        if not run_scenario(ctx, s, st, args.state, args.journal_out):
            failures += 1
    console.print(state_store.summary(st))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

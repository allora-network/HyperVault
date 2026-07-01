#!/usr/bin/env python3
"""Read-only NAV snapshot + invariant checker for the daily battle-test reconciliation.

WHY THIS EXISTS
---------------
During a multi-day funded live spike, the operator needs a single command that
reads the FULL state of the vault (aggregate NAV legs, redemption posture, every
LP's shares + pending request, fee accrual) and cross-checks the on-chain
precompile NAV against the HyperCore API view — then flags anything that's
drifted. This is the morning/evening reconciliation pass.

It is strictly READ-ONLY: it never sends a transaction, never moves funds. Every
view is wrapped (`_safe`) so a single reverting/empty precompile read (e.g. a
fork where the 0x08xx precompiles return empty — see CLAUDE.md) degrades that one
field to None instead of killing the whole snapshot. Output is a rich table plus
any invariant violations in red, and an optional append-only JSONL journal so the
day's snapshots accrue into a reviewable timeline.

Decimals: USDC is 6dp on EVM; the share token is 12dp (6-decimal offset). NAV
legs (totalAssets/idle/available/reserved/coreSpot/perpWithdrawable) are 6dp USDC.
Cost-basis-per-share has NO on-chain getter (dropped for EIP-170), so per-LP
economics are read as `shares` + `previewRedeem(shares)` (gross of perf fee).
"""
from __future__ import annotations

import argparse
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Optional

from rich.console import Console
from rich.table import Table

from accounts import build_battle_ctx, BattleCtx
import hl_helpers as hl

# USDC is 6dp on the EVM side; the ERC-4626 share token is 12dp (6-decimal offset).
USDC_DECIMALS = 6
SHARE_DECIMALS = 12
# One whole share, in share-token base units (12dp). Used to derive price-per-share.
ONE_SHARE_WEI = 10 ** SHARE_DECIMALS
# Tolerance for HL-API-vs-precompile NAV drift, in human USDC. Sub-cent precision
# noise in the precompile / API reads must not raise a false alarm.
DRIFT_TOLERANCE_USDC = 0.01


def _safe(fn: Callable[[], Any], default: Any = None) -> Any:
    """Call a read closure, returning `default` on ANY exception.

    One reverting/empty view (a stale precompile, a paused dependency, a fork that
    can't run the 0x08xx precompiles) must not abort the whole snapshot — the
    reconciliation is more useful with a hole than with a crash.
    """
    try:
        return fn()
    except Exception:
        return default


def _usdc(raw: Optional[int]) -> Optional[float]:
    """6dp base units -> human USDC, passing None through."""
    return None if raw is None else raw / 10 ** USDC_DECIMALS


# -----------------------------------------------------------------------------
# Snapshot
# -----------------------------------------------------------------------------

def snapshot(ctx: BattleCtx) -> dict:
    """Read the full vault + HL state into a JSON-serializable dict.

    Every chain read is `_safe`-wrapped. The returned dict carries raw integer
    legs (suffixed `_raw`) AND human floats so both the table and the invariant
    checker can use whichever is convenient; ints are kept JSON-safe (Python ints
    serialize fine, but we never emit web3 wrappers).
    """
    vault = ctx.vault
    f = vault.functions

    block = _safe(lambda: ctx.w3.eth.block_number)
    snap: dict[str, Any] = {
        "ts": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "block": block,
        "network": ctx.network,
        "vault": ctx.vault_addr,
        "asset_idx": ctx.asset_idx,
    }

    # ---- aggregate NAV legs (all 6dp USDC) ----
    total_assets = _safe(lambda: f.totalAssets().call())
    idle = _safe(lambda: f.idleUsdc().call())
    available = _safe(lambda: f.availableIdleUsdc().call())
    reserved = _safe(lambda: f.reservedIdleUsdc().call())
    core_spot = _safe(lambda: f.coreSpotUsdc().call())
    perp_withdrawable = _safe(lambda: f.perpWithdrawable().call())
    total_supply = _safe(lambda: f.totalSupply().call())

    snap["aggregate"] = {
        "totalAssets_raw": total_assets,
        "idle_raw": idle,
        "available_raw": available,
        "reserved_raw": reserved,
        "coreSpot_raw": core_spot,
        "perpWithdrawable_raw": perp_withdrawable,
        "totalSupply_raw": total_supply,
        "totalAssets": _usdc(total_assets),
        "idle": _usdc(idle),
        "available": _usdc(available),
        "reserved": _usdc(reserved),
        "coreSpot": _usdc(core_spot),
        "perpWithdrawable": _usdc(perp_withdrawable),
        "totalSupply": (None if total_supply is None else total_supply / 10 ** SHARE_DECIMALS),
    }

    # ---- price-per-share — computed defensively (two independent routes) ----
    # previewRedeem(ONE_SHARE) is gross-of-fee USDC for one whole share;
    # convertToAssets(ONE_SHARE) is the fee-agnostic conversion. We keep both and
    # surface previewRedeem as the headline (what an exiting LP would actually get).
    pps_preview = _safe(lambda: f.previewRedeem(ONE_SHARE_WEI).call())
    pps_convert = _safe(lambda: f.convertToAssets(ONE_SHARE_WEI).call())
    snap["pricePerShare"] = {
        "previewRedeem_raw": pps_preview,
        "convertToAssets_raw": pps_convert,
        "previewRedeem": _usdc(pps_preview),     # USDC per whole share, net of perf fee
        "convertToAssets": _usdc(pps_convert),   # USDC per whole share, gross
    }

    # ---- redemption / shutdown posture ----
    snap["posture"] = {
        "escapeActive": _safe(lambda: f.escapeActive().call()),
        "paused": _safe(lambda: f.paused().call()),
        "emergencyShutdownActive": _safe(lambda: f.emergencyShutdownActive().call()),
        "escapeGraceSeconds": _safe(lambda: f.escapeGraceSeconds().call()),
        "requestFulfillmentWindow": _safe(lambda: f.requestFulfillmentWindow().call()),
        "leverageCapBps": _safe(lambda: f.leverageCapBps().call()),
    }

    # ---- per-account: LPs + trigger + operator + feeRecipient ----
    fee_recipient = _safe(lambda: f.feeRecipient().call())
    snap["feeRecipient"] = fee_recipient

    accounts: dict[str, str] = {}
    for name, acct in ctx.accounts.items():
        accounts[name] = getattr(acct, "address", None) or str(acct)
    # Add operator / feeRecipient as named pseudo-accounts when known and distinct.
    if ctx.operator is not None:
        accounts.setdefault("operator", ctx.operator.address)
    if fee_recipient is not None and int(fee_recipient, 16) != 0:
        accounts.setdefault("feeRecipient", ctx.w3.to_checksum_address(fee_recipient))

    per_account: dict[str, dict] = {}
    for name, addr in accounts.items():
        if addr is None:
            continue
        cs_addr = _safe(lambda a=addr: ctx.w3.to_checksum_address(a), default=addr)
        shares = _safe(lambda a=cs_addr: f.balanceOf(a).call())
        preview = _safe(lambda s=shares: f.previewRedeem(s).call()) if shares else 0
        per_account[name] = {
            "address": cs_addr,
            "shares_raw": shares,
            "shares": (None if shares is None else shares / 10 ** SHARE_DECIMALS),
            "previewRedeem_raw": preview,
            "previewRedeem": _usdc(preview),
            "pendingShares_raw": _safe(lambda a=cs_addr: f.pendingWithdrawalShares(a).call()),
            "pendingDeadline": _safe(lambda a=cs_addr: f.pendingWithdrawalDeadline(a).call()),
            "pendingReserved_raw": _safe(lambda a=cs_addr: f.pendingWithdrawalReserved(a).call()),
            "requestIsOverdue": _safe(lambda a=cs_addr: f.requestIsOverdue(a).call()),
        }
    snap["accounts"] = per_account

    # ---- fee tracking: feeRecipient's USDC + share balances ----
    fee_usdc = None
    fee_shares = None
    if fee_recipient is not None and int(fee_recipient, 16) != 0:
        fr = ctx.w3.to_checksum_address(fee_recipient)
        fee_usdc = _safe(lambda: ctx.usdc.functions.balanceOf(fr).call())
        fee_shares = _safe(lambda: f.balanceOf(fr).call())
    snap["fees"] = {
        # Per-LP cost-basis-per-share has NO on-chain getter (dropped for EIP-170);
        # per-LP perf economics are inferred from shares + previewRedeem above.
        "note": "cost-basis-per-share has no getter (EIP-170); perf-fee inferred via previewRedeem",
        "feeRecipientUsdc_raw": fee_usdc,
        "feeRecipientUsdc": _usdc(fee_usdc),
        "feeRecipientShares_raw": fee_shares,
        "feeRecipientShares": (None if fee_shares is None else fee_shares / 10 ** SHARE_DECIMALS),
    }

    # ---- HL cross-checks: API view vs on-chain precompile NAV legs ----
    # spot_balance(vault) (human USDC) vs coreSpotUsdc(); perp accountValue vs
    # perpWithdrawable(). Flag drift > tolerance. On a fork the precompiles read
    # empty (0), so these will diverge — that's a known fork limitation, surfaced.
    # Use the Core USDC token index (0), NOT the perp asset_idx — they coincide at
    # 0 for a BTC-perp/USDC vault but differ once a non-zero perp market is chosen.
    _usdc_idx = getattr(ctx, "core_usdc_index", 0)
    hl_spot = _safe(lambda: hl.spot_balance(ctx.info, ctx.vault_addr, _usdc_idx))
    hl_state = _safe(lambda: hl.user_state(ctx.info, ctx.vault_addr), default={})
    hl_perp_value = _safe(
        lambda: float((hl_state or {}).get("marginSummary", {}).get("accountValue", 0)),
        default=None,
    )
    core_spot_h = _usdc(core_spot)
    perp_w_h = _usdc(perp_withdrawable)
    snap["hl_crosscheck"] = {
        "hlSpotUsdc": hl_spot,
        "coreSpotUsdc": core_spot_h,
        "spotDrift": (None if hl_spot is None or core_spot_h is None else abs(hl_spot - core_spot_h)),
        "hlPerpValue": hl_perp_value,
        "perpWithdrawable": perp_w_h,
        # perp value (mark-to-market accountValue) vs the conservative withdrawable
        # leg the vault uses for NAV — these legitimately differ by unrealized PnL,
        # so we report the gap but only the spot leg is a hard invariant.
        "perpGap": (None if hl_perp_value is None or perp_w_h is None else abs(hl_perp_value - perp_w_h)),
    }

    return snap


# -----------------------------------------------------------------------------
# Invariants
# -----------------------------------------------------------------------------

def check_invariants(snap: dict) -> list[str]:
    """Return human-readable violation strings; an empty list means all good.

    Checks (skipping any leg that read as None — a missing read is reported by the
    snapshot table, not double-counted as a violation here):
      1. idle == available + reserved          (exact, within 1 base unit)
      2. totalAssets ~= idle + coreSpot + perpWithdrawable (within tolerance)
      3. reserved <= idle
      4. HL spot-vs-precompile drift <= tolerance
    """
    out: list[str] = []
    agg = snap.get("aggregate", {})
    idle = agg.get("idle_raw")
    available = agg.get("available_raw")
    reserved = agg.get("reserved_raw")
    total_assets = agg.get("totalAssets_raw")
    core_spot = agg.get("coreSpot_raw")
    perp_w = agg.get("perpWithdrawable_raw")

    # 1) idle == available + reserved (within 1 base unit of 6dp USDC)
    if idle is not None and available is not None and reserved is not None:
        if abs(idle - (available + reserved)) > 1:
            out.append(
                f"idle != available + reserved: idle={idle/1e6:.6f}, "
                f"available={available/1e6:.6f}, reserved={reserved/1e6:.6f} "
                f"(delta {(idle - available - reserved)/1e6:+.6f} USDC)"
            )

    # 2) totalAssets ~= idle + coreSpot + perpWithdrawable (within tolerance)
    if all(v is not None for v in (total_assets, idle, core_spot, perp_w)):
        legs = idle + core_spot + perp_w
        tol = int(round(DRIFT_TOLERANCE_USDC * 1e6))
        if abs(total_assets - legs) > tol:
            out.append(
                f"totalAssets != idle + coreSpot + perpWithdrawable: "
                f"totalAssets={total_assets/1e6:.6f}, sum-of-legs={legs/1e6:.6f} "
                f"(delta {(total_assets - legs)/1e6:+.6f} USDC)"
            )

    # 3) reserved <= idle
    if idle is not None and reserved is not None and reserved > idle:
        out.append(
            f"reserved > idle: reserved={reserved/1e6:.6f} > idle={idle/1e6:.6f} USDC "
            f"(over-reservation breaks liveness)"
        )

    # 4) HL spot vs precompile drift
    drift = snap.get("hl_crosscheck", {}).get("spotDrift")
    if drift is not None and drift > DRIFT_TOLERANCE_USDC:
        cc = snap["hl_crosscheck"]
        out.append(
            f"HL spot vs coreSpotUsdc() drift {drift:.6f} USDC > {DRIFT_TOLERANCE_USDC} "
            f"(HL API {cc.get('hlSpotUsdc')}, precompile {cc.get('coreSpotUsdc')}) "
            f"— precompile/API disagree on Core spot (fork? stale read?)"
        )

    return out


# -----------------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------------

def write_snapshot(path: str, snap: dict) -> None:
    """Append one JSON line (JSONL) so a day's snapshots form a timeline."""
    line = json.dumps(snap, default=str)
    with open(path, "a") as fh:
        fh.write(line + "\n")


def _fmt(val: Any, suffix: str = "") -> str:
    """Render a value for the rich table; None -> dim n/a."""
    if val is None:
        return "[dim]n/a[/dim]"
    if isinstance(val, float):
        return f"{val:,.6f}{suffix}"
    return f"{val}{suffix}"


def _print_snapshot(console: Console, snap: dict, violations: list[str]) -> None:
    """Render the snapshot as rich tables + any invariant violations in red."""
    agg = snap.get("aggregate", {})
    posture = snap.get("posture", {})
    pps = snap.get("pricePerShare", {})

    head = Table(show_header=False, box=None, title=f"NAV snapshot @ block {snap.get('block')}")
    head.add_row("ts", str(snap.get("ts")))
    head.add_row("vault", str(snap.get("vault")))
    head.add_row("network", str(snap.get("network")))
    head.add_row("totalAssets", _fmt(agg.get("totalAssets"), " USDC"))
    head.add_row("  idle", _fmt(agg.get("idle"), " USDC"))
    head.add_row("    available", _fmt(agg.get("available"), " USDC"))
    head.add_row("    reserved", _fmt(agg.get("reserved"), " USDC"))
    head.add_row("  coreSpot", _fmt(agg.get("coreSpot"), " USDC"))
    head.add_row("  perpWithdrawable", _fmt(agg.get("perpWithdrawable"), " USDC"))
    head.add_row("totalSupply (shares)", _fmt(agg.get("totalSupply")))
    head.add_row("pricePerShare (previewRedeem)", _fmt(pps.get("previewRedeem"), " USDC"))
    head.add_row("pricePerShare (convertToAssets)", _fmt(pps.get("convertToAssets"), " USDC"))
    console.print(head)

    post = Table(show_header=False, box=None, title="posture")
    post.add_row("escapeActive", str(posture.get("escapeActive")))
    post.add_row("paused", str(posture.get("paused")))
    post.add_row("emergencyShutdownActive", str(posture.get("emergencyShutdownActive")))
    post.add_row("escapeGraceSeconds", str(posture.get("escapeGraceSeconds")))
    post.add_row("requestFulfillmentWindow", str(posture.get("requestFulfillmentWindow")))
    post.add_row("leverageCapBps", str(posture.get("leverageCapBps")))
    console.print(post)

    acct = Table(show_header=True, header_style="bold", title="per-account")
    acct.add_column("name")
    acct.add_column("shares", justify="right")
    acct.add_column("previewRedeem", justify="right")
    acct.add_column("pendingShares", justify="right")
    acct.add_column("deadline", justify="right")
    acct.add_column("reserved", justify="right")
    acct.add_column("overdue")
    for name, info in snap.get("accounts", {}).items():
        pending_raw = info.get("pendingShares_raw") or 0
        overdue = info.get("requestIsOverdue")
        overdue_str = ("[red]YES[/red]" if overdue else "no") if overdue is not None else "[dim]n/a[/dim]"
        acct.add_row(
            name,
            _fmt(info.get("shares")),
            _fmt(info.get("previewRedeem"), " USDC"),
            str(pending_raw),
            str(info.get("pendingDeadline")),
            _fmt(_usdc(info.get("pendingReserved_raw")), " USDC"),
            overdue_str,
        )
    console.print(acct)

    fees = snap.get("fees", {})
    cc = snap.get("hl_crosscheck", {})
    extra = Table(show_header=False, box=None, title="fees + HL cross-check")
    extra.add_row("feeRecipient", str(snap.get("feeRecipient")))
    extra.add_row("feeRecipient USDC", _fmt(fees.get("feeRecipientUsdc"), " USDC"))
    extra.add_row("feeRecipient shares", _fmt(fees.get("feeRecipientShares")))
    extra.add_row("HL spot USDC", _fmt(cc.get("hlSpotUsdc"), " USDC"))
    extra.add_row("precompile coreSpot", _fmt(cc.get("coreSpotUsdc"), " USDC"))
    extra.add_row("spot drift", _fmt(cc.get("spotDrift"), " USDC"))
    extra.add_row("HL perp value", _fmt(cc.get("hlPerpValue"), " USDC"))
    extra.add_row("perp gap (PnL)", _fmt(cc.get("perpGap"), " USDC"))
    console.print(extra)

    if violations:
        console.print(f"[bold red]{len(violations)} invariant violation(s):[/bold red]")
        for v in violations:
            console.print(f"  [red]- {v}[/red]")
    else:
        console.print("[green]invariants OK[/green]")


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

def main(argv: Optional[list[str]] = None) -> int:
    """Snapshot + invariant check; optionally append JSONL and loop. READ-ONLY."""
    parser = argparse.ArgumentParser(description="HyperVault NAV snapshot + invariants (read-only).")
    parser.add_argument("--artifact", default=os.environ.get("ARTIFACT"),
                        help="path to deployments/<chain>/<strategy>.json")
    parser.add_argument("--rpc-url", default=os.environ.get("HYPEREVM_RPC_MAINNET"))
    parser.add_argument("--network", default="mainnet", choices=["mainnet", "testnet"])
    parser.add_argument("--asset", type=int, default=0, help="Core USDC token index (default 0)")
    parser.add_argument("--keys", default=os.environ.get("BATTLE_KEYS"),
                        help="path to the battle keyfile (addresses for per-account rows)")
    parser.add_argument("--journal-out", default=None,
                        help="append each snapshot as a JSON line to this path")
    parser.add_argument("--once", action="store_true", default=True,
                        help="take a single snapshot and exit (default)")
    parser.add_argument("--interval", type=float, default=None,
                        help="if set, loop forever taking a snapshot every N seconds")
    args = parser.parse_args(argv)

    if not args.artifact:
        print("--artifact (or $ARTIFACT) required")
        return 2

    # build_battle_ctx owns all ctx construction (accounts.py) — never reimplement.
    ctx = build_battle_ctx(args)
    console = ctx.console or Console()

    def one_pass() -> list[str]:
        snap = snapshot(ctx)
        violations = check_invariants(snap)
        _print_snapshot(console, snap, violations)
        if args.journal_out:
            write_snapshot(args.journal_out, snap)
            console.print(f"[dim]appended snapshot to {args.journal_out}[/dim]")
        return violations

    if args.interval is None:
        violations = one_pass()
        # Non-zero exit on a violation so a cron/CI wrapper can alert.
        return 1 if violations else 0

    console.print(f"[cyan]journal loop every {args.interval}s — Ctrl-C to stop[/cyan]")
    try:
        while True:
            one_pass()
            time.sleep(args.interval)
    except KeyboardInterrupt:
        console.print("[yellow]journal loop stopped[/yellow]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

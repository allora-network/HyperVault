#!/usr/bin/env python3
"""Standalone read-only monitor for a HyperCoreVault live spike.

This process **never sends a transaction**. It polls on-chain + Hyperliquid info
state and raises alerts through a pluggable sink (stdout/log always; optional
webhook via ``$ALERT_WEBHOOK_URL``). Run it alongside the keeper
(``e2e_runner.py --steps keeper``) over the battle-test window; the keeper does
the fulfilling, the monitor does the watching.

Checks (SOLU-3376 in this module; SOLU-3377 reconciliation/leverage added on top):
  - CoreDepositWallet ``paused()``  — when the Circle bridge is paused BOTH the
    push and the pull leg stall, so repatriation (and therefore redemption
    liveness) is blocked. Fire an alert the moment it flips to paused, and an
    all-clear when it recovers.
  - Vault posture heartbeat            — escape latch, pause, emergency-shutdown,
    and the NAV decomposition (idle / available / reserved / coreSpot / perp),
    logged every pass so the journal/operator has a continuous trail.

Usage (read-only; no keys required):
    ARTIFACT=deployments/mainnet/spike.json \\
    HYPEREVM_RPC_MAINNET=https://rpc.hyperliquid.xyz/evm \\
    python scripts/python/monitor.py --once          # single pass
    python scripts/python/monitor.py --interval 30   # poll forever

Run from the repo root (so ``out/`` and the sibling modules resolve).
"""
from __future__ import annotations

import argparse
import json
import os
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional

from rich.console import Console
from web3 import Web3

import hl_helpers as hl
# Reuse the proven ABI loader + the CoreDepositWallet read surface from the
# e2e runner so the monitor and the runner agree byte-for-byte on the wallet.
from e2e_runner import WALLET_ABI, core_deposit_wallet, load_abi


# -----------------------------------------------------------------------------
# Alert sink
# -----------------------------------------------------------------------------

# Severity ordering for filtering / colouring.
_LEVELS = {"info": 0, "warn": 1, "alert": 2}
_LEVEL_STYLE = {"info": "dim", "warn": "yellow", "alert": "bold red"}


@dataclass
class AlertSink:
    """Pluggable alert sink: console (always) + optional log file + optional webhook.

    De-dupes by ``key``: an identical (key, level, message) only re-fires after
    ``re_alert_s`` so a stuck-paused wallet doesn't spam every poll, but a
    *changed* state (e.g. paused -> unpaused) fires immediately.
    """

    console: Console
    log_path: Optional[Path] = None
    webhook_url: Optional[str] = None
    re_alert_s: int = 900  # 15 min between identical re-alerts
    _last: dict[str, tuple[str, float]] = field(default_factory=dict)

    def fire(self, key: str, level: str, message: str, *, force: bool = False) -> None:
        now = time.time()
        prev = self._last.get(key)
        same = prev is not None and prev[0] == f"{level}:{message}"
        if same and not force and (now - prev[1]) < self.re_alert_s:
            return
        self._last[key] = (f"{level}:{message}", now)
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
        style = _LEVEL_STYLE.get(level, "white")
        self.console.print(f"[{style}]{ts}  [{level.upper()}] {message}[/{style}]")
        if self.log_path is not None:
            line = json.dumps({"ts": ts, "key": key, "level": level, "msg": message})
            with self.log_path.open("a") as fh:
                fh.write(line + "\n")
        # Only push warn/alert over the webhook — info is heartbeat noise.
        if self.webhook_url and _LEVELS.get(level, 0) >= _LEVELS["warn"]:
            self._post_webhook(f"[{level.upper()}] {message}")

    def _post_webhook(self, text: str) -> None:
        try:
            payload = json.dumps({"text": text}).encode()
            req = urllib.request.Request(
                self.webhook_url, data=payload,
                headers={"Content-Type": "application/json"},
            )
            urllib.request.urlopen(req, timeout=10)  # noqa: S310 (operator-supplied URL)
        except (urllib.error.URLError, OSError) as exc:  # never let alerting crash the loop
            self.console.print(f"[dim]webhook post failed: {exc}[/dim]")


# -----------------------------------------------------------------------------
# Monitor context (read-only — NO private keys)
# -----------------------------------------------------------------------------

@dataclass
class MonitorCtx:
    w3: Web3
    info: Any                       # hyperliquid.info.Info
    vault: Any                      # web3 contract (HyperCoreVault)
    vault_addr: str
    wallet: Any                     # CoreDepositWallet contract, or None (legacy mode)
    asset_idx: int
    network: str
    console: Console
    sink: AlertSink
    leverage_cap_bps: int = 0       # resolved from chain in build (SOLU-3377)


def build_monitor_ctx(args: argparse.Namespace) -> MonitorCtx:
    artifact = json.loads(Path(args.artifact).read_text())
    vault_addr = Web3.to_checksum_address(artifact["vault"])

    rpc = args.rpc_url or os.environ["HYPEREVM_RPC_MAINNET"]
    w3 = Web3(Web3.HTTPProvider(rpc))
    assert w3.is_connected(), f"RPC not reachable: {rpc}"

    vault = w3.eth.contract(address=vault_addr, abi=load_abi("HyperCoreVault"))
    wallet = core_deposit_wallet_handle(w3, vault)

    console = Console()
    log_path = Path(args.log_file) if args.log_file else None
    sink = AlertSink(
        console=console,
        log_path=log_path,
        webhook_url=args.webhook_url or os.environ.get("ALERT_WEBHOOK_URL"),
        re_alert_s=args.re_alert_s,
    )

    # leverageCapBps is an immutable public getter; read it once for the
    # leverage monitor (SOLU-3377). Degrade gracefully if absent.
    lev_cap = 0
    try:
        lev_cap = int(vault.functions.leverageCapBps().call())
    except Exception:  # noqa: BLE001 — older ABI / read failure is non-fatal
        pass

    return MonitorCtx(
        w3=w3, info=hl.make_info(args.network), vault=vault, vault_addr=vault_addr,
        wallet=wallet, asset_idx=args.asset, network=args.network,
        console=console, sink=sink, leverage_cap_bps=lev_cap,
    )


def core_deposit_wallet_handle(w3: Web3, vault: Any):
    """CoreDepositWallet handle (or None). Mirrors e2e_runner.core_deposit_wallet
    but takes (w3, vault) so we don't need a full runner Ctx."""
    addr = vault.functions.coreDepositWallet().call()
    if int(addr, 16) == 0:
        return None
    return w3.eth.contract(address=Web3.to_checksum_address(addr), abi=WALLET_ABI)


# -----------------------------------------------------------------------------
# Read helpers
# -----------------------------------------------------------------------------

def _safe_call(fn: Callable[[], Any], default: Any = None) -> Any:
    try:
        return fn()
    except Exception:  # noqa: BLE001 — a missing/failing view should not kill the loop
        return default


def _usdc(v: Optional[int]) -> str:
    return "n/a" if v is None else f"{v / 1e6:,.6f}"


# -----------------------------------------------------------------------------
# Checks (SOLU-3376)
# -----------------------------------------------------------------------------

def check_wallet_paused(ctx: MonitorCtx) -> None:
    """SOLU-3376: alert when the CoreDepositWallet is paused (push AND pull stall)."""
    if ctx.wallet is None:
        ctx.sink.fire("wallet.mode", "info",
                      "vault is legacy-mode (no CoreDepositWallet) — pause guard N/A")
        return
    paused = _safe_call(lambda: bool(ctx.wallet.functions.paused().call()))
    if paused is None:
        ctx.sink.fire("wallet.read", "warn",
                      f"could not read CoreDepositWallet.paused() at {ctx.wallet.address}")
        return
    if paused:
        ctx.sink.fire(
            "wallet.paused", "alert",
            f"CoreDepositWallet {ctx.wallet.address} is PAUSED — push AND pull are "
            "blocked; repatriation/redemption liveness is degraded. Contingency: "
            "operatorRecoverSpot / USDT0 fallback (see docs/SECURITY.md).",
        )
    else:
        # All-clear (force so a paused->unpaused transition is never swallowed by de-dup).
        if "wallet.paused" in ctx.sink._last:
            ctx.sink.fire("wallet.paused", "info",
                          f"CoreDepositWallet {ctx.wallet.address} is unpaused (recovered).",
                          force=True)


def check_posture(ctx: MonitorCtx) -> None:
    """Heartbeat: escape latch / pause / shutdown + the NAV decomposition."""
    v = ctx.vault.functions
    escape = _safe_call(lambda: bool(v.escapeActive().call()))
    paused = _safe_call(lambda: bool(v.paused().call()))
    shutdown = _safe_call(lambda: bool(v.emergencyShutdownActive().call()))
    total = _safe_call(lambda: int(v.totalAssets().call()))
    idle = _safe_call(lambda: int(v.idleUsdc().call()))
    avail = _safe_call(lambda: int(v.availableIdleUsdc().call()))
    reserved = _safe_call(lambda: int(v.reservedIdleUsdc().call()))
    core = _safe_call(lambda: int(v.coreSpotUsdc().call()))
    perp = _safe_call(lambda: int(v.perpWithdrawable().call()))

    ctx.sink.fire(
        "posture", "info",
        f"NAV total={_usdc(total)} idle={_usdc(idle)} avail={_usdc(avail)} "
        f"reserved={_usdc(reserved)} coreSpot={_usdc(core)} perp={_usdc(perp)} | "
        f"escape={escape} paused={paused} shutdown={shutdown}",
        force=True,  # heartbeat: always log (console only — info isn't webhooked)
    )
    if escape:
        ctx.sink.fire("escape.active", "warn",
                      "vault is LATCHED IN ESCAPE MODE — deposits/new-exposure blocked; "
                      "run the escape legs + fulfill, then exitEscape.")
    elif "escape.active" in ctx.sink._last:
        ctx.sink.fire("escape.active", "info", "escape latch cleared.", force=True)


# Registry of checks. SOLU-3377 appends order-reconciliation + leverage here.
CHECKS: list[Callable[[MonitorCtx], None]] = [
    check_posture,
    check_wallet_paused,
]


def run_pass(ctx: MonitorCtx) -> None:
    for check in CHECKS:
        try:
            check(ctx)
        except Exception as exc:  # noqa: BLE001 — one bad check never stops the rest
            ctx.sink.fire(f"check.error.{check.__name__}", "warn",
                          f"{check.__name__} raised: {exc}")


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Read-only HyperCoreVault spike monitor (never sends txs).")
    p.add_argument("--artifact", default=os.environ.get("ARTIFACT"),
                   help="deployment artifact JSON (or $ARTIFACT)")
    p.add_argument("--rpc-url", default=None, help="HyperEVM RPC (default $HYPEREVM_RPC_MAINNET)")
    p.add_argument("--network", default="mainnet", choices=["mainnet", "testnet"])
    p.add_argument("--asset", type=int, default=0, help="perp asset index to watch (default 0)")
    p.add_argument("--once", action="store_true", help="run a single pass and exit")
    p.add_argument("--interval", type=int, default=30, help="poll interval seconds (default 30)")
    p.add_argument("--log-file", default=None, help="append JSON-lines alerts to this file")
    p.add_argument("--webhook-url", default=None, help="alert webhook (default $ALERT_WEBHOOK_URL)")
    p.add_argument("--re-alert-s", type=int, default=900,
                   help="seconds before an identical alert re-fires (default 900)")
    # SOLU-3377 knobs (consumed once that PR lands; harmless here).
    p.add_argument("--lookback-blocks", type=int, default=5_000,
                   help="block lookback for LimitOrderSubmitted scan (SOLU-3377)")
    p.add_argument("--log-chunk", type=int, default=2_000,
                   help="getLogs chunk size in blocks (SOLU-3377)")
    return p


def main(argv: Optional[list[str]] = None) -> int:
    args = build_arg_parser().parse_args(argv)
    if not args.artifact:
        raise SystemExit("error: --artifact or $ARTIFACT is required")
    ctx = build_monitor_ctx(args)
    ctx.console.print(
        f"[bold]monitor[/bold] vault={ctx.vault_addr} wallet="
        f"{getattr(ctx.wallet, 'address', 'legacy')} leverageCapBps={ctx.leverage_cap_bps} "
        f"(read-only — never sends txs)"
    )
    if args.once:
        run_pass(ctx)
        return 0
    while True:
        run_pass(ctx)
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())

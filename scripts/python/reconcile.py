#!/usr/bin/env python3
"""Core-settlement reconciliation for fire-and-forget CoreWriter sends (SOLU-3368 / TODO-10 part 2).

WHY THIS EXISTS
---------------
Every Core-side action the vault submits (`pullFromCore`, `operatorRecoverSpot`,
`emergencyRepatriate`, the `usd*ToSpot/Perp` class transfers) goes out via CoreWriter
and is **fire-and-forget**: the EVM tx succeeds and the event fires *even if HyperCore
never settles the action* (insufficient balance to cover the withdrawal fee, a paused
CoreDepositWallet, a dropped `spot_send` on a unified account, etc. — see
docs/INTEGRATION.md). The EVM receipt is therefore a record of INTENT, not of SETTLEMENT.

A keeper must close that gap by RECONCILING: read the vault's Core balance before the
send, submit, then poll until the Core balance actually moves by ~the sent amount. If it
doesn't move within a timeout, the action was (silently) dropped and the keeper must RETRY.

This module is the reusable reconciliation primitive, kept free of any web3 / runner
coupling so it can be unit-reasoned and shared by both `e2e_runner.py` and the keeper loop
(SOLU-3365) without a merge collision. The caller supplies a `read_core_usdc` callable
(e.g. `lambda: vault.functions.coreSpotUsdc().call() / 1e6`) and a `send` callable; in
DRY-RUN the `send` is skipped and we only observe (so it is exercisable read-only, against
real chain state, with no funded execution).

Decimals: the vault's `coreSpotUsdc()` view returns 6dp-normalized human USDC. CoreWriter
`amountWei` for USDC is 8dp Core wei. `core_wei_to_human()` bridges the two.
"""
from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Callable, Optional


# A small withdrawal fee (~0.00134 USDC observed live, audit G2) is debited from the Core
# account ON TOP of the requested amount on a `send_asset` withdrawal. The Core balance can
# therefore fall by *slightly more* than the requested amount — never less on a real settle.
# We assert a LOWER bound on the observed decrease (>= requested - tolerance) so the fee, and
# benign sub-cent precision in the precompile read, don't produce false "did not settle" alarms.
DEFAULT_SETTLE_TOLERANCE_USDC = 0.01


def core_wei_to_human(amount_wei: int) -> float:
    """Core USDC is 8dp; the vault's coreSpotUsdc() view is 6dp-normalized human USDC."""
    return amount_wei / 1e8


@dataclass
class ReconcileResult:
    """Outcome of one reconciliation. `settled` is the keeper's retry signal (False -> retry)."""
    settled: bool
    core_before: float           # human USDC, pre-send
    core_after: float            # human USDC, last observed
    expected_decrease: float     # human USDC the send should remove from Core
    observed_decrease: float     # human USDC actually removed (>= expected on a real settle)
    dry_run: bool
    note: str = ""

    @property
    def needs_retry(self) -> bool:
        # A dropped fire-and-forget action leaves Core unchanged -> the keeper must retry.
        # DRY-RUN never asks for a retry (nothing was actually sent).
        return (not self.settled) and (not self.dry_run)


def reconcile_core_send(
    *,
    read_core_usdc: Callable[[], float],
    expected_decrease_usdc: float,
    send: Optional[Callable[[], None]] = None,
    wait_for: Callable[..., bool],
    log: Callable[[str], None] = print,
    timeout_s: int = 60,
    poll_s: float = 2.0,
    tolerance_usdc: float = DEFAULT_SETTLE_TOLERANCE_USDC,
    label: str = "core send",
    dry_run: bool = False,
) -> ReconcileResult:
    """Reconcile a single fire-and-forget Core-side send against the vault's Core balance.

    Flow: snapshot Core balance -> (optionally) send -> poll until the balance has fallen by
    >= `expected_decrease - tolerance`. Returns a ReconcileResult; `needs_retry` is True iff a
    real (non-dry-run) send did not settle within the timeout.

    `wait_for` must be the runner's poll helper with signature
    `wait_for(predicate, *, timeout_s, poll_s, label) -> bool` (passed in to avoid importing it
    here and to keep this module runner-agnostic).
    """
    core_before = read_core_usdc()
    log(f"[reconcile] {label}: Core USDC before = {core_before:,.6f}; "
        f"expecting a decrease of ~{expected_decrease_usdc:,.6f} "
        f"(fee may make it slightly larger){' [DRY-RUN]' if dry_run else ''}")

    if dry_run:
        # Observe-only: do not send. Report intent + the current (unchanged) state so the step
        # is fully exercisable read-only against the live chain without moving funds.
        core_after = read_core_usdc()
        return ReconcileResult(
            settled=False, core_before=core_before, core_after=core_after,
            expected_decrease=expected_decrease_usdc, observed_decrease=core_before - core_after,
            dry_run=True,
            note="dry-run: send skipped; no settlement expected (read-only intent check)",
        )

    if send is None:
        raise ValueError("reconcile_core_send: `send` is required when dry_run is False")

    send()  # fire-and-forget: this returns on EVM-receipt success, NOT on Core settlement.

    threshold = max(0.0, expected_decrease_usdc - tolerance_usdc)
    settled = wait_for(
        lambda: (core_before - read_core_usdc()) >= threshold,
        timeout_s=timeout_s, poll_s=poll_s, label=label,
    )
    core_after = read_core_usdc()
    observed = core_before - core_after

    if settled:
        log(f"[reconcile] {label}: SETTLED — Core USDC {core_before:,.6f} -> {core_after:,.6f} "
            f"(-{observed:,.6f}); EVM intent confirmed on Core.")
        note = "settled"
    else:
        # Core did not move enough within the timeout: the fire-and-forget action was almost
        # certainly DROPPED (fee uncovered / wallet paused / wrong action id). RETRY required.
        log(f"[reconcile] {label}: WARNING — Core did NOT settle within {timeout_s}s. "
            f"Core USDC {core_before:,.6f} -> {core_after:,.6f} (observed -{observed:,.6f}, "
            f"expected >= -{threshold:,.6f}). The CoreWriter action is fire-and-forget and the "
            f"EVM tx already succeeded — this almost certainly means the action was DROPPED. "
            f"RETRY the send.")
        note = "not settled within timeout — retry required"

    return ReconcileResult(
        settled=settled, core_before=core_before, core_after=core_after,
        expected_decrease=expected_decrease_usdc, observed_decrease=observed,
        dry_run=False, note=note,
    )

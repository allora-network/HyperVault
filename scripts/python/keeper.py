"""Redemption-fulfillment keeper loop for HyperCoreVault (Assessment TODO-4).

The vault's redemption queue is **permissionless**: any keeper may repatriate
capital from HyperCore and call `fulfillWithdraw(lp)` to pay an LP out of idle
EVM USDC. This module automates that loop. It:

  1. Watches `WithdrawalRequested(lp, shares)` events from a start block via
     `eth_getLogs` polling (web3.py, no websocket).
  2. Tracks one open request per LP (the vault enforces singularity).
  3. Per pending LP, sizes the claim (`previewRedeem(pendingWithdrawalShares)`)
     against *free* idle (`idleUsdc() - reservedIdleUsdc()`). When idle is short
     and Core holds material capital, it repatriates: `usdPerpToSpot(needed)` if
     perp equity exists, then `pullFromCore(int(coreSpotWei * 0.998))` — the
     mandatory **fee guard** (HyperCore deducts a ~0.00134 USDC withdrawal fee on
     top of the requested amount, so the EXACT-full balance is silently dropped).
  4. Calls `fulfillWithdraw(lp)`, records the payout (parsed from
     `WithdrawalFulfilled`) and any residual (a partial fill leaves
     `pendingWithdrawalShares(lp) > 0` — the LP stays pending for the next pass).
  5. Each pass reads the CoreDepositWallet `paused()` state. If paused, the pull
     route is dead: it WARNS loudly, skips all repatriation (never pulls into a
     paused wallet — it would revert and strand), but still fulfills against
     whatever idle already exists.

It runs against a live/forked RPC. **Dry-run is the default** (`execute=False`):
it reads REAL on-chain state via `eth_call` and logs the actions it WOULD take
without sending any transaction. The tx-sending mode is an explicit opt-in
(`--keeper-execute` on the CLI) and is gated behind a human for the funded
battle-test. Nothing here fabricates balances or settlement.

CoreWriter is fire-and-forget: after a `pullFromCore` the EVM tx succeeds before
HyperCore settles, so settlement is confirmed by polling `idleUsdc()` with a
bounded `wait_for`, recording a failure on timeout rather than assuming credit.
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Optional

from rich.table import Table
from web3.types import TxReceipt

import hl_helpers as hl

if TYPE_CHECKING:  # e2e_runner imports this module lazily; keep the type import compile-only
    from e2e_runner import Ctx


# The HyperCore withdrawal-fee guard: pull strictly UNDER the Core spot balance so
# the ~0.00134 USDC fee is always covered. The exact-full amount is silently
# dropped (Core never debits). Proven live in the G2 spike; mirrors step_pull.
FEE_GUARD_FRACTION = 0.998

# uint64 ceiling — pullFromCore / usdPerpToSpot both take uint64 Core-USDC wei.
_UINT64_MAX = 2 ** 64 - 1


@dataclass
class LpRecord:
    """Bookkeeping for one LP's open redemption request across keeper passes."""
    lp: str
    requested_shares: int                 # shares seen on the latest WithdrawalRequested
    first_seen_block: int
    total_paid_wei: int = 0               # cumulative USDC (6dp) paid out across passes
    fulfilled: bool = False               # request fully cleared (no residual shares)
    residual_shares: int = 0              # pendingWithdrawalShares after the last fulfill
    passes: int = 0                       # number of fulfill attempts made for this LP


@dataclass
class KeeperConfig:
    """Runtime knobs for the loop (wired from the e2e_runner CLI)."""
    execute: bool = False                 # False = dry-run (read + log only); True = send txs
    poll_s: float = 5.0                   # seconds between event/fulfill passes
    max_iterations: int = 12              # hard bound on passes (0 == until timeout)
    timeout_s: int = 600                  # overall wall-clock bound for the loop
    start_block: Optional[int] = None     # event scan start (default: head - lookback)
    lookback_blocks: int = 5_000          # how far back to seed the scan when start_block is unset
    log_chunk: int = 2_000                # max block span per eth_getLogs request
    settle_timeout_s: int = 60            # wait_for bound on async Core->EVM settlement
    min_material_usdc: float = 0.01       # ignore Core dust below this when deciding to repatriate


@dataclass
class KeeperState:
    """Accumulated keeper state — surfaced in the end-of-run report."""
    config: KeeperConfig
    lps: dict[str, LpRecord] = field(default_factory=dict)
    last_scanned_block: int = 0
    paused_passes: int = 0                # passes observed with the wallet paused
    iterations: int = 0


# -----------------------------------------------------------------------------
# Event watching
# -----------------------------------------------------------------------------

def _scan_withdrawal_requests(ctx: "Ctx", state: KeeperState, to_block: int) -> int:
    """Scan WithdrawalRequested logs in [last_scanned+1, to_block], updating state.

    Returns the count of new/refreshed events seen. Chunked to respect RPC
    `eth_getLogs` span caps. The `lp` topic is indexed, so this is a cheap filter.
    """
    cfg = state.config
    from_block = max(cfg.start_block or 0, state.last_scanned_block + 1)
    if from_block > to_block:
        return 0

    event = ctx.vault.events.WithdrawalRequested()
    found = 0
    cursor = from_block
    while cursor <= to_block:
        chunk_end = min(cursor + cfg.log_chunk - 1, to_block)
        logs = event.get_logs(from_block=cursor, to_block=chunk_end)
        for log in logs:
            lp = ctx.w3.to_checksum_address(log["args"]["lp"])
            shares = int(log["args"]["shares"])
            blk = int(log["blockNumber"])
            record = state.lps.get(lp)
            if record is None:
                state.lps[lp] = LpRecord(lp=lp, requested_shares=shares, first_seen_block=blk)
            else:
                # One open request per LP: a fresh event supersedes the prior view.
                record.requested_shares = shares
                record.fulfilled = False
            found += 1
        cursor = chunk_end + 1

    state.last_scanned_block = to_block
    return found


# -----------------------------------------------------------------------------
# Repatriation + fulfillment for a single LP
# -----------------------------------------------------------------------------

def _free_idle_wei(ctx: "Ctx") -> int:
    """Idle EVM USDC not already reserved for prioritized requests (6dp)."""
    idle = ctx.vault.functions.idleUsdc().call()
    reserved = ctx.vault.functions.reservedIdleUsdc().call()
    return max(0, idle - reserved)


def _repatriate_for_claim(ctx: "Ctx", state: KeeperState, record: LpRecord,
                          claim_wei: int, free_wei: int) -> None:
    """Move enough Core capital to EVM idle to (try to) cover `claim_wei`.

    Two legs when capital sits on perp margin: usdPerpToSpot first, then
    pullFromCore with the fee guard. Settlement is async — poll idle until it
    rises, recording a failure on timeout. Dry-run logs the intended legs only.
    """
    from e2e_runner import wait_for

    cfg = state.config
    shortfall_wei = max(0, claim_wei - free_wei)
    if shortfall_wei == 0:
        return

    spot_human = hl.spot_balance(ctx.info, ctx.vault_addr, 0)
    spot_core_wei = int(spot_human * 1e8)
    perp_withdrawable_wei = ctx.vault.functions.perpWithdrawable().call()  # 6dp

    material = spot_human >= cfg.min_material_usdc or perp_withdrawable_wei > 0
    if not material:
        ctx.console.print(
            f"  [yellow]LP {record.lp}: short {shortfall_wei/1e6:.6f} USDC but no material "
            f"Core capital (spot {spot_human:.6f}, perp {perp_withdrawable_wei/1e6:.6f}) "
            f"— can only fulfill against idle[/yellow]"
        )
        return

    # Leg 1 (perp -> spot): pull the shortfall down from perp margin when the spot
    # leg alone can't cover it. usdPerpToSpot takes the human notional in 6dp units.
    if perp_withdrawable_wei > 0 and spot_core_wei < _to_core_wei(shortfall_wei):
        need_ntl = min(perp_withdrawable_wei, shortfall_wei, _UINT64_MAX)  # 6dp, capped
        if cfg.execute:
            ctx.console.print(f"  usdPerpToSpot({int(need_ntl)}) — perp->spot {need_ntl/1e6:.6f} USDC")
            _send(ctx, ctx.vault.functions.usdPerpToSpot(int(need_ntl)))
            # Re-read spot after the class transfer settles enough to size the pull.
            wait_for(lambda: hl.spot_balance(ctx.info, ctx.vault_addr, 0) > spot_human,
                     timeout_s=cfg.settle_timeout_s, label="perp->spot class transfer")
            spot_human = hl.spot_balance(ctx.info, ctx.vault_addr, 0)
            spot_core_wei = int(spot_human * 1e8)
        else:
            ctx.console.print(
                f"  [cyan]DRY-RUN[/cyan] would usdPerpToSpot({int(need_ntl)}) "
                f"(perp->spot {need_ntl/1e6:.6f} USDC)"
            )

    # Leg 2 (spot -> EVM): pull strictly under the Core spot balance (fee guard).
    pull_wei = min(int(spot_core_wei * FEE_GUARD_FRACTION), _UINT64_MAX)
    if pull_wei <= 0:
        ctx.console.print("  [yellow]nothing on Core spot to pull after class transfer[/yellow]")
        return

    if not cfg.execute:
        ctx.console.print(
            f"  [cyan]DRY-RUN[/cyan] would pullFromCore({pull_wei}) "
            f"(spot {spot_human:.8f} * {FEE_GUARD_FRACTION} = {pull_wei/1e8:.8f} USDC; fee-guarded)"
        )
        return

    idle_before = ctx.usdc.functions.balanceOf(ctx.vault_addr).call()
    ctx.console.print(f"  pullFromCore({pull_wei}) — fee-guarded ({pull_wei/1e8:.8f} Core USDC)")
    _send(ctx, ctx.vault.functions.pullFromCore(pull_wei))

    settled = wait_for(
        lambda: ctx.usdc.functions.balanceOf(ctx.vault_addr).call() > idle_before,
        timeout_s=cfg.settle_timeout_s, label="Core->EVM repatriation credit",
    )
    idle_after = ctx.usdc.functions.balanceOf(ctx.vault_addr).call()
    ctx.console.print(f"  vault idle USDC: {idle_before/1e6:.6f} -> {idle_after/1e6:.6f}")
    if not settled:
        msg = f"keeper: repatriation for {record.lp} did not credit idle within {cfg.settle_timeout_s}s"
        ctx.console.print(f"  [red]{msg}[/red]")
        ctx.failures.append(msg)


def _process_lp(ctx: "Ctx", state: KeeperState, record: LpRecord, wallet_paused: bool) -> None:
    """One fulfill attempt for one LP: size the claim, repatriate if needed and
    the wallet is live, then call fulfillWithdraw and record payout + residual."""
    pending_shares = ctx.vault.functions.pendingWithdrawalShares(record.lp).call()
    if pending_shares == 0:
        record.fulfilled = True
        record.residual_shares = 0
        ctx.console.print(f"  [green]LP {record.lp}: no pending shares — already settled[/green]")
        return

    claim_wei = ctx.vault.functions.previewRedeem(pending_shares).call()
    free_wei = _free_idle_wei(ctx)
    overdue = ctx.vault.functions.requestIsOverdue(record.lp).call()
    ctx.console.print(
        f"  LP {record.lp}: pending {pending_shares} shares "
        f"(~{claim_wei/1e6:.6f} USDC), free idle {free_wei/1e6:.6f} USDC, overdue={overdue}"
    )

    if free_wei >= claim_wei:
        ctx.console.print("  idle already covers the claim — no repatriation needed")
    elif wallet_paused:
        ctx.console.print(
            "  [bold yellow]WALLET PAUSED — skipping repatriation; the Core->EVM pull route "
            "is dead. Fulfilling against existing idle only.[/bold yellow]"
        )
    else:
        _repatriate_for_claim(ctx, state, record, claim_wei, free_wei)

    record.passes += 1

    if not state.config.execute:
        payable_wei = min(claim_wei, _free_idle_wei(ctx))
        partial = " (PARTIAL — residual would remain)" if payable_wei < claim_wei else ""
        ctx.console.print(
            f"  [cyan]DRY-RUN[/cyan] would fulfillWithdraw({record.lp}) — "
            f"pays ~{payable_wei/1e6:.6f} USDC from idle{partial}"
        )
        return

    usdc_before = ctx.usdc.functions.balanceOf(record.lp).call()
    receipt = _send(ctx, ctx.vault.functions.fulfillWithdraw(record.lp), gas=400_000)
    paid_wei = ctx.usdc.functions.balanceOf(record.lp).call() - usdc_before
    record.total_paid_wei += max(0, paid_wei)

    ev = _parse_fulfilled(ctx, receipt)
    event_paid = ev["assets"] if ev else None
    residual = ctx.vault.functions.pendingWithdrawalShares(record.lp).call()
    record.residual_shares = residual
    record.fulfilled = residual == 0

    ev_str = f" (event assets={event_paid/1e6:.6f})" if event_paid is not None else ""
    cleared = "CLEARED" if record.fulfilled else "PARTIAL — stays pending"
    ctx.console.print(
        f"  [green]fulfilled[/green] LP {record.lp}: paid {paid_wei/1e6:.6f} USDC{ev_str}; "
        f"residual {residual} shares ({cleared})"
    )


# -----------------------------------------------------------------------------
# Thin tx / event / unit shims (keep this module standalone but reuse runner semantics)
# -----------------------------------------------------------------------------

def _send(ctx: "Ctx", fn, *, gas: int = 600_000) -> TxReceipt:
    """Send a tx as the keeper (operator key), reusing the runner's send_tx."""
    from e2e_runner import send_tx
    return send_tx(ctx, ctx.operator, fn, gas=gas)


def _parse_fulfilled(ctx: "Ctx", receipt: TxReceipt) -> Optional[dict]:
    """Parse the WithdrawalFulfilled event off a fulfill receipt, or None."""
    from e2e_runner import parse_event
    return parse_event(ctx, receipt, "WithdrawalFulfilled")


def _to_core_wei(evm_wei_6dp: int) -> int:
    """USDC 6dp (EVM) -> 8dp (Core) wei."""
    return evm_wei_6dp * 100


# -----------------------------------------------------------------------------
# The loop
# -----------------------------------------------------------------------------

def run_keeper(ctx: "Ctx", config: KeeperConfig) -> bool:
    """Run the redemption-fulfillment keeper loop until the queue drains or a
    bound is hit. Returns True on a clean run (no failures recorded by this
    loop). Mutates `ctx.failures` like the other steps."""
    from e2e_runner import core_deposit_wallet

    mode = "EXECUTE (sends txs)" if config.execute else "DRY-RUN (reads + logs only)"
    ctx.console.rule(f"[bold]keeper loop — redemption fulfillment ({mode})")
    if not config.execute:
        ctx.console.print(
            "[cyan]Dry-run: reading live on-chain state and logging intended actions. "
            "No transactions will be sent. Pass --keeper-execute for the funded run "
            "(human-gated).[/cyan]"
        )

    state = KeeperState(config=config)
    head = ctx.w3.eth.block_number
    if config.start_block is None:
        config.start_block = max(0, head - config.lookback_blocks)
    state.last_scanned_block = config.start_block - 1
    ctx.console.print(
        f"watching WithdrawalRequested from block {config.start_block} "
        f"(head {head}); poll {config.poll_s}s, max_iter {config.max_iterations}, "
        f"timeout {config.timeout_s}s"
    )

    wallet = core_deposit_wallet(ctx)
    start = time.time()
    failures_before = len(ctx.failures)

    while True:
        if time.time() - start >= config.timeout_s:
            ctx.console.print(f"[yellow]keeper: wall-clock timeout ({config.timeout_s}s) — stopping[/yellow]")
            break
        if config.max_iterations and state.iterations >= config.max_iterations:
            ctx.console.print(f"[yellow]keeper: hit max_iterations ({config.max_iterations}) — stopping[/yellow]")
            break

        state.iterations += 1
        ctx.console.rule(f"[dim]pass {state.iterations}", style="dim")

        # Wallet posture — read every pass (it can be paused mid-run).
        wallet_paused = False
        if wallet is not None:
            wallet_paused = wallet.functions.paused().call()
            if wallet_paused:
                state.paused_passes += 1
                ctx.console.print(
                    "[bold red]WARNING: CoreDepositWallet is PAUSED — the Core->EVM pull route "
                    "is unavailable. Repatriation is skipped this pass; only idle-backed "
                    "fulfillment will proceed.[/bold red]"
                )
        else:
            ctx.console.print("[yellow]legacy-mode vault (no CoreDepositWallet) — pause guard N/A[/yellow]")

        # 1) Pull in any new requests.
        head = ctx.w3.eth.block_number
        new_count = _scan_withdrawal_requests(ctx, state, head)
        if new_count:
            ctx.console.print(f"scanned to block {head}: {new_count} WithdrawalRequested event(s)")

        # 2) Work the open (not-yet-cleared) requests.
        pending = [r for r in state.lps.values() if not r.fulfilled]
        if not pending:
            ctx.console.print("[dim]no open requests this pass[/dim]")
        for record in pending:
            try:
                _process_lp(ctx, state, record, wallet_paused)
            except Exception as e:  # one bad LP must not kill the loop
                msg = f"keeper: processing LP {record.lp} raised: {e}"
                ctx.console.print(f"  [red]{msg}[/red]")
                ctx.failures.append(msg)

        # 3) Stop early once every tracked request is cleared.
        if state.lps and all(r.fulfilled for r in state.lps.values()):
            ctx.console.print("[green]all tracked requests cleared — keeper draining complete[/green]")
            break

        time.sleep(config.poll_s)

    _report(ctx, state)
    return len(ctx.failures) == failures_before


def _report(ctx: "Ctx", state: KeeperState) -> None:
    """Structured end-of-run summary of fulfilled LPs and residuals."""
    ctx.console.rule("[bold]keeper summary")
    tbl = Table(show_header=True, header_style="bold")
    tbl.add_column("LP")
    tbl.add_column("status")
    tbl.add_column("paid (USDC)", justify="right")
    tbl.add_column("residual shares", justify="right")
    tbl.add_column("passes", justify="right")
    for record in state.lps.values():
        status = "CLEARED" if record.fulfilled else "OPEN"
        colour = "green" if record.fulfilled else "yellow"
        tbl.add_row(
            record.lp,
            f"[{colour}]{status}[/{colour}]",
            f"{record.total_paid_wei/1e6:.6f}",
            str(record.residual_shares),
            str(record.passes),
        )
    if not state.lps:
        tbl.add_row("(none)", "-", "-", "-", "-")
    ctx.console.print(tbl)

    cleared = sum(1 for r in state.lps.values() if r.fulfilled)
    open_ct = len(state.lps) - cleared
    ctx.console.print(
        f"iterations: {state.iterations}  LPs seen: {len(state.lps)}  "
        f"cleared: {cleared}  open/residual: {open_ct}  "
        f"passes with wallet paused: {state.paused_passes}"
    )
    if not state.config.execute:
        ctx.console.print("[cyan]DRY-RUN — no transactions were sent.[/cyan]")

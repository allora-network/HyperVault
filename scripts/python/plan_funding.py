#!/usr/bin/env python3
"""Per-account funding planner for the HyperVault live-spike battle-test.

WHY THIS EXISTS
---------------
A funded battle-test runs ten LP wallets (lp1..lp10) plus a `trigger` wallet, each
with a target USDC tier and each needing a little native HYPE for gas. Before the
run, the human funding the spike needs to know EXACTLY how much USDC + HYPE to send
to each address — no more (it's real money on a throwaway), no less (a short wallet
stalls a scenario mid-flight). This script reads the keyfile (addresses + tiers)
and live balances, computes the shortfall per account, and prints a copy-pasteable
block of `cast send` commands for the HUMAN to run from their own funded wallet.

It NEVER signs or broadcasts anything. It holds no private key of the funding
wallet; the emitted `cast send` lines are placeholders the human fills in and runs.
`--check` re-reads balances and prints an OK/SHORT table against tier + gas buffer
so the human can confirm funding landed before kicking off `battle_test.py`.

Itemized separately so they don't pollute NAV reconciliation:
  - operator's one-time +1.0 USDC Core-account activation reserve (first push), and
  - an estimate of HyperCore withdrawal fees (~0.00134 USDC per pull) across the run.
These are spike overheads, not LP capital.

Decimals: USDC is 6dp; native HYPE is 18dp (wei).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from rich.console import Console
from rich.table import Table
from web3 import Web3

from accounts import ERC20_ABI

# --- spike overhead constants (documented in CLAUDE.md / docs/INTEGRATION.md) ---
# A vault's FIRST push to a fresh Core account costs ~1.0 USDC activation gas (one-time).
FIRST_PUSH_ACTIVATION_USDC = 1.0
# HyperCore deducts a ~0.00134 USDC withdrawal fee per `send_asset` pull, on top of
# the requested amount. Budget a handful of pulls so the fee never starves a pull.
WITHDRAWAL_FEE_PER_PULL_USDC = 0.00134
DEFAULT_EXPECTED_PULLS = 20  # generous upper bound for a multi-scenario spike

# Native HYPE gas buffers (human HYPE). LPs only deposit/redeem/request; the
# operator/trigger send the heavier trade + repatriation + escape txs.
LP_GAS_BUFFER_HYPE = 0.05
OPERATOR_GAS_BUFFER_HYPE = 0.5
TRIGGER_GAS_BUFFER_HYPE = 0.2


@dataclass
class AccountPlan:
    """Funding plan for one keyfile account."""
    name: str
    address: str
    tier_usdc: float
    current_usdc: float
    usdc_shortfall: float        # USDC to send to reach tier
    current_hype: float
    gas_buffer_hype: float
    hype_shortfall: float        # native HYPE to send to reach the gas buffer


def _gas_buffer_for(name: str) -> float:
    """Per-role native HYPE buffer: operator/trigger move more than LPs."""
    if name == "operator":
        return OPERATOR_GAS_BUFFER_HYPE
    if name == "trigger":
        return TRIGGER_GAS_BUFFER_HYPE
    return LP_GAS_BUFFER_HYPE


def _load_keyfile(path: str) -> dict:
    """Read the battle keyfile JSON (gen_battle_keys writes it; we read it directly)."""
    data = json.loads(Path(path).read_text())
    if "accounts" not in data:
        raise ValueError(f"keyfile {path} has no 'accounts' map")
    return data


def plan(w3: Web3, usdc, keyfile: dict, *, expected_pulls: int) -> tuple[list[AccountPlan], dict]:
    """Compute the per-account funding plan + the itemized spike-overhead block.

    Reads live USDC `balanceOf` (6dp) and native HYPE `get_balance` (wei) per
    account, then derives shortfalls against tier + gas buffer. Returns
    (plans, overheads). Read-only.
    """
    accounts = keyfile["accounts"]
    plans: list[AccountPlan] = []
    for name in sorted(accounts):
        meta = accounts[name]
        addr = Web3.to_checksum_address(meta["address"])
        tier = float(meta.get("tier_usdc", 0.0))

        cur_usdc_raw = usdc.functions.balanceOf(addr).call()
        cur_usdc = cur_usdc_raw / 1e6
        cur_hype_wei = w3.eth.get_balance(addr)
        cur_hype = float(w3.from_wei(cur_hype_wei, "ether"))

        gas_buffer = _gas_buffer_for(name)
        plans.append(AccountPlan(
            name=name,
            address=addr,
            tier_usdc=tier,
            current_usdc=cur_usdc,
            usdc_shortfall=max(0.0, tier - cur_usdc),
            current_hype=cur_hype,
            gas_buffer_hype=gas_buffer,
            hype_shortfall=max(0.0, gas_buffer - cur_hype),
        ))

    # Itemized spike overheads (kept OUT of LP tiers so they don't skew NAV recon).
    overheads = {
        "operator_first_push_activation_usdc": FIRST_PUSH_ACTIVATION_USDC,
        "expected_pulls": expected_pulls,
        "withdrawal_fee_per_pull_usdc": WITHDRAWAL_FEE_PER_PULL_USDC,
        "withdrawal_fees_total_usdc": round(WITHDRAWAL_FEE_PER_PULL_USDC * expected_pulls, 6),
    }
    return plans, overheads


def _print_plan(console: Console, plans: list[AccountPlan], overheads: dict,
                usdc_addr: str) -> None:
    """Print the funding table + copy-pasteable cast-send commands. NEVER sends."""
    tbl = Table(show_header=True, header_style="bold", title="funding plan (live balances vs tier)")
    tbl.add_column("name")
    tbl.add_column("address")
    tbl.add_column("tier USDC", justify="right")
    tbl.add_column("have USDC", justify="right")
    tbl.add_column("send USDC", justify="right")
    tbl.add_column("have HYPE", justify="right")
    tbl.add_column("send HYPE", justify="right")
    total_usdc = 0.0
    total_hype = 0.0
    for p in plans:
        total_usdc += p.usdc_shortfall
        total_hype += p.hype_shortfall
        send_usdc = f"[green]{p.usdc_shortfall:,.6f}[/green]" if p.usdc_shortfall > 0 else "0"
        send_hype = f"[green]{p.hype_shortfall:,.4f}[/green]" if p.hype_shortfall > 0 else "0"
        tbl.add_row(
            p.name, p.address,
            f"{p.tier_usdc:,.2f}", f"{p.current_usdc:,.6f}", send_usdc,
            f"{p.current_hype:,.4f}", send_hype,
        )
    console.print(tbl)

    console.print(
        f"[bold]totals to fund:[/bold] {total_usdc:,.6f} USDC + {total_hype:,.4f} HYPE (LP/role tiers only)"
    )

    # Itemized overheads — surfaced separately so they're not counted as LP capital.
    over = Table(show_header=False, box=None, title="itemized spike overheads (NOT LP capital)")
    over.add_row("operator first-push activation",
                 f"{overheads['operator_first_push_activation_usdc']:,.6f} USDC (one-time)")
    over.add_row("withdrawal fees (estimate)",
                 f"{overheads['withdrawal_fees_total_usdc']:,.6f} USDC "
                 f"(~{overheads['withdrawal_fee_per_pull_usdc']} × {overheads['expected_pulls']} pulls)")
    console.print(over)

    grand_usdc = total_usdc + overheads["operator_first_push_activation_usdc"] + \
        overheads["withdrawal_fees_total_usdc"]
    console.print(
        f"[bold]grand total USDC to source from the funding wallet:[/bold] {grand_usdc:,.6f} USDC "
        f"(tiers {total_usdc:,.6f} + overheads {grand_usdc - total_usdc:,.6f})"
    )

    # Copy-pasteable cast-send block (HUMAN runs these from their funded wallet).
    console.print("\n[bold]cast send commands (run from YOUR funded wallet — this script never signs):[/bold]")
    console.print("[dim]# set FUNDER_KEY to the funding wallet's private key, RPC to mainnet[/dim]")
    console.print("[dim]export RPC=$HYPEREVM_RPC_MAINNET ; export FUNDER_KEY=0x...  # placeholder[/dim]")
    for p in plans:
        if p.usdc_shortfall > 0:
            units = int(round(p.usdc_shortfall * 1e6))
            console.print(
                f"cast send {usdc_addr} 'transfer(address,uint256)' "
                f"{p.address} {units} --rpc-url $RPC --private-key $FUNDER_KEY  "
                f"[dim]# {p.name}: +{p.usdc_shortfall:,.6f} USDC[/dim]"
            )
    console.print("[dim]# native HYPE drips (value is in wei):[/dim]")
    for p in plans:
        if p.hype_shortfall > 0:
            wei = Web3.to_wei(p.hype_shortfall, "ether")
            console.print(
                f"cast send {p.address} --value {wei} --rpc-url $RPC --private-key $FUNDER_KEY  "
                f"[dim]# {p.name}: +{p.hype_shortfall:,.4f} HYPE[/dim]"
            )


def _print_check(console: Console, plans: list[AccountPlan]) -> int:
    """Print an OK/SHORT table; return the count of SHORT accounts."""
    tbl = Table(show_header=True, header_style="bold", title="--check: funded vs tier + gas buffer")
    tbl.add_column("name")
    tbl.add_column("address")
    tbl.add_column("USDC have/tier", justify="right")
    tbl.add_column("HYPE have/buf", justify="right")
    tbl.add_column("status")
    short = 0
    for p in plans:
        usdc_ok = p.usdc_shortfall <= 0
        hype_ok = p.hype_shortfall <= 0
        ok = usdc_ok and hype_ok
        if not ok:
            short += 1
        status = "[green]OK[/green]" if ok else "[red]SHORT[/red]"
        tbl.add_row(
            p.name, p.address,
            f"{p.current_usdc:,.4f}/{p.tier_usdc:,.2f}",
            f"{p.current_hype:,.4f}/{p.gas_buffer_hype:,.2f}",
            status,
        )
    console.print(tbl)
    if short:
        console.print(f"[red]{short} account(s) SHORT — fund them before starting the battle-test[/red]")
    else:
        console.print("[green]all accounts funded to tier + gas buffer[/green]")
    return short


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Plan/check per-account battle-test funding (read-only; never signs/sends).")
    parser.add_argument("--artifact", default=os.environ.get("ARTIFACT"),
                        help="path to deployments/<chain>/<strategy>.json (for the USDC address)")
    parser.add_argument("--rpc-url", default=os.environ.get("HYPEREVM_RPC_MAINNET"))
    parser.add_argument("--network", default="mainnet", choices=["mainnet", "testnet"])
    parser.add_argument("--keys", default=os.environ.get("BATTLE_KEYS"),
                        help="path to the battle keyfile JSON (addresses + tiers)")
    parser.add_argument("--check", action="store_true",
                        help="re-read balances and print an OK/SHORT table vs tier + gas buffer")
    parser.add_argument("--expected-pulls", type=int, default=DEFAULT_EXPECTED_PULLS,
                        help="withdrawal-fee budget: number of Core->EVM pulls expected")
    args = parser.parse_args(argv)

    if not args.artifact:
        print("--artifact (or $ARTIFACT) required", file=sys.stderr)
        return 2
    if not args.keys:
        print("--keys (or $BATTLE_KEYS) required", file=sys.stderr)
        return 2

    console = Console()
    artifact = json.loads(Path(args.artifact).read_text())
    usdc_addr = Web3.to_checksum_address(artifact["asset"])

    rpc = args.rpc_url or os.environ.get("HYPEREVM_RPC_MAINNET")
    if not rpc:
        print("--rpc-url (or $HYPEREVM_RPC_MAINNET) required", file=sys.stderr)
        return 2
    w3 = Web3(Web3.HTTPProvider(rpc))
    if not w3.is_connected():
        print(f"RPC not reachable: {rpc}", file=sys.stderr)
        return 2

    usdc = w3.eth.contract(address=usdc_addr, abi=ERC20_ABI)
    keyfile = _load_keyfile(args.keys)

    plans, overheads = plan(w3, usdc, keyfile, expected_pulls=args.expected_pulls)

    if args.check:
        short = _print_check(console, plans)
        return 1 if short else 0

    _print_plan(console, plans, overheads, usdc_addr)
    console.print("\n[cyan]Read-only plan — this script signs nothing. Run the cast commands "
                  "yourself, then re-run with --check to confirm.[/cyan]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

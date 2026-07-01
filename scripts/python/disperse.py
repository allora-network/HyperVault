#!/usr/bin/env python3
"""Fan funds out from the funder to every battle-test wallet, with an audit trail.

The human funds ONE wallet (the "funder" in the keyfile) with USDC + native HYPE
on HyperEVM. This script then disperses the per-account allocations (USDC.transfer
+ native HYPE sends) recorded in the keyfile to operator/emergency/feeRecipient,
the ten LPs, and the trigger caller — writing every transfer to a JSON-lines audit
log so the whole distribution is reconcilable.

DRY-RUN-FIRST: without ``--execute`` it sends NOTHING — it reads the funder's live
balances, prints the full plan, and flags any shortfall. ``--execute`` broadcasts
the transfers (signed by the throwaway funder key from the keyfile). Run the
dry-run, fund the funder, then re-run with ``--execute``.

Usage (run from the repo root):
    python3 scripts/python/gen_battle_keys.py            # 1) make the keyfile, get the funder addr
    # ... human funds the funder with the printed USDC + HYPE ...
    python3 scripts/python/disperse.py                   # 2) dry-run: shows the plan + balances
    python3 scripts/python/disperse.py --execute         # 3) broadcast the fan-out
    python3 scripts/python/disperse.py --check           # balances vs allocation, anytime
"""
from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path

from eth_account import Account
from rich.console import Console
from rich.table import Table
from web3 import Web3

from accounts import DEFAULT_KEYFILE, ERC20_ABI, normalize_key
from e2e_runner import usdc_units

# The vault's USDC on HyperEVM (Circle-bridged, 6dp). Funding happens pre-deploy,
# so we can't read it from an artifact — default to the known token, allow override.
SPIKE_USDC = "0xb88339CB7199b77E23DB6E890353E22632Ba630f"
DEFAULT_AUDIT_LOG = "logs/disperse_audit.jsonl"
ERC20_GAS = 100_000
NATIVE_GAS = 21_000


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _audit(path: str, rec: dict) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("a") as fh:
        fh.write(json.dumps(rec) + "\n")


def _send(w3: Web3, funder: Account, tx: dict) -> str:
    signed = funder.sign_transaction(tx)
    raw = getattr(signed, "raw_transaction", None) or signed.rawTransaction  # web3 7.x / 6.x
    h = w3.eth.send_raw_transaction(raw)
    receipt = w3.eth.wait_for_transaction_receipt(h)
    if receipt.status != 1:
        raise RuntimeError(f"transfer reverted: {h.hex()}")
    return h.hex()


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Disperse battle-test funds from the funder (dry-run-first).")
    p.add_argument("--keys", default=DEFAULT_KEYFILE, help="keyfile path")
    p.add_argument("--rpc-url", default=None, help="HyperEVM RPC (default $HYPEREVM_RPC_MAINNET)")
    p.add_argument("--usdc", default=SPIKE_USDC, help="USDC ERC20 address on HyperEVM")
    p.add_argument("--audit-log", default=DEFAULT_AUDIT_LOG, help="JSON-lines audit trail output")
    p.add_argument("--execute", action="store_true", help="ACTUALLY BROADCAST (default: dry-run)")
    p.add_argument("--check", action="store_true", help="just report balances vs allocations, send nothing")
    args = p.parse_args(argv)

    console = Console()
    data = json.loads(Path(args.keys).read_text())
    accounts = data["accounts"]
    funder_name = data.get("funder", "funder")
    funder_rec = accounts[funder_name]
    funder = Account.from_key(normalize_key(funder_rec["key"]))

    rpc = args.rpc_url or os.environ["HYPEREVM_RPC_MAINNET"]
    w3 = Web3(Web3.HTTPProvider(rpc))
    assert w3.is_connected(), f"RPC not reachable: {rpc}"
    usdc = w3.eth.contract(address=Web3.to_checksum_address(args.usdc), abi=ERC20_ABI)

    # Recipients = everyone except the funder, in a sensible order.
    order = ["operator", "emergency", "feeRecipient"] + \
            [n for n in accounts if n.startswith("lp")] + ["trigger"]
    recipients = [n for n in order if n in accounts and n != funder_name]

    need_usdc = sum(float(accounts[n].get("alloc_usdc", 0)) for n in recipients)
    need_hype = sum(float(accounts[n].get("alloc_hype", 0)) for n in recipients)

    funder_usdc = usdc.functions.balanceOf(funder.address).call() / 1e6
    funder_hype = w3.eth.get_balance(funder.address) / 1e18

    # --- report ---------------------------------------------------------------
    head = Table(title=f"disperse from funder {funder.address}")
    for c in ("", "USDC", "HYPE"):
        head.add_column(c, justify="right" if c else "left")
    head.add_row("funder balance", f"{funder_usdc:,.4f}", f"{funder_hype:,.4f}")
    head.add_row("needed (sum allocs)", f"{need_usdc:,.4f}", f"{need_hype:,.4f}")
    head.add_row("surplus/short", f"{funder_usdc - need_usdc:+,.4f}", f"{funder_hype - need_hype:+,.4f}")
    console.print(head)

    # The funder also spends native gas on the transfers themselves — require a margin
    # on top of the HYPE it sends out (and FUND_TOTALS bakes in a deploy reserve too).
    gas_margin = 0.2
    short = funder_usdc + 1e-9 < need_usdc or funder_hype + 1e-9 < need_hype + gas_margin
    if short:
        console.print("[bold red]FUNDER SHORT[/bold red] — top it up before --execute "
                      f"(needs >= {need_usdc:.2f} USDC + {need_hype + gas_margin:.2f} HYPE "
                      "incl. send-gas margin; fund the FUND_TOTALS amount for the deploy reserve too).")

    plan = Table(title="per-recipient allocation")
    for c in ("name", "address", "USDC", "HYPE"):
        plan.add_column(c, justify="right" if c in ("USDC", "HYPE") else "left")
    for n in recipients:
        plan.add_row(n, accounts[n]["address"],
                     f"{float(accounts[n].get('alloc_usdc', 0)):.2f}",
                     f"{float(accounts[n].get('alloc_hype', 0)):.2f}")
    console.print(plan)

    if args.check:
        return 0
    if not args.execute:
        console.print("[cyan]DRY-RUN[/cyan] — no transfers sent. Re-run with --execute to broadcast.")
        return 0
    if short:
        raise SystemExit("refusing to --execute while the funder is short; top it up first.")

    # --- execute --------------------------------------------------------------
    console.print("[bold green]EXECUTE[/bold green] — broadcasting transfers from the funder.")
    nonce = w3.eth.get_transaction_count(funder.address)
    gas_price = w3.eth.gas_price
    chain_id = w3.eth.chain_id
    sent = 0
    for n in recipients:
        rec = accounts[n]
        to = Web3.to_checksum_address(rec["address"])
        u = float(rec.get("alloc_usdc", 0))
        hh = float(rec.get("alloc_hype", 0))
        if u > 0:
            tx = usdc.functions.transfer(to, usdc_units(u)).build_transaction({
                "from": funder.address, "nonce": nonce, "gas": ERC20_GAS,
                "gasPrice": gas_price, "chainId": chain_id,
            })
            txh = _send(w3, funder, tx)
            console.print(f"  USDC {u:>7.2f} -> {n:<12} {to}  {txh}")
            _audit(args.audit_log, {"ts": _now(), "kind": "usdc", "name": n, "to": to,
                                    "amount": u, "amount_raw": usdc_units(u), "nonce": nonce,
                                    "tx": txh, "status": "ok"})
            nonce += 1; sent += 1
        if hh > 0:
            tx = {"from": funder.address, "to": to, "value": w3.to_wei(hh, "ether"),
                  "nonce": nonce, "gas": NATIVE_GAS, "gasPrice": gas_price, "chainId": chain_id}
            txh = _send(w3, funder, tx)
            console.print(f"  HYPE {hh:>7.2f} -> {n:<12} {to}  {txh}")
            _audit(args.audit_log, {"ts": _now(), "kind": "hype", "name": n, "to": to,
                                    "amount": hh, "amount_raw": w3.to_wei(hh, "ether"),
                                    "nonce": nonce, "tx": txh, "status": "ok"})
            nonce += 1; sent += 1
    console.print(f"[green]done: {sent} transfers; audit trail -> {args.audit_log}[/green]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

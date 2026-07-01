#!/usr/bin/env python3
"""Generate the throwaway keyfile for the live-spike battle-test.

Derives the FULL self-contained account set from a single freshly-generated
BIP-39 mnemonic, so ONE secret reproduces every key (a lost keyfile is
recoverable as long as the phrase survives) and there is exactly one secret to
guard:

  - funder        — the ONE wallet the human funds; also the deployer + timelock
                    proposer/executor. disperse.py fans funds from it to the rest.
  - operator      — trades + runs the keeper.
  - emergency     — pause / shutdown / repatriate.
  - feeRecipient  — receives mgmt/perf fees (key-controlled so fees are recoverable).
  - lp1..lp10     — the ten depositors.
  - trigger       — unprivileged caller for the permissionless surface.

For PRODUCTION these become distinct hardware/multisig keys (deferred: SOLU-3374).
The all-throwaway-in-one-keyfile model is for the spike only.

Safety:
  - connects to NOTHING and moves NO funds (offline key generation only),
  - writes the keyfile with mode 0600, refuses to overwrite (use --force),
  - prints ADDRESSES + allocations ONLY to stdout (never keys / the mnemonic),
  - the keyfile path is gitignored (scripts/python/.battle_keys*.json).

Each account record carries its disperse allocation (alloc_usdc / alloc_hype),
so the keyfile is the self-documenting source of truth for the funding plan and
the audit trail.

Usage:
    python3 scripts/python/gen_battle_keys.py [--out scripts/python/.battle_keys.json] [--force]
"""
from __future__ import annotations

import argparse
import json
import os
import stat
import subprocess
import time
from pathlib import Path

from eth_account import Account
from rich.console import Console
from rich.table import Table

from accounts import (ALL_NAMES, DEFAULT_KEYFILE, DERIVATION_INDEX, FUND_TOTALS,
                      HYPE_ALLOC, LP_TIERS, USDC_ALLOC)

FUNDER = "funder"


def _git_tracked(path: Path) -> bool:
    try:
        r = subprocess.run(["git", "ls-files", "--error-unmatch", str(path)],
                           capture_output=True, text=True)
        return r.returncode == 0
    except Exception:  # noqa: BLE001
        return False


def generate(out_path: str, network: str, force: bool) -> None:
    console = Console()
    out = Path(out_path)
    if out.exists() and not force:
        raise SystemExit(f"refusing to overwrite existing keyfile {out} (use --force)")
    if _git_tracked(out):
        raise SystemExit(
            f"{out} is tracked by git — add it to .gitignore before generating keys")

    Account.enable_unaudited_hdwallet_features()
    base_acct, mnemonic = Account.create_with_mnemonic(num_words=12)
    del base_acct

    accounts: dict[str, dict] = {}
    for name in ALL_NAMES:
        idx = DERIVATION_INDEX[name]
        acct = Account.from_mnemonic(mnemonic, account_path=f"m/44'/60'/0'/0/{idx}")
        key_hex = acct.key.hex()
        accounts[name] = {
            "address": acct.address,
            "key": key_hex if key_hex.startswith("0x") else "0x" + key_hex,
            "role": "lp" if name.startswith("lp") else name,
            "tier_usdc": float(LP_TIERS.get(name, 0.0)),
            "alloc_usdc": float(USDC_ALLOC.get(name, 0.0)),
            "alloc_hype": float(HYPE_ALLOC.get(name, 0.0)),
        }

    payload = {
        "network": network,
        "generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "mnemonic": mnemonic,
        "funder": FUNDER,
        "fund_totals": FUND_TOTALS,
        "accounts": accounts,
    }
    out.write_text(json.dumps(payload, indent=2) + "\n")
    os.chmod(out, stat.S_IRUSR | stat.S_IWUSR)  # 0600

    table = Table(title=f"battle-test accounts (addresses only) — {out}")
    for col in ("name", "role", "address", "alloc USDC", "alloc HYPE"):
        table.add_column(col, justify="right" if "alloc" in col else "left")
    for name, rec in accounts.items():
        marker = "  <= FUND THIS" if name == FUNDER else ""
        table.add_row(name, rec["role"], rec["address"] + marker,
                      f"{rec['alloc_usdc']:.2f}", f"{rec['alloc_hype']:.2f}")
    console.print(table)

    funder_addr = accounts[FUNDER]["address"]
    console.print(
        f"\n[bold]FUND THE FUNDER[/bold] [cyan]{funder_addr}[/cyan] on HyperEVM (chainId 999):\n"
        f"  - [bold]{FUND_TOTALS['usdc']:.0f} USDC[/bold] (the vault's USDC, "
        "ERC20 0xb88339CB7199b77E23DB6E890353E22632Ba630f, 6 decimals)\n"
        f"  - [bold]{FUND_TOTALS['hype']:.1f} HYPE[/bold] (native gas)"
    )
    console.print(f"[green]wrote {out} (mode 0600). Guard the mnemonic — it reproduces ALL keys.[/green]")
    console.print("[yellow]Next: fund the funder above, then "
                  "`python3 scripts/python/disperse.py` (dry-run) and `--execute` to fan out.[/yellow]")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Generate the gitignored battle-test keyfile (offline).")
    p.add_argument("--out", default=DEFAULT_KEYFILE, help="keyfile output path")
    p.add_argument("--network", default="mainnet", choices=["mainnet", "testnet"])
    p.add_argument("--force", action="store_true", help="overwrite an existing keyfile")
    args = p.parse_args(argv)
    generate(args.out, args.network, args.force)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

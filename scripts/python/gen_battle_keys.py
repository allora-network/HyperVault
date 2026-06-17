#!/usr/bin/env python3
"""Generate the throwaway keyfile for the 10-account battle-test.

Derives 11 throwaway accounts (lp1..lp10 + an unprivileged "trigger") from a
single freshly-generated BIP-39 mnemonic, so ONE secret reproduces every account
(a lost keyfile is recoverable as long as the phrase survives) and there is
exactly one secret to guard. operator/emergency/feeRecipient are NOT generated
here — those are human-supplied, key-controlled EOAs.

Safety:
  - connects to NOTHING and moves NO funds (offline key generation only),
  - writes the keyfile with mode 0600, refuses to overwrite (use --force),
  - prints ADDRESSES ONLY to stdout (never private keys / the mnemonic),
  - the keyfile path is gitignored (scripts/python/.battle_keys*.json).

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

from accounts import DEFAULT_KEYFILE, LP_TIERS

# lp1..lp10 -> HD indices 1..10, trigger -> 11. Index 0 is intentionally unused.
_DERIVATION_INDEX = {name: i + 1 for i, name in enumerate(
    [n for n in LP_TIERS if n.startswith("lp")]
)}
_DERIVATION_INDEX["trigger"] = 11


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
    for name, idx in _DERIVATION_INDEX.items():
        acct = Account.from_mnemonic(mnemonic, account_path=f"m/44'/60'/0'/0/{idx}")
        accounts[name] = {
            "address": acct.address,
            "key": acct.key.hex() if acct.key.hex().startswith("0x") else "0x" + acct.key.hex(),
            "tier_usdc": float(LP_TIERS.get(name, 0.0)),
        }

    payload = {
        "network": network,
        "generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "mnemonic": mnemonic,
        "accounts": accounts,
    }
    out.write_text(json.dumps(payload, indent=2) + "\n")
    os.chmod(out, stat.S_IRUSR | stat.S_IWUSR)  # 0600

    table = Table(title=f"battle-test accounts (addresses only) — {out}")
    table.add_column("name"); table.add_column("address"); table.add_column("tier USDC", justify="right")
    total = 0.0
    for name, rec in accounts.items():
        table.add_row(name, rec["address"], f"{rec['tier_usdc']:.0f}")
        total += rec["tier_usdc"]
    console.print(table)
    console.print(f"[bold]total LP USDC to fund: {total:.0f}[/bold] (plus operator seed + "
                  "1.0 USDC first-push activation + HYPE gas — see plan_funding.py)")
    console.print(f"[green]wrote {out} (mode 0600). Guard the mnemonic — it reproduces all keys.[/green]")
    console.print("[yellow]Next: fund these addresses (plan_funding.py emits the commands).[/yellow]")


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

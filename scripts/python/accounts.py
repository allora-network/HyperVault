#!/usr/bin/env python3
"""Multi-account layer for the HyperVault 10-account battle-test.

The proven single-lifecycle harness (`e2e_runner.py`) hardcodes exactly two
actors (operator + alice). The battle-test needs ten throwaway LPs plus an
unprivileged "trigger" caller, so this module provides:

  - the throwaway keyfile contract (written by `gen_battle_keys.py`, read here),
  - `BattleCtx`, a read-only-by-default context carrying the account registry,
  - `build_battle_ctx(args)`, which wires web3 + the vault/USDC contracts + the
    accounts together.

It deliberately REUSES `e2e_runner`'s stateless low-level helpers (`send_tx`,
`parse_event`, `wait_for`, `load_abi`, `usdc_units`, `WALLET_ABI`,
`core_deposit_wallet`) rather than touching that file's `Ctx`/steps — keeping the
battle-test additive and the audited harness stable.

Run from the repo root so `out/` and the sibling imports resolve.
"""
from __future__ import annotations

import argparse
import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

from eth_account import Account
from rich.console import Console
from web3 import Web3

import hl_helpers as hl
from e2e_runner import load_abi


# The canonical 10-LP + trigger tier map (USDC). Mirrors the coverage matrix:
# small (5) / medium (15) / large (40). LP totals = 220 USDC. The "trigger"
# account is the unprivileged caller for the permissionless surface (it needs
# only gas, no USDC). operator/emergency/feeRecipient are human-supplied EOAs,
# NOT in the throwaway keyfile.
LP_TIERS: dict[str, float] = {
    "lp1": 5.0,
    "lp2": 15.0,
    "lp3": 40.0,
    "lp4": 40.0,
    "lp5": 15.0,
    "lp6": 5.0,
    "lp7": 15.0,
    "lp8": 5.0,
    "lp9": 40.0,
    "lp10": 40.0,
    "trigger": 0.0,
}

LP_NAMES: list[str] = [n for n in LP_TIERS if n.startswith("lp")]

DEFAULT_KEYFILE = "scripts/python/.battle_keys.json"

# Minimal ERC20 ABI for USDC (read + the moves the battle-test/wind-down need).
ERC20_ABI = [
    {"type": "function", "name": "balanceOf", "stateMutability": "view",
     "inputs": [{"name": "a", "type": "address"}], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "approve", "stateMutability": "nonpayable",
     "inputs": [{"name": "s", "type": "address"}, {"name": "v", "type": "uint256"}],
     "outputs": [{"type": "bool"}]},
    {"type": "function", "name": "allowance", "stateMutability": "view",
     "inputs": [{"name": "o", "type": "address"}, {"name": "s", "type": "address"}],
     "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "decimals", "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "uint8"}]},
    {"type": "function", "name": "transfer", "stateMutability": "nonpayable",
     "inputs": [{"name": "to", "type": "address"}, {"name": "v", "type": "uint256"}],
     "outputs": [{"type": "bool"}]},
]


def normalize_key(key: str) -> str:
    """eth_account wants a 0x-prefixed hex key; .env keys sometimes lack it."""
    key = key.strip()
    return key if key.startswith("0x") else "0x" + key


def load_accounts(path: str = DEFAULT_KEYFILE) -> dict[str, dict]:
    """Load the throwaway keyfile -> {name: {"account", "address", "tier_usdc"}}.

    Names are lp1..lp10 and "trigger". Raises a clear error if the file is
    missing (run gen_battle_keys.py first)."""
    p = Path(path)
    if not p.exists():
        raise SystemExit(
            f"keyfile not found: {path}\n"
            "Run: python3 scripts/python/gen_battle_keys.py  (writes the gitignored keyfile)"
        )
    data = json.loads(p.read_text())
    out: dict[str, dict] = {}
    for name, rec in data.get("accounts", {}).items():
        acct = Account.from_key(normalize_key(rec["key"]))
        out[name] = {
            "account": acct,
            "address": Web3.to_checksum_address(rec.get("address", acct.address)),
            "tier_usdc": float(rec.get("tier_usdc", LP_TIERS.get(name, 0.0))),
        }
    return out


def _env_account(*env_names: str) -> Optional[Account]:
    """First present env var (a private key) -> Account, else None (read-only ok)."""
    for n in env_names:
        v = os.environ.get(n)
        if v:
            return Account.from_key(normalize_key(v))
    return None


@dataclass
class BattleCtx:
    w3: Web3
    info: Any                       # hyperliquid.info.Info (None if HL unreachable)
    vault: Any                      # web3 contract (HyperCoreVault)
    usdc: Any                       # web3 contract (ERC20)
    vault_addr: str
    usdc_addr: str
    asset_idx: int
    asset_meta: Any                 # hl_helpers.PerpAssetMeta (None if HL unreachable)
    accounts: dict[str, Account]    # lp1..lp10, trigger
    tiers: dict[str, float]
    operator: Optional[Account]     # human-supplied (OPERATOR_PRIVATE_KEY)
    emergency: Optional[Account]    # human-supplied (EMERGENCY_PRIVATE_KEY)
    network: str
    execute: bool                   # DRY-RUN-first: False => no tx is ever sent
    console: Console = field(default_factory=Console)
    fee_recipient: Optional[str] = None
    core_usdc_index: int = 0        # Core spot token index for USDC (NOT the perp asset_idx)

    def actor(self, name: str) -> Account:
        """Resolve an actor name to an Account. 'operator'/'emergency' come from
        env; lp*/'trigger' from the keyfile. Raises RuntimeError (not SystemExit)
        so a missing key fails only the current scenario, not the whole batch."""
        if name == "operator":
            if self.operator is None:
                raise RuntimeError("operator account unavailable (set OPERATOR_PRIVATE_KEY)")
            return self.operator
        if name == "emergency":
            if self.emergency is None:
                raise RuntimeError("emergency account unavailable (set EMERGENCY_PRIVATE_KEY)")
            return self.emergency
        if name not in self.accounts:
            raise RuntimeError(f"unknown actor: {name}")
        return self.accounts[name]


def add_common_args(p: argparse.ArgumentParser) -> None:
    """Args shared by every battle-test entrypoint (battle_test/journal/...)."""
    p.add_argument("--artifact", default=os.environ.get("ARTIFACT"),
                   help="deployment artifact JSON (or $ARTIFACT)")
    p.add_argument("--rpc-url", default=None, help="HyperEVM RPC (default $HYPEREVM_RPC_MAINNET)")
    p.add_argument("--network", default="mainnet", choices=["mainnet", "testnet"])
    p.add_argument("--asset", type=int, default=0, help="perp asset index (default 0 = BTC)")
    p.add_argument("--keys", default=DEFAULT_KEYFILE, help="throwaway keyfile path")


def build_battle_ctx(args: argparse.Namespace) -> BattleCtx:
    if not getattr(args, "artifact", None):
        raise SystemExit("error: --artifact or $ARTIFACT is required")
    artifact = json.loads(Path(args.artifact).read_text())
    vault_addr = Web3.to_checksum_address(artifact["vault"])
    usdc_addr = Web3.to_checksum_address(artifact["asset"])

    rpc = getattr(args, "rpc_url", None) or os.environ["HYPEREVM_RPC_MAINNET"]
    w3 = Web3(Web3.HTTPProvider(rpc))
    assert w3.is_connected(), f"RPC not reachable: {rpc}"

    vault = w3.eth.contract(address=vault_addr, abi=load_abi("HyperCoreVault"))
    usdc = w3.eth.contract(address=usdc_addr, abi=ERC20_ABI)

    loaded = load_accounts(getattr(args, "keys", DEFAULT_KEYFILE))
    accounts = {name: rec["account"] for name, rec in loaded.items()}
    tiers = {name: rec["tier_usdc"] for name, rec in loaded.items()}

    # HL info is best-effort (read-only NAV cross-checks + perp meta for trading).
    info = None
    asset_meta = None
    try:
        info = hl.make_info(args.network)
        asset_meta = hl.get_perp_meta(info, args.asset)
    except Exception:  # noqa: BLE001 — keep the kit usable when HL API is unreachable
        pass

    fee_recipient = None
    try:
        fee_recipient = vault.functions.feeRecipient().call()
    except Exception:  # noqa: BLE001
        pass

    core_usdc_index = 0
    try:
        core_usdc_index = int(vault.functions.coreUsdcIndex().call())
    except Exception:  # noqa: BLE001 — USDC is index 0 on HyperCore mainnet
        pass

    return BattleCtx(
        w3=w3, info=info, vault=vault, usdc=usdc,
        vault_addr=vault_addr, usdc_addr=usdc_addr,
        asset_idx=args.asset, asset_meta=asset_meta,
        accounts=accounts, tiers=tiers,
        operator=_env_account("OPERATOR_PRIVATE_KEY"),
        emergency=_env_account("EMERGENCY_PRIVATE_KEY", "EMERGENCY_ADMIN_PRIVATE_KEY"),
        network=args.network, execute=bool(getattr(args, "execute", False)),
        fee_recipient=fee_recipient, core_usdc_index=core_usdc_index,
    )

#!/usr/bin/env python3
"""Build + (optionally) drive the per-vault TimelockController admin batch.

WHY THIS EXISTS
---------------
The spike vault's DEFAULT_ADMIN_ROLE is a per-vault `TimelockController` (its
address is the `timelock` field in the deploy artifact). EVERY admin config change
— perp/spot whitelist, the redemption SLA window, the escape grace, the soft
barriers, the fees — must therefore go through the timelock two-step:

    scheduleBatch(...)  ->  wait getMinDelay() seconds  ->  executeBatch(...)

with the same operation identity Deploy.s.sol uses: `predecessor = bytes32(0)`,
`salt = keccak256(abi.encode(label, chainId, vault))`, and `delay = getMinDelay()`.
This mirrors `_seedWhitelistViaTimelock` so a scheduled-then-executed batch hashes
identically and can't collide with the deploy seed.

BROADCASTING IS A HUMAN GATE. The default mode is DRY-RUN: it prints the exact
targets/values/payloads, the operation id, and the `cast send` equivalent, plus
the "wait <delay>s then re-run with --execute" note. It sends a transaction ONLY
when `--execute-onchain` is passed AND a DEPLOYER_PRIVATE_KEY is present in the
environment. No key, no broadcast — by construction.

ABI-encoding note: web3 v6 exposes `contract.encodeABI(fn_name=..., args=...)`;
web3 v7 renamed it to `contract.encode_abi(abi_element_identifier=..., args=...)`.
We try both so this works across the pinned range.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Optional

from eth_account import Account
from rich.console import Console
from rich.table import Table
from web3 import Web3

# Reuse the runner's loader so the vault ABI is read identically.
from e2e_runner import load_abi


# Minimal TimelockController ABI — the surface this tool drives/reads.
TIMELOCK_ABI = [
    {"type": "function", "name": "getMinDelay", "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "scheduleBatch", "stateMutability": "nonpayable",
     "inputs": [
         {"name": "targets", "type": "address[]"},
         {"name": "values", "type": "uint256[]"},
         {"name": "payloads", "type": "bytes[]"},
         {"name": "predecessor", "type": "bytes32"},
         {"name": "salt", "type": "bytes32"},
         {"name": "delay", "type": "uint256"},
     ], "outputs": []},
    {"type": "function", "name": "executeBatch", "stateMutability": "payable",
     "inputs": [
         {"name": "targets", "type": "address[]"},
         {"name": "values", "type": "uint256[]"},
         {"name": "payloads", "type": "bytes[]"},
         {"name": "predecessor", "type": "bytes32"},
         {"name": "salt", "type": "bytes32"},
     ], "outputs": []},
    {"type": "function", "name": "hashOperationBatch", "stateMutability": "pure",
     "inputs": [
         {"name": "targets", "type": "address[]"},
         {"name": "values", "type": "uint256[]"},
         {"name": "payloads", "type": "bytes[]"},
         {"name": "predecessor", "type": "bytes32"},
         {"name": "salt", "type": "bytes32"},
     ], "outputs": [{"type": "bytes32"}]},
    {"type": "function", "name": "isOperationReady", "stateMutability": "view",
     "inputs": [{"name": "id", "type": "bytes32"}], "outputs": [{"type": "bool"}]},
    {"type": "function", "name": "isOperationDone", "stateMutability": "view",
     "inputs": [{"name": "id", "type": "bytes32"}], "outputs": [{"type": "bool"}]},
]


@dataclass
class Action:
    """One vault admin call: (method name, positional args). Encoded against the
    vault ABI; the timelock executes it as a batch entry (target = vault, value 0)."""
    method: str
    args: tuple

    def describe(self) -> str:
        return f"{self.method}{self.args}"


# -----------------------------------------------------------------------------
# Named presets — the admin levers a battle-test actually flips.
# -----------------------------------------------------------------------------

def whitelist_perp(asset: int, enabled: bool = True) -> Action:
    """Allow (or disallow) the operator to trade a perp asset id."""
    return Action("setWhitelistPerp", (int(asset), bool(enabled)))


def whitelist_spot(asset: int, enabled: bool = True) -> Action:
    """Allow (or disallow) the operator to trade a spot asset id."""
    return Action("setWhitelistSpot", (int(asset), bool(enabled)))


def set_sla(seconds: int) -> Action:
    """Set the request-fulfillment window (the redemption SLA deadline)."""
    return Action("setRequestFulfillmentWindow", (int(seconds),))


def set_escape_grace(seconds: int) -> Action:
    """Set the permissionless escape-brake grace period (hard bounds [4h, 30d])."""
    return Action("setEscapeGraceSeconds", (int(seconds),))


def set_barriers(lockup: int, cooldown: int, gate_bps: int) -> Action:
    """Set the soft redemption barriers (lockup / cooldown / per-tx gate bps).
    All default 0 = OFF; barriers gate only the synchronous withdraw/redeem path."""
    return Action("setRedemptionBarriers", (int(lockup), int(cooldown), int(gate_bps)))


def set_fees(mgmt_bps: int, perf_bps: int) -> Action:
    """Set the management (<=2000 bps/yr) and performance (<=5000 bps) fees."""
    return Action("setFees", (int(mgmt_bps), int(perf_bps)))


# -----------------------------------------------------------------------------
# --actions string parsing (e.g. "sla=300,grace=14400,barriers=0:0:0,fees=0:0")
# -----------------------------------------------------------------------------

def parse_actions(spec: str) -> list[Action]:
    """Parse a comma-separated --actions string into Action objects.

    Grammar (each comma-separated token is `key=value`):
      perp=<id>[:0|1]        -> whitelist_perp
      spot=<id>[:0|1]        -> whitelist_spot
      sla=<seconds>          -> set_sla
      grace=<seconds>        -> set_escape_grace
      barriers=<lockup>:<cooldown>:<gateBps>
      fees=<mgmtBps>:<perfBps>
    """
    actions: list[Action] = []
    for raw in spec.split(","):
        token = raw.strip()
        if not token:
            continue
        if "=" not in token:
            raise ValueError(f"bad action token {token!r} (expected key=value)")
        key, value = token.split("=", 1)
        key = key.strip().lower()
        value = value.strip()
        if key == "perp":
            parts = value.split(":")
            enabled = (parts[1] != "0") if len(parts) > 1 else True
            actions.append(whitelist_perp(int(parts[0]), enabled))
        elif key == "spot":
            parts = value.split(":")
            enabled = (parts[1] != "0") if len(parts) > 1 else True
            actions.append(whitelist_spot(int(parts[0]), enabled))
        elif key == "sla":
            actions.append(set_sla(int(value)))
        elif key == "grace":
            actions.append(set_escape_grace(int(value)))
        elif key == "barriers":
            lockup, cooldown, gate = (value.split(":") + ["0", "0", "0"])[:3]
            actions.append(set_barriers(int(lockup), int(cooldown), int(gate)))
        elif key == "fees":
            mgmt, perf = (value.split(":") + ["0", "0"])[:2]
            actions.append(set_fees(int(mgmt), int(perf)))
        else:
            raise ValueError(f"unknown action key {key!r}")
    return actions


# -----------------------------------------------------------------------------
# Encoding + batch assembly
# -----------------------------------------------------------------------------

def _encode_call(vault, action: Action) -> bytes:
    """ABI-encode one vault call, tolerating web3 v6 (encodeABI) and v7 (encode_abi)."""
    # web3 v6: contract.encodeABI(fn_name=..., args=[...])
    if hasattr(vault, "encodeABI"):
        try:
            data = vault.encodeABI(fn_name=action.method, args=list(action.args))
            return bytes.fromhex(data[2:] if data.startswith("0x") else data)
        except TypeError:
            pass
    # web3 v7: contract.encode_abi(abi_element_identifier=..., args=[...])
    if hasattr(vault, "encode_abi"):
        try:
            data = vault.encode_abi(abi_element_identifier=action.method, args=list(action.args))
        except TypeError:
            # Some v7 builds accept positional identifier or the legacy fn_name kwarg.
            try:
                data = vault.encode_abi(action.method, args=list(action.args))
            except TypeError:
                data = vault.encode_abi(fn_name=action.method, args=list(action.args))
        return bytes.fromhex(data[2:] if data.startswith("0x") else data)
    raise RuntimeError("vault contract exposes neither encodeABI nor encode_abi")


def build_batch(vault, actions: list[Action], *, label: str, chain_id: int,
                vault_addr: str) -> dict:
    """Assemble the TimelockController batch tuple for `actions`.

    Returns {targets, values, payloads, predecessor, salt}. The salt mirrors
    Deploy.s.sol: keccak256(abi.encode(label, chainId, vault)) — a fixed label
    means a re-built batch is idempotent (same operation id), so re-running
    --schedule for the same config won't create a duplicate pending op.
    """
    targets = [Web3.to_checksum_address(vault_addr) for _ in actions]
    values = [0 for _ in actions]
    payloads = [_encode_call(vault, a) for a in actions]
    predecessor = b"\x00" * 32
    # abi.encode(string,uint256,address) — matches Solidity abi.encode in Deploy.s.sol.
    salt = Web3.keccak(
        Web3.to_bytes(hexstr=_abi_encode_salt(label, chain_id, vault_addr))
    )
    return {
        "targets": targets,
        "values": values,
        "payloads": payloads,
        "predecessor": predecessor,
        "salt": salt,
    }


def _abi_encode_salt(label: str, chain_id: int, vault_addr: str) -> str:
    """ABI-encode (string label, uint256 chainId, address vault) -> 0x-hex.

    Uses eth_abi so the salt byte-for-byte matches Solidity's
    `abi.encode("label", block.chainid, vault)`.
    """
    from eth_abi import encode as abi_encode
    packed = abi_encode(
        ["string", "uint256", "address"],
        [label, int(chain_id), Web3.to_checksum_address(vault_addr)],
    )
    return "0x" + packed.hex()


# -----------------------------------------------------------------------------
# Minimal ctx shim for reusing e2e_runner.send_tx (it only touches .w3)
# -----------------------------------------------------------------------------

@dataclass
class _TxShim:
    """Just enough of e2e_runner.Ctx for send_tx: it reads ctx.w3 only."""
    w3: Any


def _send(w3, account: Account, fn, *, gas: int = 1_200_000) -> Any:
    """Broadcast a tx via e2e_runner.send_tx using a minimal ctx shim."""
    from e2e_runner import send_tx
    return send_tx(_TxShim(w3=w3), account, fn, gas=gas)


# -----------------------------------------------------------------------------
# Pretty printing
# -----------------------------------------------------------------------------

def _print_batch(console: Console, actions: list[Action], batch: dict,
                 timelock_addr: str, min_delay: int, op_id: Optional[bytes]) -> None:
    """Print the batch contents, operation id, and the cast-send equivalents."""
    tbl = Table(show_header=True, header_style="bold", title="timelock admin batch")
    tbl.add_column("#", justify="right")
    tbl.add_column("vault method")
    tbl.add_column("args")
    tbl.add_column("payload (0x..)")
    for i, action in enumerate(actions):
        payload_hex = "0x" + batch["payloads"][i].hex()
        short = payload_hex if len(payload_hex) <= 26 else payload_hex[:24] + "…"
        tbl.add_row(str(i), action.method, str(action.args), short)
    console.print(tbl)

    salt_hex = "0x" + batch["salt"].hex()
    console.print(f"timelock:    {timelock_addr}")
    console.print(f"getMinDelay: {min_delay}s")
    console.print(f"predecessor: 0x{batch['predecessor'].hex()}")
    console.print(f"salt:        {salt_hex}")
    if op_id is not None:
        console.print(f"operationId: 0x{op_id.hex()}")

    # cast-send equivalents (the human-runnable form). Arrays are bracketed.
    targets_arr = "[" + ",".join(batch["targets"]) + "]"
    values_arr = "[" + ",".join(str(v) for v in batch["values"]) + "]"
    payloads_arr = "[" + ",".join("0x" + p.hex() for p in batch["payloads"]) + "]"
    console.print("\n[bold]cast send equivalents (HUMAN GATE — broadcasting is manual):[/bold]")
    console.print(
        f"[dim]# 1) schedule[/dim]\n"
        f"cast send {timelock_addr} \\\n"
        f"  'scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)' \\\n"
        f"  '{targets_arr}' '{values_arr}' '{payloads_arr}' \\\n"
        f"  0x{batch['predecessor'].hex()} {salt_hex} {min_delay} \\\n"
        f"  --rpc-url $HYPEREVM_RPC_MAINNET --private-key $DEPLOYER_PRIVATE_KEY"
    )
    console.print(
        f"[dim]# 2) wait {min_delay}s, then execute[/dim]\n"
        f"cast send {timelock_addr} \\\n"
        f"  'executeBatch(address[],uint256[],bytes[],bytes32,bytes32)' \\\n"
        f"  '{targets_arr}' '{values_arr}' '{payloads_arr}' \\\n"
        f"  0x{batch['predecessor'].hex()} {salt_hex} \\\n"
        f"  --rpc-url $HYPEREVM_RPC_MAINNET --private-key $DEPLOYER_PRIVATE_KEY"
    )


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Build/drive the per-vault TimelockController admin batch "
                    "(DRY-RUN by default; broadcasting is a HUMAN GATE).")
    parser.add_argument("--artifact", default=os.environ.get("ARTIFACT"),
                        help="path to deployments/<chain>/<strategy>.json")
    parser.add_argument("--rpc-url", default=os.environ.get("HYPEREVM_RPC_MAINNET"))
    parser.add_argument("--actions", required=True,
                        help="comma list, e.g. 'sla=300,grace=14400,barriers=0:0:0,fees=0:0,perp=0'")
    parser.add_argument("--label", default="battle-admin",
                        help="salt label (keccak256(abi.encode(label,chainId,vault)))")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--schedule", action="store_true",
                      help="target the scheduleBatch leg (default if neither given)")
    mode.add_argument("--execute", action="store_true",
                      help="target the executeBatch leg")
    parser.add_argument("--execute-onchain", action="store_true",
                        help="ACTUALLY broadcast (requires DEPLOYER_PRIVATE_KEY in env). "
                             "Default sends NOTHING — broadcasting is a HUMAN GATE.")
    parser.add_argument("--wait", action="store_true",
                        help="with --schedule --execute-onchain: sleep getMinDelay() then execute")
    args = parser.parse_args(argv)

    if not args.artifact:
        print("--artifact (or $ARTIFACT) required", file=sys.stderr)
        return 2

    console = Console()
    artifact = json.loads(Path(args.artifact).read_text())
    vault_addr = Web3.to_checksum_address(artifact["vault"])
    timelock_addr = Web3.to_checksum_address(artifact["timelock"])

    rpc = args.rpc_url or os.environ.get("HYPEREVM_RPC_MAINNET")
    if not rpc:
        print("--rpc-url (or $HYPEREVM_RPC_MAINNET) required", file=sys.stderr)
        return 2
    w3 = Web3(Web3.HTTPProvider(rpc))
    if not w3.is_connected():
        print(f"RPC not reachable: {rpc}", file=sys.stderr)
        return 2

    vault = w3.eth.contract(address=vault_addr, abi=load_abi("HyperCoreVault"))
    timelock = w3.eth.contract(address=timelock_addr, abi=TIMELOCK_ABI)

    chain_id = w3.eth.chain_id
    actions = parse_actions(args.actions)
    if not actions:
        console.print("[yellow]no actions parsed — nothing to do[/yellow]")
        return 0

    batch = build_batch(vault, actions, label=args.label, chain_id=chain_id, vault_addr=vault_addr)
    min_delay = timelock.functions.getMinDelay().call()

    # Compute the operation id (on-chain hashOperationBatch keeps it canonical).
    op_id: Optional[bytes] = None
    try:
        op_id = timelock.functions.hashOperationBatch(
            batch["targets"], batch["values"], batch["payloads"],
            batch["predecessor"], batch["salt"],
        ).call()
    except Exception:
        op_id = None

    _print_batch(console, actions, batch, timelock_addr, min_delay, op_id)

    # Operation status (read-only) when we could compute the id.
    if op_id is not None:
        ready = _safe_call(lambda: timelock.functions.isOperationReady(op_id).call())
        done = _safe_call(lambda: timelock.functions.isOperationDone(op_id).call())
        console.print(f"isOperationReady: {ready}   isOperationDone: {done}")

    # Default leg is schedule unless --execute was passed.
    do_execute_leg = args.execute and not args.schedule

    if not args.execute_onchain:
        leg = "executeBatch" if do_execute_leg else "scheduleBatch"
        console.print(
            f"\n[cyan]DRY-RUN — nothing broadcast.[/cyan] Intended leg: [bold]{leg}[/bold]. "
            f"Re-run with [bold]--execute-onchain[/bold] AND $DEPLOYER_PRIVATE_KEY set to send."
        )
        if not do_execute_leg:
            console.print(f"[yellow]After scheduling, wait {min_delay}s then re-run with "
                          f"--execute --execute-onchain.[/yellow]")
        return 0

    # ---- LIVE path (human-gated): requires DEPLOYER_PRIVATE_KEY ----
    pk = os.environ.get("DEPLOYER_PRIVATE_KEY")
    if not pk:
        console.print("[red]--execute-onchain requires DEPLOYER_PRIVATE_KEY in env — refusing to send[/red]")
        return 2
    account = Account.from_key(pk if pk.startswith("0x") else "0x" + pk)

    if not do_execute_leg:
        console.print("[bold]scheduling batch on-chain...[/bold]")
        rcpt = _send(w3, account, timelock.functions.scheduleBatch(
            batch["targets"], batch["values"], batch["payloads"],
            batch["predecessor"], batch["salt"], min_delay))
        console.print(f"scheduleBatch tx status {rcpt.status}")
        if args.wait and min_delay > 0:
            console.print(f"[yellow]waiting {min_delay}s for the timelock delay...[/yellow]")
            time.sleep(min_delay + 2)
            do_execute_leg = True  # fall through to execute below

    if do_execute_leg:
        console.print("[bold]executing batch on-chain...[/bold]")
        rcpt = _send(w3, account, timelock.functions.executeBatch(
            batch["targets"], batch["values"], batch["payloads"],
            batch["predecessor"], batch["salt"]))
        console.print(f"executeBatch tx status {rcpt.status}")

    return 0


def _safe_call(fn: Callable[[], Any]) -> Any:
    """Best-effort read; returns None on any error (read-only status helpers)."""
    try:
        return fn()
    except Exception:
        return None


if __name__ == "__main__":
    raise SystemExit(main())

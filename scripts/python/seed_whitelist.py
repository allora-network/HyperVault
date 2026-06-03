#!/usr/bin/env python3
"""Schedule + execute whitelist seeding through a TimelockController.

On deploy, the script handles this automatically when `timelockMinDelaySec == 0`.
Use this script for any later additions, or for production deploys after the
delay window has passed.

Usage:
    ARTIFACT=deployments/mainnet/<strategy>.json \\
    DEPLOYER_PRIVATE_KEY=0x... \\
    PERPS_TO_ADD=1,5,12 \\
    SPOTS_TO_ADD= \\
    python seed_whitelist.py [--execute-only]
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from eth_account import Account
from web3 import Web3


TIMELOCK_ABI = [
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
    {"type": "function", "name": "getMinDelay", "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "uint256"}]},
]


def main() -> int:
    artifact_path = os.environ.get("ARTIFACT")
    if not artifact_path:
        print("ARTIFACT env var required", file=sys.stderr)
        return 2
    artifact = json.loads(Path(artifact_path).read_text())

    rpc = os.environ["HYPEREVM_RPC_MAINNET"]
    w3 = Web3(Web3.HTTPProvider(rpc))

    vault_addr = Web3.to_checksum_address(artifact["vault"])
    timelock_addr = Web3.to_checksum_address(artifact["timelock"])
    deployer = Account.from_key(os.environ["DEPLOYER_PRIVATE_KEY"])

    perps_csv = os.environ.get("PERPS_TO_ADD", "")
    spots_csv = os.environ.get("SPOTS_TO_ADD", "")
    perps = [int(x) for x in perps_csv.split(",") if x.strip()]
    spots = [int(x) for x in spots_csv.split(",") if x.strip()]
    if not perps and not spots:
        print("nothing to do — set PERPS_TO_ADD / SPOTS_TO_ADD")
        return 0

    # Build vault calldata for each setWhitelistPerp / setWhitelistSpot call
    # selector(setWhitelistPerp(uint32,bool)) = first 4 bytes of keccak256("setWhitelistPerp(uint32,bool)")
    def sel(sig: str) -> bytes:
        return Web3.keccak(text=sig)[:4]
    sel_perp = sel("setWhitelistPerp(uint32,bool)")
    sel_spot = sel("setWhitelistSpot(uint32,bool)")

    def encode_call(selector: bytes, asset: int) -> bytes:
        return selector + asset.to_bytes(32, "big") + (1).to_bytes(32, "big")

    targets, values, payloads = [], [], []
    for p in perps:
        targets.append(vault_addr); values.append(0); payloads.append(encode_call(sel_perp, p))
    for s in spots:
        targets.append(vault_addr); values.append(0); payloads.append(encode_call(sel_spot, s))

    predecessor = b"\x00" * 32
    salt = Web3.keccak(text=f"seed-{time.time()}")

    timelock = w3.eth.contract(address=timelock_addr, abi=TIMELOCK_ABI)
    min_delay = timelock.functions.getMinDelay().call()
    print(f"timelock min delay: {min_delay}s")

    nonce = w3.eth.get_transaction_count(deployer.address)
    gas_price = w3.eth.gas_price

    def send(fn, **kw):
        nonlocal nonce
        tx = fn.build_transaction({
            "from": deployer.address, "nonce": nonce, "gas": 800_000,
            "gasPrice": gas_price, "chainId": w3.eth.chain_id, **kw,
        })
        signed = deployer.sign_transaction(tx)
        h = w3.eth.send_raw_transaction(signed.raw_transaction)
        rcpt = w3.eth.wait_for_transaction_receipt(h)
        print(f"  tx {h.hex()} status {rcpt.status}")
        nonce += 1
        return rcpt

    if "--execute-only" not in sys.argv:
        print("scheduling batch...")
        send(timelock.functions.scheduleBatch(targets, values, payloads, predecessor, salt, min_delay))
        if min_delay > 0:
            print(f"waiting {min_delay}s for delay...")
            time.sleep(min_delay + 2)

    print("executing batch...")
    send(timelock.functions.executeBatch(targets, values, payloads, predecessor, salt))
    print("done")
    return 0


if __name__ == "__main__":
    sys.exit(main())

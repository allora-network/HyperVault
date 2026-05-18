#!/usr/bin/env python3
"""Opt a vault address into HyperEVM big blocks via the HL API.

Big blocks (30M gas, 1 minute) are required for the emergency fan-out paths
(`emergencyCancelByCloid` over many assets, `emergencyClosePositions`).

Usage:
    OPERATOR_PRIVATE_KEY=0x... \\
    VAULT_ADDRESS=0x... \\
    NETWORK=testnet \\
    python optin_big_blocks.py

The signer must be an API wallet authorized for the vault address. By default,
the vault deployer's key serves as the initial API wallet — rotate to a
production-controlled wallet before mainnet.
"""
import os
import sys

from eth_account import Account
from hyperliquid.exchange import Exchange
from hyperliquid.utils import constants


def main() -> int:
    key = os.environ["OPERATOR_PRIVATE_KEY"]
    vault = os.environ["VAULT_ADDRESS"]
    network = os.environ.get("NETWORK", "testnet")
    base = constants.TESTNET_API_URL if network == "testnet" else constants.MAINNET_API_URL

    account = Account.from_key(key)
    print(f"Signer: {account.address}")
    print(f"Vault:  {vault}")
    print(f"API:    {base}")

    ex = Exchange(account, base_url=base, vault_address=vault)
    res = ex.update_evm_user_modify(using_big_blocks=True)
    print(f"Result: {res}")
    return 0 if res.get("status") == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Send USDC from your HL Core spot account to the vault's Core address.

Needed on testnet where USDC is not linked as an ERC20 on HyperEVM. To fund
the vault for perp orders, we bypass the EVM-side `pushToCore` and instead
push from our own personal HL Core balance directly to the vault's Core
account (which has the same address as the vault contract on EVM).

Usage:
    VAULT_ADDRESS=0x...                       # target Core account
    OPERATOR_PRIVATE_KEY=0x...                # your personal HL Core key
    USDC_AMOUNT=200                           # human USDC (6dp)
    NETWORK=testnet
    python seed_vault_core.py
"""
import os
import sys

from eth_account import Account
from hyperliquid.exchange import Exchange
from hyperliquid.utils import constants


def main() -> int:
    key = os.environ["OPERATOR_PRIVATE_KEY"]
    vault = os.environ["VAULT_ADDRESS"]
    amount = float(os.environ.get("USDC_AMOUNT", "100"))
    network = os.environ.get("NETWORK", "testnet")
    base = constants.TESTNET_API_URL if network == "testnet" else constants.MAINNET_API_URL

    account = Account.from_key(key)
    print(f"Sender (Core): {account.address}")
    print(f"Recipient:     {vault}")
    print(f"Amount:        {amount} USDC")
    print(f"API:           {base}")

    ex = Exchange(account, base_url=base)
    # USDC on Core is denominated in USD; spot_send takes the human amount as a string.
    res = ex.spot_transfer(amount, vault, "USDC")
    print(f"Result: {res}")
    return 0 if res.get("status") == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())

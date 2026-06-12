#!/usr/bin/env python3
"""Toggle HyperEVM big blocks for an EOA via the HL API.

Big blocks (30M gas, ~1 minute cadence) apply to the SENDER of an EVM tx, not
to a contract: the account that needs them is whichever EOA submits a >2M-gas
transaction. In practice:

  - the DEPLOYER, for `forge script script/Deploy.s.sol` (~9M gas vault deploy);
  - the EMERGENCY key, if an `emergencyCancelByCloid`/`emergencyClosePositions`
    fan-out over many assets ever exceeds the 2M small-block limit.

Toggle OFF after the big tx lands, so follow-on transactions go to the fast
(1s) small blocks instead of waiting on the ~1 minute big-block cadence.

Usage:
    # default: opt the DEPLOYER in (falls back to OPERATOR_PRIVATE_KEY)
    DEPLOYER_PRIVATE_KEY=... NETWORK=mainnet python3 scripts/python/optin_big_blocks.py
    # turn off afterwards
    DEPLOYER_PRIVATE_KEY=... python3 scripts/python/optin_big_blocks.py --off
    # explicit key selection
    BIG_BLOCKS_PRIVATE_KEY=... python3 scripts/python/optin_big_blocks.py

Note (2026-06-03 live-spike gotcha, fixed here): the installed SDK's method is
`Exchange.use_big_blocks(enable)`; the previously-referenced
`update_evm_user_modify(...)` does not exist. The toggle is signed by the EOA
for itself — no vault_address involvement (that SDK kwarg is for HL-native
vaults, unrelated to EVM block selection).
"""
import os
import sys

from eth_account import Account
from hyperliquid.exchange import Exchange
from hyperliquid.utils import constants


def main() -> int:
    enable = "--off" not in sys.argv
    key = (
        os.environ.get("BIG_BLOCKS_PRIVATE_KEY")
        or os.environ.get("DEPLOYER_PRIVATE_KEY")
        or os.environ["OPERATOR_PRIVATE_KEY"]
    )
    if not key.startswith("0x"):
        key = "0x" + key  # forge needs the 0x prefix in .env; eth_account takes both
    network = os.environ.get("NETWORK", "mainnet")
    base = constants.TESTNET_API_URL if network == "testnet" else constants.MAINNET_API_URL

    account = Account.from_key(key)
    print(f"Signer:  {account.address}")
    print(f"API:     {base}")
    print(f"Action:  use_big_blocks({enable})")

    ex = Exchange(account, base_url=base)
    res = ex.use_big_blocks(enable)
    print(f"Result: {res}")
    return 0 if isinstance(res, dict) and res.get("status") == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())

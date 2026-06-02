#!/usr/bin/env python3
"""Finding G resolver — read-only, live-node proof of the EVM<->Core USDC linkage.

WHY THIS EXISTS (and is not a Foundry fork test): the EVM<->Core USDC linkage lives in
the HyperCore `tokenInfo` precompile at 0x...080C. Foundry's revm does NOT implement the
HyperEVM precompiles, so a forge fork reads it as empty (it would falsely report
evmContract == address(0)). A real `eth_call` to the live node DOES execute the precompile.
This script makes that read with zero dependencies (stdlib only) and no keys/funds.

It resolves the contradiction in the repo:
  - src/HyperCoreVault.sol:500-511 natspec + README claim the configured USDC is NOT linked
    to Core USDC (so pullFromCore/coreSpotUsdc are unreliable);
  - scripts/python/e2e_runner.py step_pull asserts the bridge round-trip works.

The decisive on-chain fact: tokenInfo(0).evmContract vs the configured asset.

Run:
    HYPEREVM_RPC_MAINNET=<rpc> python3 scripts/python/resolve_usdc_linkage.py
    # (falls back to the public node if the env var is unset)

The bridge-blacklist corollary (pushToCore reverts because 0x2000..0000 is blacklisted on
the configured USDC) is proven on real bytecode in
test/fork/HyperVaultLiveness.fork.t.sol::test_G_pushToCoreRevertsOnBlacklistedBridge.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.request

# The configured vault asset on HyperEVM mainnet (deployments/configs/mainnet-tier1.json).
CONFIGURED_ASSET = "0xb88339cb7199b77e23db6e890353e22632ba630f"
# Core token index for USDC (Constants.USDC_CORE_INDEX) and the tokenInfo precompile.
USDC_CORE_INDEX = 0
TOKEN_INFO_PRECOMPILE = "0x000000000000000000000000000000000000080C"
DEFAULT_RPC = "https://rpc.hyperliquid.xyz/evm"


def eth_call(rpc: str, to: str, data: str) -> bytes:
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_call",
        "params": [{"to": to, "data": data}, "latest"],
    }
    req = urllib.request.Request(
        rpc, data=json.dumps(payload).encode(), headers={"content-type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = json.loads(resp.read())
    if "error" in body:
        raise RuntimeError(f"eth_call error: {body['error']}")
    return bytes.fromhex(body["result"][2:])


def word(ret: bytes, index: int) -> bytes:
    """Return the 32-byte ABI word at `index` (0-based) of the decoded tuple body.

    The precompile returns a single dynamic tuple, so ret[0:32] is the 0x20 offset to the
    tuple body; the head words start at byte 32.
    """
    start = 32 + index * 32
    return ret[start : start + 32]


def addr_from_word(w: bytes) -> str:
    return "0x" + w[12:].hex()


def main() -> int:
    rpc = os.environ.get("HYPEREVM_RPC_MAINNET", DEFAULT_RPC)
    # tokenInfo(uint32 tokenIndex) — raw precompile input is abi.encode(uint32).
    data = "0x" + format(USDC_CORE_INDEX, "064x")
    ret = eth_call(rpc, TOKEN_INFO_PRECOMPILE, data)

    # TokenInfo head layout (see PrecompileLib.TokenInfo):
    #   [0] name offset  [1] spots offset  [2] deployerTradingFeeShare
    #   [3] deployer     [4] evmContract   [5] szDecimals  [6] weiDecimals  [7] evmExtraWeiDecimals
    evm_contract = addr_from_word(word(ret, 4))
    wei_decimals = int.from_bytes(word(ret, 6), "big")
    extra = int.from_bytes(word(ret, 7), "big")
    extra = extra - (1 << 256) if extra >= (1 << 255) else extra  # int8

    linked = evm_contract.lower() == CONFIGURED_ASSET.lower()

    print(f"RPC:                       {rpc}")
    print(f"Core USDC (token {USDC_CORE_INDEX}) linked EVM contract: {evm_contract}")
    print(f"Core USDC weiDecimals / evmExtraWeiDecimals:   {wei_decimals} / {extra}  "
          f"(EVM side decimals = {wei_decimals + extra})")
    print(f"Configured vault asset:    {CONFIGURED_ASSET}")
    print("-" * 72)
    if linked:
        print("VERDICT: LINKED. The configured asset IS the Core-USDC EVM contract.")
        print("         => pullFromCore/coreSpotUsdc are faithful; the natspec/README claim")
        print("            of 'not linked' would be STALE. (Re-check the blacklist corollary.)")
        return 0
    print("VERDICT: NOT LINKED (Finding G CONFIRMED).")
    print("         The configured asset is a DIFFERENT USDC than the one Core token 0 bridges")
    print("         to. Therefore:")
    print("           - coreSpotUsdc() measures the vault's balance of a token that is NOT asset();")
    print("           - pushToCore/pullFromCore target the Core bridge 0x2000..0000, which is")
    print("             blacklisted on the configured Circle USDC -> they REVERT (see the fork")
    print("             test test_G_pushToCoreRevertsOnBlacklistedBridge);")
    print("           - the redemption queue can never realise Core value into asset() via the")
    print("             canonical bridge with this configuration.")
    return 2


if __name__ == "__main__":
    sys.exit(main())

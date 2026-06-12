#!/usr/bin/env python3
"""USDC linkage resolver — read-only, live-node proof of the EVM<->Core USDC route (G2).

WHY THIS EXISTS (and is not a Foundry fork test): the EVM<->Core USDC linkage lives in
the HyperCore `tokenInfo` precompile at 0x...080C. Foundry's revm does NOT implement the
HyperEVM precompiles, so a forge fork reads it as empty (it would falsely report
evmContract == address(0)). A real `eth_call` to the live node DOES execute the precompile.
This script makes that read with zero dependencies (stdlib only) and no keys/funds.

THREE POSSIBLE VERDICTS (audit G2 superseded the original Finding-G binary):
  - WALLET-LINKED  (expected mainnet state since 2025-12-08): tokenInfo(0).evmContract is
    Circle's CoreDepositWallet — a bridge CONTRACT, not an ERC-20 — whose `token()` is the
    configured asset. pushToCore must use approve+deposit on the wallet; pullFromCore's
    Core-side send pays out through the wallet's system-guarded transfer().
  - DIRECT-LINKED  (HIP-1 pattern): evmContract IS the configured asset; the legacy
    transfer-to-system-address route is canonical (coreDepositWallet = 0 in config).
  - NOT-LINKED: neither — no trustless route; the pre-G2 Path-B treasury posture applies.

Run:
    HYPEREVM_RPC_MAINNET=<rpc> python3 scripts/python/resolve_usdc_linkage.py
    # (falls back to the public node if the env var is unset)

The bridge-blacklist corollary (a LEGACY push reverts because 0x2000..0000 is blacklisted
on the configured USDC — Circle forces the wallet path) is proven on real bytecode in
test/fork/HyperVaultLiveness.fork.t.sol::test_G_legacyPushRevertsOnBlacklistedBridge; the
wallet route itself in test/fork/HyperVaultCoreDepositWallet.fork.t.sol.
"""
from __future__ import annotations

import json
import os
import ssl
import sys
import urllib.request

# macOS CommandLineTools python ships without root CAs; prefer certifi when
# present (the repo .venv has it via the hyperliquid SDK), else system default.
try:
    import certifi

    _SSL_CTX = ssl.create_default_context(cafile=certifi.where())
except ImportError:  # pragma: no cover
    _SSL_CTX = ssl.create_default_context()

# The configured vault asset on HyperEVM mainnet (deployments/configs/mainnet-tier1.json).
CONFIGURED_ASSET = "0xb88339cb7199b77e23db6e890353e22632ba630f"
# Core token index for USDC (Constants.USDC_CORE_INDEX) and the tokenInfo precompile.
USDC_CORE_INDEX = 0
TOKEN_INFO_PRECOMPILE = "0x000000000000000000000000000000000000080C"
USDC_SYSTEM_ADDRESS = "0x2000000000000000000000000000000000000000"
DEFAULT_RPC = "https://rpc.hyperliquid.xyz/evm"

# 4-byte selectors (stdlib has no keccak256; values from `cast sig`).
SEL_TOKEN = "0xfc0c546a"                 # token()
SEL_PAUSED = "0x5c975abb"                # paused()
SEL_TOKEN_SYSTEM_ADDRESS = "0x0d39c3fc"  # tokenSystemAddress()
SEL_BALANCE_OF = "0x70a08231"            # balanceOf(address)


def eth_call(rpc: str, to: str, data: str) -> bytes:
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_call",
        "params": [{"to": to, "data": data}, "latest"],
    }
    req = urllib.request.Request(
        rpc,
        data=json.dumps(payload).encode(),
        headers={
            "content-type": "application/json",
            # Some public RPCs (e.g. drpc) 403 the default urllib user agent.
            "user-agent": "hypervault-linkage-resolver/1.0",
        },
    )
    with urllib.request.urlopen(req, timeout=20, context=_SSL_CTX) as resp:
        body = json.loads(resp.read())
    if "error" in body:
        raise RuntimeError(f"eth_call error: {body['error']}")
    return bytes.fromhex(body["result"][2:])


def try_call_addr(rpc: str, to: str, selector: str) -> str | None:
    """eth_call returning an address, or None if the call reverts/returns nothing."""
    try:
        ret = eth_call(rpc, to, selector)
    except RuntimeError:
        return None
    if len(ret) < 32:
        return None
    return "0x" + ret[12:32].hex()


def try_call_bool(rpc: str, to: str, selector: str) -> bool | None:
    try:
        ret = eth_call(rpc, to, selector)
    except RuntimeError:
        return None
    if len(ret) < 32:
        return None
    return int.from_bytes(ret[:32], "big") != 0


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

    print(f"RPC:                       {rpc}")
    print(f"Core USDC (token {USDC_CORE_INDEX}) linked EVM contract: {evm_contract}")
    print(f"Core USDC weiDecimals / evmExtraWeiDecimals:   {wei_decimals} / {extra}  "
          f"(EVM side decimals = {wei_decimals + extra})")
    print(f"Configured vault asset:    {CONFIGURED_ASSET}")
    print("-" * 72)

    if evm_contract.lower() == CONFIGURED_ASSET.lower():
        print("VERDICT: DIRECT-LINKED. The configured asset IS the Core-USDC EVM contract")
        print("         (HIP-1 pattern). Deploy with coreDepositWallet = address(0); the")
        print("         legacy transfer-to-system-address route is canonical.")
        return 0

    if int(evm_contract, 16) != 0:
        wallet_token = try_call_addr(rpc, evm_contract, SEL_TOKEN)
        if wallet_token is not None and wallet_token.lower() == CONFIGURED_ASSET.lower():
            paused = try_call_bool(rpc, evm_contract, SEL_PAUSED)
            sys_addr = try_call_addr(rpc, evm_contract, SEL_TOKEN_SYSTEM_ADDRESS)
            reserve_ret = eth_call(
                rpc, CONFIGURED_ASSET, SEL_BALANCE_OF + evm_contract[2:].rjust(64, "0")
            )
            reserve = int.from_bytes(reserve_ret[:32], "big") / 1e6
            sys_ok = sys_addr is not None and sys_addr.lower() == USDC_SYSTEM_ADDRESS
            print("VERDICT: WALLET-LINKED (audit G2 — the expected mainnet state).")
            print(f"         evmContract is a CoreDepositWallet, not an ERC-20:")
            print(f"           wallet.token():             {wallet_token}  (== configured asset)")
            print(f"           wallet.tokenSystemAddress(): {sys_addr}  "
                  f"({'OK' if sys_ok else 'MISMATCH vs ' + USDC_SYSTEM_ADDRESS})")
            print(f"           wallet.paused():             {paused}")
            print(f"           wallet USDC reserve:         {reserve:,.2f} USDC")
            print("         => deploy with coreDepositWallet = evmContract above;")
            print("            pushToCore uses approve+deposit; pullFromCore unchanged.")
            if paused:
                print("         WARNING: wallet is PAUSED — both bridge directions are stalled")
                print("                  until Circle unpauses (contingency: operatorRecoverSpot).")
                return 3
            if not sys_ok:
                print("         WARNING: tokenSystemAddress mismatch — the vault constructor")
                print("                  would (correctly) refuse this configuration.")
                return 4
            return 0

    print("VERDICT: NOT LINKED (the original Finding-G posture).")
    print("         The configured asset has no usable route to Core token 0:")
    print("           - coreSpotUsdc() measures a token that is NOT asset();")
    print("           - a LEGACY push targets the bridge 0x2000..0000, blacklisted on the")
    print("             configured Circle USDC -> it REVERTS;")
    print("           - the redemption queue can only realise Core value via the Path-B")
    print("             treasury route (operatorRecoverSpot -> treasury -> re-deposit).")
    return 2


if __name__ == "__main__":
    sys.exit(main())

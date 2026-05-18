"""Thin wrappers around the Hyperliquid Python SDK for the e2e runner.

Conventions: a HyperEVM smart contract IS a HyperCore account, addressable by
its 20-byte EVM address. Reads use `Info`; writes go through the vault EVM
contract, not the HL Exchange endpoint, so we don't need a signed L1 account
for normal ops. The one exception is `update_evm_user_modify` (big-blocks
opt-in), which the vault itself signs via an API wallet — see
`optin_big_blocks.py`.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Optional

from hyperliquid.info import Info
from hyperliquid.utils import constants


def make_info(network: str) -> Info:
    base = constants.TESTNET_API_URL if network == "testnet" else constants.MAINNET_API_URL
    return Info(base_url=base, skip_ws=True)


@dataclass
class PerpAssetMeta:
    index: int
    name: str
    sz_decimals: int
    max_leverage: int

    def encode_px(self, human_price: float) -> int:
        """HL convention: encoded_px = floor(human_price * 10^(8 - szDecimals))."""
        return int(human_price * (10 ** (8 - self.sz_decimals)))

    def decode_px(self, encoded_px: int) -> float:
        return encoded_px / (10 ** (8 - self.sz_decimals))

    def encode_sz(self, human_size: float) -> int:
        return int(human_size * (10 ** self.sz_decimals))

    def round_to_tick(self, human_price: float, sig_figs: int = 5) -> float:
        """HL requires <=5 sig figs and increments of 10^(8 - szDecimals) raw.
        We round to 5 sig figs and to the nearest raw tick, returning the
        human-readable value."""
        if human_price == 0:
            return 0.0
        # Round to sig_figs significant figures
        d = math.floor(math.log10(abs(human_price)))
        factor = 10 ** (sig_figs - 1 - d)
        rounded = round(human_price * factor) / factor
        # Round to nearest raw tick
        tick = 1 / (10 ** (8 - self.sz_decimals))
        return round(rounded / tick) * tick


def get_perp_meta(info: Info, asset_index: int) -> PerpAssetMeta:
    meta = info.meta()
    universe = meta["universe"]
    if asset_index >= len(universe):
        raise ValueError(f"perp asset index {asset_index} out of range (len={len(universe)})")
    entry = universe[asset_index]
    return PerpAssetMeta(
        index=asset_index,
        name=entry["name"],
        sz_decimals=int(entry["szDecimals"]),
        max_leverage=int(entry.get("maxLeverage", 1)),
    )


def perp_mark_px(info: Info, asset_index: int) -> float:
    """Returns the current mark price as a human-readable float."""
    _, ctxs = info.meta_and_asset_ctxs()
    return float(ctxs[asset_index]["markPx"])


def perp_oracle_px(info: Info, asset_index: int) -> float:
    _, ctxs = info.meta_and_asset_ctxs()
    return float(ctxs[asset_index]["oraclePx"])


def open_orders(info: Info, address: str) -> list[dict]:
    return info.open_orders(address)


def find_resting_by_cloid(info: Info, address: str, cloid: int) -> Optional[dict]:
    """Returns the open order dict whose cloid matches, or None."""
    cloid_hex = "0x" + cloid.to_bytes(16, "big").hex()
    for o in info.open_orders(address):
        if o.get("cloid", "").lower() == cloid_hex.lower():
            return o
    return None


def user_state(info: Info, address: str) -> dict:
    """Perp account state: positions, marginSummary, withdrawable."""
    return info.user_state(address)


def spot_user_state(info: Info, address: str) -> dict:
    """Spot account state: balances per token."""
    return info.spot_user_state(address)


def spot_balance(info: Info, address: str, token_index: int) -> float:
    """Returns human-readable USDC balance on Core spot for a given token index."""
    state = info.spot_user_state(address)
    for b in state.get("balances", []):
        if int(b["token"]) == token_index:
            return float(b["total"])
    return 0.0


def fmt_human(label: str, val: float, unit: str = "USDC") -> str:
    return f"{label}: {val:,.6f} {unit}"

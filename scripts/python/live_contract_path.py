#!/usr/bin/env python3
"""Contract-path confirmation of the v1.3 fixes against the freshly-deployed
FIXED vault: whitelist BTC, fund perp, place a tif=1 / 10^8-scale order THROUGH
the vault (exercising the corrected band + leverage-cap gates), confirm it rests
on the HL book, cancel, and recover funds. Real money (~$11, recoverable)."""
import json, os, sys, time
from pathlib import Path
from eth_account import Account
from web3 import Web3
from hyperliquid.exchange import Exchange
from hyperliquid.utils import constants
import hl_helpers as hl

VAULT = os.environ.get("TEST_VAULT", "0xDbD860Cbaa83a96eb177527635103D66aB816Ce5")
OPERATOR = "0x200342145Ae3A0c1da9AdE8571EC0ff23c2b753A"
BTC = 0
FUND = 11.0
SZ = 0.0002
REPO_ROOT = Path(__file__).resolve().parents[2]


def load_vault(w3):
    abi = json.loads((REPO_ROOT / "out" / "HyperCoreVault.sol" / "HyperCoreVault.json").read_text())["abi"]
    return w3.eth.contract(address=Web3.to_checksum_address(VAULT), abi=abi)


def send(w3, acct, fn, gas, label):
    tx = fn.build_transaction({"from": acct.address, "nonce": w3.eth.get_transaction_count(acct.address),
                               "gas": gas, "gasPrice": w3.eth.gas_price, "chainId": w3.eth.chain_id})
    h = w3.eth.send_raw_transaction(acct.sign_transaction(tx).raw_transaction)
    r = w3.eth.wait_for_transaction_receipt(h, timeout=180)
    print(f"    {label}: {'OK' if r.status == 1 else 'REVERT'}  {h.hex()}  gas {r.gasUsed}", flush=True)
    if r.status != 1:
        raise RuntimeError(f"{label} reverted")
    return r


def wait(pred, timeout=25, label=""):
    t = time.time()
    while time.time() - t < timeout:
        try:
            if pred():
                return True
        except Exception as e:
            print("   poll err", e)
        time.sleep(2)
    return False


def perp_val(info, a):
    return float(hl.user_state(info, a).get("marginSummary", {}).get("accountValue", 0) or 0)


def main():
    w3 = Web3(Web3.HTTPProvider(os.environ["HYPEREVM_RPC_MAINNET"]))
    op = Account.from_key(os.environ["OPERATOR_PRIVATE_KEY"])
    info = hl.make_info("mainnet")
    ex = Exchange(op, base_url=constants.MAINNET_API_URL)
    v = load_vault(w3)
    print(f"vault={VAULT}  name={v.functions.name().call()}  paused={v.functions.paused().call()}")

    print("use_big_blocks(False):", json.dumps(ex.use_big_blocks(False)))

    if 0 not in [int(x) for x in v.functions.whitelistedPerpsList().call()]:
        send(w3, op, v.functions.setWhitelistPerp(0, True), 200_000, "whitelist BTC")
    print("whitelisted perps:", v.functions.whitelistedPerpsList().call())

    if perp_val(info, VAULT) < FUND - 0.5:
        print("fund vault perp:", json.dumps(ex.send_asset(Web3.to_checksum_address(VAULT), "spot", "", "USDC", FUND)))
        wait(lambda: perp_val(info, VAULT) >= FUND - 0.5, 40, "perp credit")
    print(f"vault perp={perp_val(info, VAULT):.4f}  perpWithdrawable={v.functions.perpWithdrawable().call()/1e6:.4f}")

    meta = hl.get_perp_meta(info, BTC)
    oracle = hl.perp_oracle_px(info, BTC)
    human_px = meta.round_to_tick(oracle * 0.99)
    enc_px, enc_sz = meta.encode_px(human_px), meta.encode_sz(SZ)
    print(f"\noracle={oracle} human_px={human_px} enc_px={enc_px} (10^8 scale) enc_sz={enc_sz} (~${SZ*oracle:.2f})", flush=True)
    r = send(w3, op, v.functions.placeLimitOrder(BTC, True, enc_px, enc_sz, False, 1), 1_500_000, "placeLimitOrder tif=1 (10^8)")
    ev = v.events.LimitOrderSubmitted().process_receipt(r)
    cloid = int(ev[0]["args"]["cloid"])
    print(f"    cloid={cloid}")
    rested = wait(lambda: hl.find_resting_by_cloid(info, VAULT, cloid) is not None, 25, "resting")
    print(f"    *** ORDER RESTED ON HL BOOK (contract path): {rested} ***")
    print("    openOrders:", json.dumps(hl.open_orders(info, VAULT)))

    if rested:
        send(w3, op, v.functions.cancelOrderByCloid(BTC, cloid), 800_000, "cancel")
        wait(lambda: hl.find_resting_by_cloid(info, VAULT, cloid) is None, 25, "cancelled")

    # recover ~$11: allowlist operator (this vault has the C-2 allowlist), perp->spot, recover
    try:
        send(w3, op, v.functions.setSpotRecoverDest(op.address, True), 200_000, "setSpotRecoverDest")
        pv = perp_val(info, VAULT)
        if pv > 0.01:
            send(w3, op, v.functions.usdPerpToSpot(int(pv * 1e6)), 600_000, "usdPerpToSpot")
            wait(lambda: hl.spot_balance(info, VAULT, 0) >= pv - 0.5, 40, "perp->spot")
        sv = hl.spot_balance(info, VAULT, 0)
        if sv > 0.01:
            send(w3, op, v.functions.operatorRecoverSpot(op.address, 0, int((sv - 0.0001) * 1e8)), 800_000, "operatorRecoverSpot")
    except Exception as e:
        print("  recovery error:", e)
    print(f"\nFINAL vault perp={perp_val(info, VAULT):.4f} spot={hl.spot_balance(info, VAULT, 0):.4f} | operator spot={hl.spot_balance(info, OPERATOR, 0):.4f}")
    print(f"\n=== CONTRACT-PATH RESULT: {'CONFIRMED — order rested via the vault' if rested else 'NOT confirmed'} ===")
    return 0 if rested else 1


if __name__ == "__main__":
    sys.exit(main())

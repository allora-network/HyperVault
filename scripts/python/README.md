# Python scripts — live mainnet test harness + ops helpers

These scripts are the project's **live mainnet integration coverage** (the
mock-based forge tests were retired in favour of real on-chain verification).
Run from the repo root after `forge build` (the runner reads ABIs from `out/`).

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r scripts/python/requirements.txt
```

Everything targets **HyperEVM mainnet** by default. Set `OPERATOR_PRIVATE_KEY`
(the vault operator key) and `HYPEREVM_RPC_MAINNET` (see `.env`).

## `e2e_runner.py` — full-lifecycle live test harness
Drives a vault through `deposit → push → spot→perp → place → cancel → fill →
perp→spot → pull → redeem` on mainnet, asserting both the vault's on-chain state
and the HL API view at each step. `place` rests a post-only order; `fill` crosses
the book with a marketable IOC (real taker fill + fees, then flattens
reduce-only); the bridge steps need a linked EVM↔Core USDC bridge.

```bash
ARTIFACT=deployments/mainnet/<strategy>.json \
OPERATOR_PRIVATE_KEY=0x... ALICE_PRIVATE_KEY=0x... \
python scripts/python/e2e_runner.py                                   # full run
python scripts/python/e2e_runner.py --steps preflight,core_status    # read-only sanity
python scripts/python/e2e_runner.py --steps place,cancel --skip-bridge
```

## `live_contract_path.py` — focused order-lifecycle live test
Whitelist BTC → fund perp (`send_asset`) → place a `tif=1` / `10^8`-scale order
through the vault → confirm it rests on the HL book → cancel → recover funds.
Used to confirm the v1.3 px/sz-scale + TIF fixes from the contract path.

```bash
TEST_VAULT=0x... OPERATOR_PRIVATE_KEY=0x... \
python scripts/python/live_contract_path.py
```

## `optin_big_blocks.py`
Opt an address into HyperEVM big blocks (required to deploy the ~6–8M-gas vault).

```bash
OPERATOR_PRIVATE_KEY=0x... VAULT_ADDRESS=0x... NETWORK=mainnet \
python scripts/python/optin_big_blocks.py
```

## `seed_vault_core.py`
Spot-send USDC from your HL Core account to a vault's Core address — how to fund
a vault for perp orders when the EVM↔Core USDC bridge isn't linked for the asset
(the current mainnet state).

```bash
VAULT_ADDRESS=0x... OPERATOR_PRIVATE_KEY=0x... USDC_AMOUNT=20 NETWORK=mainnet \
python scripts/python/seed_vault_core.py
```

## `seed_whitelist.py`
Schedule + execute whitelist additions through the per-vault timelock.

```bash
ARTIFACT=deployments/mainnet/<strategy>.json \
HYPEREVM_RPC_MAINNET=https://rpc.hyperliquid.xyz/evm \
DEPLOYER_PRIVATE_KEY=0x... PERPS_TO_ADD=1,5,12 \
python scripts/python/seed_whitelist.py
```

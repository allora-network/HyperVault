# Python scripts

Run from the repo root after `forge build` (the runner reads ABIs from `out/`).

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r scripts/python/requirements.txt
```

## `e2e_runner.py`
End-to-end testnet driver. See `docs/TESTNET.md` for full walkthrough.

```bash
ARTIFACT=deployments/testnet/testnet-example.json \
HYPEREVM_RPC_TESTNET=https://rpc.hyperliquid-testnet.xyz/evm \
ALICE_PRIVATE_KEY=0x... \
OPERATOR_PRIVATE_KEY=0x... \
python scripts/python/e2e_runner.py
```

Selective steps: `--steps preflight,deposit,push`

## `optin_big_blocks.py`
One-shot helper to opt a vault into HyperEVM big blocks via HL API.

```bash
OPERATOR_PRIVATE_KEY=0x... \
VAULT_ADDRESS=0x... \
NETWORK=testnet \
python scripts/python/optin_big_blocks.py
```

## `seed_vault_core.py`
Spot-send USDC from your personal HL Core account to a vault's Core address.
Used on testnet (or any environment) where the real EVM↔Core bridge isn't
available and we manually fund the vault for perp orders.

```bash
VAULT_ADDRESS=0x... \
OPERATOR_PRIVATE_KEY=0x... \
USDC_AMOUNT=20 \
NETWORK=testnet \
python scripts/python/seed_vault_core.py
```

## `seed_whitelist.py`
Schedule + execute whitelist additions through the per-vault timelock.

```bash
ARTIFACT=deployments/testnet/testnet-example.json \
HYPEREVM_RPC_TESTNET=https://rpc.hyperliquid-testnet.xyz/evm \
DEPLOYER_PRIVATE_KEY=0x... \
PERPS_TO_ADD=1,5,12 \
python scripts/python/seed_whitelist.py
```

# Testnet E2E Walkthrough

End-to-end deploy + lifecycle test on Hyperliquid testnet, with real signed transactions and cross-checks against the HL API. Takes about 20 minutes the first time.

## What you'll need

- A funded testnet wallet (HYPE for gas) — get from the [Hyperliquid testnet drip](https://app.hyperliquid-testnet.xyz/drip)
- Some testnet USDC to deposit — drip also gives this
- Two private keys: one for the **deployer** (also acts as operator initially), one for **alice** (depositor). For a smoke test both can be the same key
- Python 3.11+ and Node 20+
- This repo at `~/Downloads/AlloraLabs/VaultContract` with `forge build` already run

## 1. The USDC situation on testnet

Real USDC is **not** deployed as an ERC20 on HyperEVM testnet — the `tokenInfo(0)` precompile points to `0xb806…2060`, but that address has empty bytecode. Hyperliquid pre-allocated the address but never deployed the wrapper.

That means **we deploy our own `MockUSDC`** on HyperEVM testnet and use it as the vault asset. The Core USDC you got from the drip is still useful: we'll `spot_send` it from your personal Core account directly into the vault's Core address to fund perp orders, bypassing the EVM-side bridge entirely.

What this loses: end-to-end test of `pushToCore`/`pullFromCore` (the actual EVM↔Core bridge mechanic). Those paths are covered by the Foundry integration test against `CoreSimulator`. Everything else — deposits, redeems, fee math, CoreWriter order placement, cancels, perp class transfers, NAV precompile reads — is tested with real signed txs against HL testnet.

Deploy MockUSDC and mint yourself test funds:

```bash
MINT_AMOUNT_USDC=100000 \
forge script script/DeployMockUSDC.s.sol \
    --rpc-url $HYPEREVM_RPC_TESTNET --broadcast
```

Note the printed `MockUSDC deployed at: 0x…` — that's the `usdcAddress` for your vault config.

## 2. Set environment

```bash
cd ~/Downloads/AlloraLabs/VaultContract
cp .env.example .env
# Edit .env with your values
```

Minimum needed in `.env`:

```bash
HYPEREVM_RPC_TESTNET=https://rpc.hyperliquid-testnet.xyz/evm
DEPLOYER_PRIVATE_KEY=0x...
# After the registry deploy step below:
FACTORY_TESTNET=0x...
REGISTRY_TESTNET=0x...
```

Also:

```bash
source .env  # forge scripts read from process env
```

## 3. One-time: deploy registry + factory

```bash
forge script script/DeployRegistry.s.sol \
    --rpc-url $HYPEREVM_RPC_TESTNET \
    --broadcast
```

The script writes `deployments/testnet/registry.json`. Copy the printed addresses back into your `.env` as `REGISTRY_TESTNET` and `FACTORY_TESTNET`.

## 4. Configure your test vault

```bash
cp deployments/configs/testnet-example.json deployments/configs/smoke.json
```

Edit `smoke.json`:

```json
{
  "name": "Testnet Smoke",
  "symbol": "tsmoke",
  "operator": "0xYourDeployerAddress",
  "emergencyAdmin": "0xYourDeployerAddress",
  "feeRecipient": "0xYourDeployerAddress",
  "usdcAddress": "0xTestnetUsdcAddress",
  "timelockMinDelaySec": 0,
  "leverageCapBps": 30000,
  "slippageBandBps": 200,
  "perfFeeBps": 1500,
  "mgmtFeeAnnualBps": 200,
  "depositCap": "100000000000",
  "maxDepositPerAddress": "10000000000",
  "whitelistPerps": [0],
  "whitelistSpots": []
}
```

`timelockMinDelaySec: 0` is intentional for testnet — it lets the deploy script seed the whitelist in the same tx. For production set it to `86400` and run `scripts/python/seed_whitelist.py` after the delay window.

## 5. Deploy the vault

```bash
STRATEGY_CONFIG=deployments/configs/smoke.json \
forge script script/Deploy.s.sol \
    --rpc-url $HYPEREVM_RPC_TESTNET \
    --broadcast
```

This:
- Deploys a per-vault `TimelockController`
- Calls the factory to CREATE2-deploy a `HyperCoreVault`
- Registers the vault in the `HyperCoreVaultRegistry`
- Schedules + executes `setWhitelistPerp(0, true)` through the timelock (because delay=0)
- Writes the artifact JSON to `deployments/testnet/smoke.json`

Note the printed `Vault:` and `Timelock:` addresses.

## 6. Opt the vault into big blocks

The emergency fan-out paths can exceed the 2M-gas small-block limit. Opt the vault into big blocks via the HL API:

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r scripts/python/requirements.txt

OPERATOR_PRIVATE_KEY=$DEPLOYER_PRIVATE_KEY \
VAULT_ADDRESS=0xYourVaultAddress \
NETWORK=testnet \
python scripts/python/optin_big_blocks.py
```

You should see `{"status": "ok", ...}`.

## 7. Seed the vault's Core account

Because we're using `MockUSDC` (not bridge-linked), the `pushToCore` step won't actually credit Core. Instead, fund the vault's Core address directly from your personal Core account (vault Core address = its EVM address):

```bash
VAULT_ADDRESS=0xYourVaultAddress \
OPERATOR_PRIVATE_KEY=$DEPLOYER_PRIVATE_KEY \
USDC_AMOUNT=20 \
NETWORK=testnet \
python scripts/python/seed_vault_core.py
```

Confirm by re-querying:

```bash
curl -s -X POST https://api.hyperliquid-testnet.xyz/info \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"spotClearinghouseState\",\"user\":\"0xYourVaultAddress\"}"
```

You should see `total: "20.0"` for token 0.

## 8. Run the e2e lifecycle

```bash
ARTIFACT=deployments/testnet/smoke.json \
HYPEREVM_RPC_TESTNET=https://rpc.hyperliquid-testnet.xyz/evm \
ALICE_PRIVATE_KEY=$DEPLOYER_PRIVATE_KEY \
OPERATOR_PRIVATE_KEY=$DEPLOYER_PRIVATE_KEY \
python scripts/python/e2e_runner.py \
    --deposit-usdc 10 --asset 0 --skip-bridge
```

The `--skip-bridge` flag omits the `push`/`pull` steps (which would no-op against MockUSDC). The runner walks through:

| Step | What it does | HL API cross-check |
|---|---|---|
| `preflight` | balance + role sanity checks | n/a |
| `deposit` | alice approves + deposits 10 USDC (MockUSDC) | n/a (EVM only) |
| `core_status` | reports vault's Core balances (post-seed) | informational |
| `spot_to_perp` | operator `usdSpotToPerp(5 USDC)` | `info.user_state(vault).marginSummary` grows |
| `place` | operator places BTC buy 1% below mark (post-only) | `info.open_orders(vault)` contains the cloid |
| `cancel` | operator `cancelOrderByCloid(cloid)` | open order disappears from HL |
| `perp_to_spot` | operator `usdPerpToSpot(5 USDC)` | perp margin drops |
| `redeem` | alice redeems all shares | alice's MockUSDC balance ≈ original (minus fees) |

(Without `--skip-bridge`, the runner additionally executes `push` and `pull` — only useful when you have a real linked ERC20 as the vault asset.)

Each step prints both the EVM event and the HL API state and asserts they agree. Failures are collected at the end. Run a subset with `--steps deposit,place,cancel,redeem` if you want to iterate.

## 9. Inspect via the frontend

```bash
cd frontend
echo "VITE_REGISTRY_TESTNET=$REGISTRY_TESTNET" > .env.local
npm install
npm run dev
```

Open `http://localhost:5173`, click "testnet", and your vault should appear in the grid with live NAV breakdown.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `forge script` fails with `Set FACTORY_TESTNET in env` | step 3 not done or `.env` not sourced | rerun step 3, then `source .env` |
| Deploy reverts at `_seedWhitelistViaTimelock` | `timelockMinDelaySec > 0` but factory granted you proposer + executor | set delay to 0 for bootstrap, or use `seed_whitelist.py` after waiting |
| `push` step times out waiting for Core credit | testnet bridge slow or USDC address wrong | confirm `tokenInfo(0).evmContract` matches `usdcAddress` in your config |
| `place` step says "cloid did not appear" | HL rejected the order — usually tick size, slippage band, or min size | re-run with `--asset 0` and a fresh price; or relax `slippageBandBps` |
| Order fills instead of resting | mark moved through your post-only price | re-run; ALO with 1% below mark almost always rests on a calm market |
| `pull` step times out | bridge async credit slower than `wait_for` timeout | wait a minute and re-check `vault.idleUsdc()` manually with `cast call` |
| `redeem` returns less than deposit | mgmt fee accrued between deposit and redeem — expected | verify the delta is ≤ `mgmtFeeAnnualBps * elapsed_seconds / (10000 * 365 days)` of deposit |

## Cleanup

There's nothing to clean up. The vault, registry, factory, and timelock stay deployed on testnet. To do a fresh run with a new vault, just give a different `name` / `symbol` in the config — CREATE2 will deploy to a new address.

## After testnet — going to mainnet

When testnet has run cleanly end-to-end:

1. Set `timelockMinDelaySec: 86400` in your production config
2. Set `operator`, `emergencyAdmin`, `feeRecipient` to production multisigs (NOT the deployer EOA)
3. Set `usdcAddress` to mainnet USDC
4. Deploy registry + factory on mainnet (one-time)
5. Deploy the vault — the script will NOT seed the whitelist (delay > 0); use `seed_whitelist.py` 24h later
6. Opt into big blocks
7. Smoke test with a $100 deposit before opening to LPs

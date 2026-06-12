# HyperVault

**EIP-4626 vault template for HyperEVM**, with on-chain NAV via HyperCore precompiles and trade execution via the CoreWriter system contract. Replaces Hyperliquid's legacy native vaults (10,000 USDC creation fee, perps-only) with a gas-only Solidity contract that supports spot, perps, and HIP-3 markets in any quote.

Validated end-to-end on **HyperEVM mainnet** (chain 999) — see [the mainnet findings](#real-mainnet-findings) below for what worked, what didn't, and the v1.3 fixes that shipped from that exercise.

---

## What this gives you

- **Audit-ready ERC-4626 vault** (`src/HyperCoreVault.sol`) — operator/emergency/admin roles, asset whitelist, leverage cap, slippage band, management + performance fees, withdrawal queue, cost-basis tracking
- **Per-strategy deploy pipeline** — JSON config in, on-chain vault + per-vault `TimelockController` + auto-registered entry out
- **Discovery frontend** — Vite + React + viem; auto-discovers every vault from `deployments/<chain>/*.json` artifacts at build time
- **Live mainnet test harness** (`scripts/python/e2e_runner.py`) — exercises the full lifecycle against real HyperCore (`deposit → spot↔perp → limit order place / cancel / fill-confirm → withdraw / redeem`) with HL-API assertions at each step. Mock-based forge tests were retired in favour of live verification — see [the mainnet findings](#real-mainnet-findings).

## Why HyperEVM (not legacy HyperCore vaults)

| | Legacy HyperCore vault | HyperVault on HyperEVM |
|---|---|---|
| Creation fee | 10,000 USDC | ~$1 in gas |
| Asset support | Perps only, USDC quote | Spot + perp + HIP-3, any quote |
| Composability | None — internal HL accounting | ERC-20 share token; DeFi-native |
| Custom logic | Fixed | Arbitrary Solidity (fees, lockups, whitelists, etc.) |
| Where it runs | HL Core matching engine | HyperEVM EVM contract; calls Core via `CoreWriter` (`0x3333…3333`) |

The vault contract lives on HyperEVM but its HyperCore account is automatically derived from its EVM address — so a single deploy gives you one ERC-4626 token, one EVM contract, and one Core account, all at the same address.

---

## Architecture at a glance

```
            ┌─────────────────────────────────────────────────┐
            │  Operator (EOA / multisig)                      │
            │  Emergency Admin (multisig)                     │
            │  Timelock (24h) ─ admin role                    │
            └────────────┬────────────────────────────────────┘
                         │ calls
            ┌────────────▼────────────────────────────────────┐
            │  HyperCoreVault (one per strategy)              │
            │  - ERC4626 share token (12 dp)                  │
            │  - AccessControl: OPERATOR / EMERGENCY / ADMIN  │
            │  - Pausable, ReentrancyGuard                    │
            │  - Whitelist (perps + spots)                    │
            │  - Leverage cap, slippage band, fees            │
            │  - cloid counter                                │
            │  - Withdrawal queue escape hatch                │
            │  - operatorRecoverSpot, operatorSweepStranded   │
            └───────┬─────────────────────┬───────────────────┘
                    │ writes              │ reads
                    ▼                     ▼
            ┌───────────────────┐ ┌────────────────────────┐
            │ CoreWriter        │ │ L1 read precompiles    │
            │ 0x333…3333        │ │ 0x0800 … 0x0810        │
            └───────┬───────────┘ └────────────────────────┘
                    │ async dispatch
                    ▼
            ┌──────────────────────────────────────────────┐
            │  HyperCore matching engine                   │
            │  Position / balance state per account        │
            └──────────────────────────────────────────────┘
```

Deep-dive: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## Repository layout

```
src/                          Solidity sources
  HyperCoreVault.sol          Main ERC4626 vault per strategy
  HyperCoreVaultFactory.sol   CREATE2 factory (currently bypassed for size — see below)
  HyperCoreVaultRegistry.sol  On-chain directory of deployed vaults
  libraries/
    Constants.sol             Precompile addresses, CoreWriter action IDs, TIF enum, USDC indices
    CoreWriterLib.sol         Typed wrappers for limit_order / spot_send / usd_class_transfer / cancel
    PrecompileLib.sol         Typed reads of all L1 precompiles (position, spotBalance, oraclePx, etc.)
    AssetId.sol               Perp/spot ID encoding (spot = 10_000 + spotIdx)
    SystemAddress.sol         Token bridge-address derivation (0x20 || zero-pad || tokenIdx)
  interfaces/
    ICoreWriter.sol
    IHyperCoreVault.sol       Full public ABI + events for indexers / frontend

script/                       Foundry deploy scripts
  DeployRegistry.s.sol        One-time per chain
  Deploy.s.sol                Per-strategy from JSON config; deploys timelock + vault + seeds whitelist
  DeployTifTestVault.s.sol    Throwaway test vault for live mainnet verification (admin=operator)

scripts/python/               Python orchestration + live mainnet test harness (HL SDK + web3.py)
  e2e_runner.py               Full-lifecycle live mainnet test harness; HL API cross-checks per step
  live_contract_path.py       Focused live test: whitelist → fund → place (rests) → cancel → recover
  hl_helpers.py               HL reads + px/sz (×10^8) / tif encoding used by the harness
  optin_big_blocks.py         Toggles HyperEVM big-blocks via HL API (needed for vault deploy)
  seed_vault_core.py          Sends Core USDC from your account to a vault's Core address
  seed_whitelist.py           Post-deploy whitelist updates through the timelock

deployments/                  Strategy configs (input) + deploy artifacts (output)
  configs/                    Per-strategy JSON parameter files (mainnet-tier1/2/2b, example)
  mainnet/                    Per-strategy deploy artifacts written by Deploy.s.sol

docs/                         Architecture, integration, security
  ARCHITECTURE.md             Design rationale + diagrams
  INTEGRATION.md              Live runner integration guide (event → SDK field mapping, runbook)
  SECURITY.md                 Threat model, role/permission matrix, audit checklist, mainnet findings

frontend/                     Vite + React + viem discovery UI
  src/
    App.tsx                   Orchestrator; groups by chain, async live state per vault
    components/VaultCard.tsx  NAV breakdown, fees, paused/shutdown banners
    lib/
      artifacts.ts            Build-time glob of deployments/*/*.json
      chains.ts               Hyperliquid mainnet/testnet/local chain configs
      abi.ts                  Minimal vault ABI for read-only discovery
      fetcher.ts              viem multicall reader for live NAV + state
```

---

## Critical components

### Smart contracts

**`HyperCoreVault.sol`** — the main contract. Per-strategy, EIP-4626-compliant. Notable surface:
- `deposit / mint / withdraw / redeem` — standard ERC-4626 with `maxWithdraw` correctly bounded by idle USDC (no silent reverts)
- `placeLimitOrder / cancelOrderByCloid` — operator-only, gated by asset whitelist + slippage band vs `oraclePx` + post-trade leverage cap
- `pushToCore / pullFromCore` — operator-only EVM↔Core USDC bridging. **v1.5 (G2):** push goes through **Circle's CoreDepositWallet** (`approve + deposit`, the official route for natively-minted USDC; `coreDepositWallet` is a validated per-vault immutable, `address(0)` = legacy direct-linked-asset mode); pull is the unchanged Core-side send that the wallet pays out
- `operatorRecoverSpot(to, token, amountWei)` — operator-only generic Core spot send; **contingency** (e.g. Circle pauses the wallet) — no longer the primary realisation path
- `usdSpotToPerp / usdPerpToSpot` — operator-only USD class transfers
- `operatorSweepStranded(to)` — recovers EVM `asset()` balance when `totalSupply == 0` (the donation-to-empty-vault recovery)
- `emergencyCancelByCloid / emergencyCancelByOid / emergencyClosePositions / emergencyShutdown / pause / unpause` — emergency-role only
- `setWhitelistPerp / setWhitelistSpot / setLeverageCap / setSlippageBand / setFees / setDepositCap / sweep` — admin (timelock) only
- `nav / pricePerShare / idleUsdc / coreSpotUsdc / perpWithdrawable` — public view helpers, all backed by precompile reads

**`HyperCoreVaultRegistry.sol`** — on-chain directory. The frontend reads from `deployments/*/*.json` directly (no chain call needed for discovery), but the registry remains the canonical on-chain source. Owner OR factory can write.

**`HyperCoreVaultFactory.sol`** — currently **bypassed** in the deploy script. The factory's runtime bytecode (which inlines `type(HyperCoreVault).creationCode`) is 30KB+, over the EIP-170 24KB limit. `Deploy.s.sol` constructs the vault via plain CREATE from the script instead. A v1.1 refactor to a minimal-proxy (EIP-1167 Clones) pattern would restore the factory.

### Libraries

**`CoreWriterLib`** — wraps the CoreWriter system contract (`0x3333…3333`). Each typed function packs `abi.encodePacked(uint8(1), uint24(actionId), abi.encode(args))` and calls `sendRawAction`. The action set: `limit_order`, `cancel_order_by_oid`, `cancel_order_by_cloid`, `spot_send`, `usd_class_transfer`, `vault_transfer`. Encoding follows the HL CoreWriter spec — `px`/`sz` as `human × 10^8` and `tif` as `1=ALO / 2=GTC / 3=IOC` — verified live by the mainnet test harness.

**`PrecompileLib`** — typed `staticcall` wrappers for every L1 read precompile (`0x0800–0x0810`). Returns the protocol's struct; falls back to zero-initialised struct if the precompile errors (e.g., the account has never touched that market). Used by the vault for `totalAssets` (NAV = idle + coreSpot + perpWithdrawable) and by the operator gates (oraclePx for slippage, position/markPx for leverage).

**`Constants`, `AssetId`, `SystemAddress`** — small pure helpers. `AssetId` encodes perp/spot IDs (spot = 10_000 + spotIdx). `SystemAddress` derives the per-token bridge address (`0x20 || zero-pad || tokenIdx_BE`).

### Deploy scripts

`forge script script/DeployRegistry.s.sol --rpc-url <RPC> --broadcast` — one-time per chain.

`STRATEGY_CONFIG=deployments/configs/<name>.json forge script script/Deploy.s.sol --rpc-url <RPC> --broadcast` — per strategy. Reads JSON config → deploys per-vault TimelockController → deploys vault via CREATE → registers in registry → seeds whitelist via `scheduleBatch + executeBatch` (when `timelockMinDelaySec == 0`). Writes a typed artifact JSON to `deployments/<chain>/<name>.json` that the frontend auto-discovers.

### Python helpers

`scripts/python/e2e_runner.py` — the live mainnet test harness: drives the full vault lifecycle on HyperEVM mainnet with HL API assertions at every step (deposit, spot↔perp, limit order place/cancel/fill, withdraw/redeem). Step-selectable via `--steps`; `--skip-bridge` for assets without a linked EVM↔Core USDC bridge (fund Core via `seed_vault_core.py` instead).

`scripts/python/optin_big_blocks.py` — toggles HyperEVM big-blocks via the HL API (required because the vault deploy is ~8M gas, over the 2M small-block limit).

`scripts/python/seed_vault_core.py` — sends Core USDC from your account to a vault's Core address (the workaround when the EVM↔Core bridge isn't linked for the chosen asset).

`scripts/python/seed_whitelist.py` — schedules + executes whitelist additions through the per-vault timelock.

### Frontend

Build-time auto-discovery via `import.meta.glob('/deployments/*/*.json', { eager: true })`. To add a new vault to the UI, just run the deploy script — the artifact is picked up on the next `npm run dev` / `npm run build`. Per-chain grouping, live NAV / fee / paused-state reads via viem multicall.

```bash
cd frontend
npm install
ln -sf ../deployments deployments  # one-time, lets Vite glob the artifacts
npm run dev          # http://localhost:5173
```

---

## Quick start

### Prerequisites
- [Foundry](https://book.getfoundry.sh/) (`brew install foundry` or `curl -L https://foundry.paradigm.xyz | bash && foundryup`)
- Node 20+ and npm
- Python 3.11+ (for the e2e runner)

### Install + build
```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 --shallow --no-git
forge install foundry-rs/forge-std --shallow --no-git
forge build

# Automated coverage is the live mainnet harness (mock forge tests were retired):
#   python3 -m pip install --user -r scripts/python/requirements.txt
#   ARTIFACT=deployments/mainnet/<strategy>.json OPERATOR_PRIVATE_KEY=0x... \
#   python3 scripts/python/e2e_runner.py --network mainnet
```

### Deploy a strategy
```bash
cp .env.example .env
# Fill in HYPEREVM_RPC_MAINNET, DEPLOYER_PRIVATE_KEY (with 0x prefix)
source .env

# One-time per chain:
forge script script/DeployRegistry.s.sol --rpc-url $HYPEREVM_RPC_MAINNET --broadcast
# Copy printed REGISTRY_MAINNET into .env; `source .env` again

# Per strategy:
cp deployments/configs/example.json deployments/configs/my-strategy.json
# Edit the config — operator/feeRecipient/usdcAddress/leverageCapBps/etc

STRATEGY_CONFIG=deployments/configs/my-strategy.json forge script script/Deploy.s.sol \
    --rpc-url $HYPEREVM_RPC_MAINNET --broadcast --slow
```

After deploy, opt the vault into big-blocks (only needed for emergency fan-out paths):

```bash
python3 -m pip install --user -r scripts/python/requirements.txt
OPERATOR_PRIVATE_KEY=$DEPLOYER_PRIVATE_KEY \
VAULT_ADDRESS=<printed-vault-address> \
NETWORK=mainnet \
python3 scripts/python/optin_big_blocks.py
```

### Run the discovery frontend
```bash
cd frontend
npm install
ln -sf ../deployments deployments
npm run dev
```

Live mainnet verification (deposit / order / fill / cancel / withdraw) runs through `scripts/python/e2e_runner.py` — see [`scripts/python/README.md`](scripts/python/README.md).

---

## Real mainnet findings

The vault was validated end-to-end on HyperEVM mainnet. Several bugs were found and fixed by running against real precompiles and CoreWriter (which mock/fork verification had hidden) — most importantly the px/sz action scale, confirmed by placing a **resting BTC order from the contract path**. No findings remain open.

**Fixed:**
1. **`limit_order` px/sz action scale is `human × 10^8` (uniform), NOT `10^(8−szDecimals)` / `10^szDecimals`** — confirmed on mainnet (an order at the szDecimals-based scale is silently dropped; a `10^8` order rests). The `oraclePx`/`markPx` precompiles return `human × 10^(6−szDecimals)`, so the perp slippage band normalizes oraclePx by `10^(2+szDecimals)` (per-asset `szDecimals` via `perpAssetInfoStrict`), the leverage-cap notional divides by `1e10`, and `hl_helpers.encode_px/encode_sz` use `× 10^8`. (v1.2's "×100" normalization was wrong and dropped every realistic order.)
2. **EIP-170 contract-size limit on the factory.** Inlining `type(HyperCoreVault).creationCode` pushed the factory over 24KB. Worked around by deploying the vault directly from `Deploy.s.sol` via CREATE; the factory remains in the repo for a future EIP-1167 refactor.
3. **`operatorRecoverSpot(to, token, amountWei)` added** so the operator can move Core spot funds out of the vault when no bridge route is usable. **(v1.5 G2 update: the official USDC route exists — Circle's CoreDepositWallet, live since 2025-12-08 — and `pushToCore` now uses it; `operatorRecoverSpot` demotes to a contingency.)** `operatorSweepStranded(to)` added for recovering EVM `asset()` balance after `totalSupply` returns to zero.

**Resolved (v1.3) — was "HL Core does not process `limit_order` from contracts":**
- **Root cause was the px/sz SCALE (item 1 above), confirmed on mainnet** — not an HL/contract limitation, and not (primarily) TIF. Decisive test, all `tif=1` via raw `CoreWriter.sendRawAction`: a `10^8`-scale BTC order **rested on the book** (`limitPx 72596.0, sz 0.0002`); the same order at the repo's `10^(8−szDecimals)`/`10^szDecimals` scale was **silently dropped**; and a perfectly-`tif=1`-encoded but wrong-scale order also dropped. The TIF enum was *also* off by one (`TIF_ALO=0…`; correct `1/2/3`) and is fixed — real but secondary (tif=0 still drops once scale is right). **Deployed v1.2 vaults bake in BOTH the wrong scale (band/cap math) and the wrong TIF, so they cannot place orders and must be redeployed** (this also fixes `emergencyClosePositions`, which encoded IOC as GTC).

Documented in full in [`docs/SECURITY.md`](docs/SECURITY.md) under "Lessons from mainnet testing (v1.2)".

### Vault tiers

The repo ships three strategy configs — `tier1`, `tier2`, `tier2b` (`deployments/configs/mainnet-tier*.json`). **They are currently identical in every risk parameter** and differ only by name/symbol and deployed instance (separate vault + timelock addresses). Tiering is scaffolding for future differentiation — not yet differentiated.

| Parameter | tier1 | tier2 | tier2b |
|---|---|---|---|
| Name / symbol | Allora Mainnet Tier1 / `amt1` | Allora Mainnet Tier2 / `amt2` | Allora Mainnet Tier2b / `amt2b` |
| Leverage cap | 3× (30000 bps) | 3× | 3× |
| Slippage band | 2% (200 bps) | 2% | 2% |
| Perf / mgmt fee | 15% / 2%-yr | 15% / 2%-yr | 15% / 2%-yr |
| Deposit cap / per-address | $100 / $100 | $100 / $100 | $100 / $100 |
| Whitelisted markets | BTC perp (id 0) | BTC perp (id 0) | BTC perp (id 0) |
| Quote (USDC) | `0xb883…630f` | `0xb883…630f` | `0xb883…630f` |
| Timelock min delay | 0s | 0s | 0s |

> To make the tiers mean something different, edit the per-tier config and redeploy. A natural scheme: **tier1** conservative (lower cap, BTC only), **tier2** standard, **tier2b** higher cap / more markets.

### Deployed instances (pre-v1.3 — superseded, pending redeploy)

Deployed before the v1.3 px/sz-scale + TIF fixes, so they **cannot place orders** (wrong action scale + TIF inlined in bytecode). Redeploy with the current code via `Deploy.s.sol`, then refresh these addresses.

| | Vault (pre-v1.3) | Timelock |
|---|---|---|
| tier1 | [`0x1DDC…5B1a`](https://hyperevmscan.io/address/0x1DDC8A2478157da455D7AafE7486CD674f7E5B1a) | `0x4bf3037EB1b5b87fD37d99FAD6579fe22049e906` |
| tier2 | [`0xdc51…34aE`](https://hyperevmscan.io/address/0xdc5196C7d841b2C3C6E935dE04383Fb40b8534aE) | `0x11BfF9278097f31448f3F9973FEbec61eEf6E27A` |
| tier2b | [`0xC439…02f5`](https://hyperevmscan.io/address/0xC43997299722A3896ddBA28730a7ff2A6A6B02f5) | `0x190d0c65182300B9b1C7F1FDD514c6cA3D9CCe5A` |
| Registry | [`0xA430…0ba8`](https://hyperevmscan.io/address/0xA430c24f63BB3245723242c7843b2E07BA220ba8) | — |
| USDC (quote) | `0xb88339CB7199b77E23DB6E890353E22632Ba630f` | — |

The v1.3 fixes were confirmed on a throwaway test vault that placed a **resting BTC order via the contract path** (then cancelled, funds recovered); see [`docs/SECURITY.md`](docs/SECURITY.md).

---

## Known limitations and v1.1 follow-ups

- **EIP-1167 minimal-proxy refactor** to restore the CREATE2 factory and keep the per-vault deploy under EIP-170
- **Multi-quote vault support** (current: USDC-only)
- **Subaccount support** (current: one Core account per vault, derived from EVM address)
- **Sweep stranded asset** is operator-gated; consider moving to `EMERGENCY_ROLE` for production
- **Operator NAV override** for edge cases where precompiles return wrong values

---

## Docs

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — design rationale, NAV math, fee accounting
- [`docs/INTEGRATION.md`](docs/INTEGRATION.md) — live-runner integration, event-to-SDK-field mapping, runbook
- [`docs/SECURITY.md`](docs/SECURITY.md) — threat model, role matrix, audit checklist, mainnet findings
- [`scripts/python/README.md`](scripts/python/README.md) — Python helpers + live mainnet test harness

## License

MIT

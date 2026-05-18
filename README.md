# HyperVault

**EIP-4626 vault template for HyperEVM**, with on-chain NAV via HyperCore precompiles and trade execution via the CoreWriter system contract. Replaces Hyperliquid's legacy native vaults (10,000 USDC creation fee, perps-only) with a gas-only Solidity contract that supports spot, perps, and HIP-3 markets in any quote.

Validated end-to-end on **HyperEVM mainnet** (chain 999) — see [the mainnet findings](#real-mainnet-findings) below for what worked, what didn't, and the v1.2 fixes that shipped from that exercise.

---

## What this gives you

- **Audit-ready ERC-4626 vault** (`src/HyperCoreVault.sol`) — operator/emergency/admin roles, asset whitelist, leverage cap, slippage band, management + performance fees, withdrawal queue, cost-basis tracking
- **Per-strategy deploy pipeline** — JSON config in, on-chain vault + per-vault `TimelockController` + auto-registered entry out
- **Discovery frontend** — Vite + React + viem; auto-discovers every vault from `deployments/<chain>/*.json` artifacts at build time
- **Python e2e runner** — drives `deposit → push → spot→perp → place → cancel → perp→spot → pull → redeem` against the live HL API
- **51 forge tests** — unit, integration (against mocked precompiles + CoreWriter), CoreWriter encoding bit-exactness, fee math, withdrawal queue, leverage/slippage gates

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
  DeployMockUSDC.s.sol        For testnet / fork where real USDC isn't available
  Deploy.s.sol                Per-strategy from JSON config; deploys timelock + vault + seeds whitelist

test/                         51 tests across 8 suites
  unit/                       Vault, fees, withdrawal queue, CoreWriter encoding bit-exactness, etc.
  integration/                Full lifecycle via mocked precompiles + CoreWriter (CoreSimulator-style)
  mocks/                      MockCoreWriter, MockPrecompiles, MockUSDC

scripts/python/               Python orchestration (HL SDK + web3.py)
  e2e_runner.py               Drives full lifecycle on testnet/mainnet with HL API cross-checks
  optin_big_blocks.py         Toggles HyperEVM big-blocks via HL API (needed for vault deploy)
  seed_vault_core.py          Sends Core USDC from your account to a vault's Core address
  seed_whitelist.py           Post-deploy whitelist updates through the timelock

deployments/                  Strategy configs (input) + deploy artifacts (output)
  configs/                    Per-strategy JSON parameter files
  mainnet/                    Per-strategy deploy artifacts written by Deploy.s.sol
  testnet/

docs/                         Architecture, integration, security, testnet runbook
  ARCHITECTURE.md             Design rationale + diagrams
  INTEGRATION.md              Live runner integration guide (event → SDK field mapping, runbook)
  SECURITY.md                 Threat model, role/permission matrix, audit checklist, mainnet findings
  TESTNET.md                  Step-by-step testnet walkthrough

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
- `pushToCore / pullFromCore` — operator-only EVM↔Core USDC bridging (where the bridge is linked)
- `operatorRecoverSpot(to, token, amountWei)` — operator-only generic Core spot send; the fallback when `pullFromCore`'s bridge path isn't available
- `usdSpotToPerp / usdPerpToSpot` — operator-only USD class transfers
- `operatorSweepStranded(to)` — recovers EVM `asset()` balance when `totalSupply == 0` (the donation-to-empty-vault recovery)
- `emergencyCancelByCloid / emergencyCancelByOid / emergencyClosePositions / emergencyShutdown / pause / unpause` — emergency-role only
- `setWhitelistPerp / setWhitelistSpot / setLeverageCap / setSlippageBand / setFees / setDepositCap / sweep` — admin (timelock) only
- `nav / pricePerShare / idleUsdc / coreSpotUsdc / perpWithdrawable` — public view helpers, all backed by precompile reads

**`HyperCoreVaultRegistry.sol`** — on-chain directory. The frontend reads from `deployments/*/*.json` directly (no chain call needed for discovery), but the registry remains the canonical on-chain source. Owner OR factory can write.

**`HyperCoreVaultFactory.sol`** — currently **bypassed** in the deploy script. The factory's runtime bytecode (which inlines `type(HyperCoreVault).creationCode`) is 30KB+, over the EIP-170 24KB limit. `Deploy.s.sol` constructs the vault via plain CREATE from the script instead. A v1.1 refactor to a minimal-proxy (EIP-1167 Clones) pattern would restore the factory.

### Libraries

**`CoreWriterLib`** — wraps the CoreWriter system contract (`0x3333…3333`). Each typed function packs `abi.encodePacked(uint8(1), uint24(actionId), abi.encode(args))` and calls `sendRawAction`. The action set: `limit_order`, `cancel_order_by_oid`, `cancel_order_by_cloid`, `spot_send`, `usd_class_transfer`, `vault_transfer`. Bit-exact encoding is verified by golden-vector tests in `test/unit/CoreWriterLib.t.sol`.

**`PrecompileLib`** — typed `staticcall` wrappers for every L1 read precompile (`0x0800–0x0810`). Returns the protocol's struct; falls back to zero-initialised struct if the precompile errors (e.g., the account has never touched that market). Used by the vault for `totalAssets` (NAV = idle + coreSpot + perpWithdrawable) and by the operator gates (oraclePx for slippage, position/markPx for leverage).

**`Constants`, `AssetId`, `SystemAddress`** — small pure helpers. `AssetId` encodes perp/spot IDs (spot = 10_000 + spotIdx). `SystemAddress` derives the per-token bridge address (`0x20 || zero-pad || tokenIdx_BE`).

### Deploy scripts

`forge script script/DeployRegistry.s.sol --rpc-url <RPC> --broadcast` — one-time per chain.

`STRATEGY_CONFIG=deployments/configs/<name>.json forge script script/Deploy.s.sol --rpc-url <RPC> --broadcast` — per strategy. Reads JSON config → deploys per-vault TimelockController → deploys vault via CREATE → registers in registry → seeds whitelist via `scheduleBatch + executeBatch` (when `timelockMinDelaySec == 0`). Writes a typed artifact JSON to `deployments/<chain>/<name>.json` that the frontend auto-discovers.

### Python helpers

`scripts/python/e2e_runner.py` — drives the full vault lifecycle on testnet/mainnet with HL API cross-checks at every step. Step-selectable via `--steps`, `--skip-bridge` mode for environments without a working EVM↔Core USDC bridge.

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

### Install + test
```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 --shallow --no-git
forge install foundry-rs/forge-std --shallow --no-git
forge build
forge test                 # 51 tests
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

Full step-by-step (including faucets, big-blocks toggle, e2e runner) lives in [`docs/TESTNET.md`](docs/TESTNET.md).

---

## Real mainnet findings

The vault was validated end-to-end on HyperEVM mainnet. Three concrete bugs were found and fixed by running against real precompiles and CoreWriter (which our anvil-fork verification had hidden). One issue remains open and worth flagging before production use.

**Fixed:**
1. **`oraclePx` / `markPx` precompiles use `human × 10^(6−szDecimals)` scale**, not the `10^(8−szDecimals)` scale that the `limit_order` CoreWriter action uses. A 100× mismatch in the slippage and leverage gates was breaking every realistic order. Fixed by normalizing oraclePx by 100 in the slippage band check and adjusting the leverage notional formula. Test mocks updated for the corrected scale.
2. **EIP-170 contract-size limit on the factory.** Inlining `type(HyperCoreVault).creationCode` pushed the factory over 24KB. Worked around by deploying the vault directly from `Deploy.s.sol` via CREATE; the factory remains in the repo for a future EIP-1167 refactor.
3. **`operatorRecoverSpot(to, token, amountWei)` added** so the operator can move Core spot funds out of the vault when the EVM↔Core bridge for the chosen asset isn't deployed (the current mainnet state for USDC). `operatorSweepStranded(to)` added for recovering EVM `asset()` balance after `totalSupply` returns to zero.

**Open finding:**
- **HL Core does not appear to process `limit_order` actions submitted via CoreWriter from a contract account.** Other actions (`spot_send`, `usd_class_transfer`, `send_asset`) work correctly for vault contracts — funds move, ledger entries appear. But `placeLimitOrder` produces zero entries in HL's `historicalOrders`, regardless of TIF (0/1/2/3 all tested) or order size (`$0.76` and `$12+` both attempted). The CoreWriter event fires on EVM, but HL Core is silent. Possible causes: requires `setLeverage` initialization (no CoreWriter wrapper exists for it), requires `add_api_wallet` delegation, or requires `user_set_abstraction` mode setup. Needs HL team input or further protocol research.

Documented in full in [`docs/SECURITY.md`](docs/SECURITY.md) under "Lessons from mainnet testing (v1.2)".

### Deployed addresses (mainnet, for reference)

| What | Address |
|---|---|
| HyperCoreVaultRegistry | [`0xA430c24f63BB3245723242c7843b2E07BA220ba8`](https://hyperevmscan.io/address/0xA430c24f63BB3245723242c7843b2E07BA220ba8) |
| Tier 1 vault (v1.0) | [`0x1DDC8A2478157da455D7AafE7486CD674f7E5B1a`](https://hyperevmscan.io/address/0x1DDC8A2478157da455D7AafE7486CD674f7E5B1a) |
| Tier 2 vault (v1.1, +recoverSpot) | [`0xdc5196C7d841b2C3C6E935dE04383Fb40b8534aE`](https://hyperevmscan.io/address/0xdc5196C7d841b2C3C6E935dE04383Fb40b8534aE) |
| Tier 2b vault (v1.2, +slippage scale fix) | [`0xC43997299722A3896ddBA28730a7ff2A6A6B02f5`](https://hyperevmscan.io/address/0xC43997299722A3896ddBA28730a7ff2A6A6B02f5) |
| Mainnet USDC (Circle, bridged from Arbitrum) | `0xb88339CB7199b77E23DB6E890353E22632Ba630f` |

Total mainnet spend across the full validation exercise: ~0.011 HYPE (~$0.50) in gas + 1 USDC HL transfer fee + 1.5 USDC stranded in the Tier 2b vault (donation-trap demonstration, recoverable via `operatorSweepStranded` if redeployed).

---

## Known limitations and v1.1 follow-ups

- **EIP-1167 minimal-proxy refactor** to restore the CREATE2 factory and keep the per-vault deploy under EIP-170
- **`setLeverage` CoreWriter wrapper** or `add_api_wallet` flow to unblock perp order placement from contract accounts
- **Multi-quote vault support** (current: USDC-only)
- **Subaccount support** (current: one Core account per vault, derived from EVM address)
- **Sweep stranded asset** is operator-gated; consider moving to `EMERGENCY_ROLE` for production
- **Operator NAV override** for edge cases where precompiles return wrong values

---

## Docs

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — design rationale, NAV math, fee accounting
- [`docs/INTEGRATION.md`](docs/INTEGRATION.md) — live-runner integration, event-to-SDK-field mapping, runbook
- [`docs/SECURITY.md`](docs/SECURITY.md) — threat model, role matrix, audit checklist, mainnet findings
- [`docs/TESTNET.md`](docs/TESTNET.md) — step-by-step testnet walkthrough
- [`scripts/python/README.md`](scripts/python/README.md) — Python helper usage

## License

MIT

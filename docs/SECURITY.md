# Security Notes (Audit Prep)

## Threat model

| Adversary | Capability | Mitigation |
|---|---|---|
| Random EOA | Can call any external function | Role gating on every state-changing function. `DEFAULT_ADMIN_ROLE` mutations time-locked. |
| Depositor | Has ERC4626 share token, can call `redeem` / `requestWithdraw` | `maxWithdraw` correctly capped by idle USDC. Inflation defense via OZ virtual-shares + 6 decimal offset. |
| Operator (compromised key) | Can place orders, bridge funds, transfer USD class | Asset whitelist (admin/timelock), slippage band vs oracle px, leverage cap on incremental notional, **cannot** withdraw to self, **cannot** change fees |
| Emergency admin (compromised key) | Can pause, cancel-all, close-positions, emergencyShutdown | Cannot move funds to self. Worst case: vault locked for redeems and operator-trade halted. Recoverable by admin (timelock) granting/revoking roles. |
| Admin (compromised) | Can change any guardrail, sweep non-asset tokens, grant/revoke roles | 24-hour `TimelockController` delay gives LPs time to redeem before malicious change takes effect. |
| HyperCore protocol bug | Mismarks `withdrawable`, returns stale precompile data | NAV uses HL's own conservative `withdrawable` (not `accountValue`) — protocol invariants apply. If HL is compromised, the vault is compromised. |

## Role / function matrix

| Function | Caller | Notes |
|---|---|---|
| `deposit`, `mint` | anyone | `whenNotPaused`, blocked under `emergencyShutdownActive` |
| `withdraw`, `redeem` | anyone | Never blocked — even when paused |
| `requestWithdraw`, `cancelWithdrawRequest`, `fulfillWithdraw` | anyone | `fulfillWithdraw` is keeper-friendly |
| `placeLimitOrder` | `OPERATOR_ROLE` | `whenNotPaused`, whitelist + slippage + leverage gates |
| `cancelOrderByCloid` | `OPERATOR_ROLE` | No gates |
| `pushToCore`, `pullFromCore` | `OPERATOR_ROLE` | `whenNotPaused` |
| `usdSpotToPerp`, `usdPerpToSpot` | `OPERATOR_ROLE` | `whenNotPaused` |
| `pause`, `unpause` | `EMERGENCY_ROLE` | |
| `emergencyCancelByCloid`, `emergencyCancelByOid`, `emergencyClosePositions` | `EMERGENCY_ROLE` | |
| `emergencyShutdown` | `EMERGENCY_ROLE` | One-way; deposits permanently blocked |
| `setWhitelist*`, `setLeverageCap`, `setSlippageBand`, `setFees`, `setDepositCap`, `setMaxDepositPerAddress` | `DEFAULT_ADMIN_ROLE` (timelock) | 24h delay in production |
| `sweep` | `DEFAULT_ADMIN_ROLE` | Cannot sweep `asset()` |
| `grantRole`, `revokeRole` | `DEFAULT_ADMIN_ROLE` | Standard OZ AccessControl |

## Lessons from mainnet testing (v1.2)

These are real bugs / footguns surfaced by running the vault end-to-end on Hyperliquid mainnet, not theoretical concerns.

- **The "donation to empty vault" trap.** If anyone bridges or `spot_send`s the vault asset (USDC) to the vault address *before* the first ERC4626 deposit, OZ's virtual-shares formula leaves those funds permanently stranded — they boost NAV per-share but no LP can claim them since `totalSupply == 0`. We hit this on mainnet when we manually funded the vault's Core account before depositing on EVM. **Mitigations**: (a) ALWAYS seed the vault with a deployer "lock-in" deposit before opening to LPs; (b) v1.2 ships `operatorSweepStranded(to)` that lets the operator recover EVM `asset()` balance when `totalSupply == 0`.

- **Precompile scale ≠ action scale (100×).** `oraclePx`/`markPx` precompiles return prices in `human * 10^(6 - szDecimals)`, but the `limit_order` CoreWriter action takes price in `human * 10^(8 - szDecimals)`. The slippage band and leverage cap gates were both initially comparing these on the same scale and breaking under any realistic price. v1.2 normalizes (multiply oraclePx by 100) before comparing. Tests now use realistic 6-dec-scale oracle values.

- **Place ≠ accept (silently).** Confirmed on mainnet: an order rejected by HL Core (e.g. for being below the $10 minimum) leaves no trace — the EVM tx succeeds, the CoreWriter event fires, and the order simply never appears in `open_orders` or `historicalOrders` on the HL API. Reconcilers MUST query HL post-submission to confirm acceptance.

- **HL Core does not appear to process `limit_order` actions from contract accounts** (open as of v1.2 mainnet testing). Other CoreWriter actions (`spot_send`, `usd_class_transfer`) work correctly for vault contracts — money moves, ledger entries appear. But `placeLimitOrder` produces zero entries in `historicalOrders` regardless of TIF value (0/1/2/3 all tested). Possibilities being investigated: requires a `setLeverage` action first (no CoreWriter wrapper); requires `add_api_wallet` delegation; or requires explicit `user_set_abstraction` mode. **Status**: open finding — needs HL team input. Operators should validate order placement on testnet (when bridge linkage works there) or via an alternative trading channel (deployer-as-API-wallet) until resolved.

- **Unified-account-only `send_asset` path.** Personal HL accounts in "unifiedAccount" mode have `spot_transfer` / `usd_class_transfer` / `usd_transfer` disabled. The working call is `Exchange.send_asset(dest, "spot", "spot", "USDC", amount)` (1 USDC fee) for spot-to-spot, or `send_asset(dest, "spot", "", "USDC", amount)` (no fee) to route into the recipient's perp account directly. Documented in `docs/INTEGRATION.md`.

## Known limitations & audit focus

- **Leverage cap is best-effort, not strict.** It checks the incremental notional of a new order plus current open-position notional (read from precompiles). It does not account for HL's own margin requirements per-asset, cross-margin offsets, or resting orders not yet filled. An operator can split orders to circumvent. Treat as a guideline, not a hard guarantee. Pair with off-chain monitoring.

- **Slippage band uses `oraclePrice` precompile.** HL's oracle is a median across multiple venues and is robust to single-venue manipulation. Still, if HL's oracle infra is degraded, the band can pass a bad order.

- **Place ≠ accept ≠ fill.** Every order-related event fires on EVM tx success, not on HL acceptance. Reconciliation MUST verify via HL API post-submission (see `docs/INTEGRATION.md`).

- **CoreWriter is fire-and-forget.** A rejected action does not revert the EVM tx. The vault's view of "outstanding orders" relies entirely on off-chain reconciliation.

- **Decimals.** USDC EVM 6dp; USDC Core 8dp; bridge scales ×100 across. If HL ever changes Core USDC `weiDecimals`, update `Constants.USDC_CORE_DECIMALS`. The factory's `strictAssetValidation` mode catches asset address mismatches but does NOT catch decimal mismatches — add at audit time.

- **`receive()` is omitted.** Native HYPE sent to the vault address reverts. Intentional.

- **Cost basis carry on transfer.** ERC20 share transfers weighted-average the receiver's cost basis. Senders keep their cost basis on remaining shares. The vault address (when shares are escrowed via `requestWithdraw`) is excluded from cost-basis tracking; the request stores its own snapshot.

- **Fee dilution math.** The dilutive-mint formula `feeAssets * supply / (nav - feeAssets)` is exact in continuous math and approximate under integer rounding. Off-by-one errors favor existing holders (under-charge by ≤ 1 wei).

## Static analysis

```bash
slither src/HyperCoreVault.sol --filter-paths "lib/"
mythril analyze src/HyperCoreVault.sol --solv 0.8.27
```

## Audit checklist

- [ ] OZ ERC4626 inflation-attack mitigation verified at all entry points
- [ ] `_update` cost-basis carry preserves invariant: sum-of-LP-cost-bases-weighted = totalSupply * avgCostBasis
- [ ] Dilutive fee mint cannot overflow when `nav ≈ feeAssets` (sanity cap in `_accrueMgmtFee`)
- [ ] Decimal normalization paths (`_coreToEvm`) are bidirectionally consistent for USDC
- [ ] CoreWriter action encoding matches Hyperliquid's reference (golden vectors in `test/unit/CoreWriterLib.t.sol`)
- [ ] Precompile struct decoding matches the protocol version deployed at the time of audit (regress against hyper-evm-lib's `PrecompileLib.sol` per a pinned commit)
- [ ] Reentrancy on the operator surface (CoreWriter is fire-and-forget; precompiles are staticcall — verify)
- [ ] No path lets EMERGENCY_ROLE drain funds
- [ ] No path lets a deposit at time T receive shares priced at T-1 NAV (snapshot-then-mint pattern)
- [ ] Withdrawal queue cannot double-spend or strand escrowed shares
- [ ] Factory CREATE2 salt collision impossible for distinct deployers

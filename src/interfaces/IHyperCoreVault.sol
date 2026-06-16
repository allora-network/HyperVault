// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice Public ABI for HyperCoreVault — the events and external functions
///         the live-runner, indexers, and the frontend need to integrate with.
/// @dev    Mirrors the implementation in `src/HyperCoreVault.sol`. Implementing
///         contracts inherit `IERC4626` separately to keep the surface explicit.
interface IHyperCoreVault is IERC4626 {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error AssetNotWhitelisted(uint32 asset);
    error SlippageBandExceeded(uint64 limitPx, uint64 oraclePx, uint16 bandBps);
    error LeverageCapExceeded(uint256 grossNotional, uint256 nav, uint16 capBps);
    error DepositCapExceeded(uint256 requested, uint256 cap);
    error PerAddressCapExceeded(uint256 requested, uint256 cap);
    error WithdrawExceedsIdleBalance(uint256 requested, uint256 idle);
    error EmergencyShutdownActive();
    error ZeroAddress();
    error InvalidFeeConfig(uint16 mgmtBps, uint16 perfBps);
    error SweepingAsset();
    error StrandedSweepRequiresZeroSupply();
    /// @notice `operatorRecoverSpot` destination is not on the admin allowlist (audit C-2).
    error SpotRecoverDestinationNotAllowed(address dest);
    /// @notice Configured Core-USDC decimals disagree with the live `tokenInfo`
    ///         precompile at deploy (audit C1/M5) — NAV would be off by 10^|Δ|.
    error CoreUsdcDecimalsMismatch(uint8 configured, uint8 fromPrecompile);
    /// @notice The configured CoreDepositWallet custodies a different token than
    ///         the vault's `asset()` (audit G2) — deposits would feed someone
    ///         else's bridge. Checked directly against the wallet at deploy.
    error CoreDepositWalletTokenMismatch(address asset, address walletToken);
    /// @notice The configured CoreDepositWallet's `tokenSystemAddress()` is not
    ///         the system address derived from `coreUsdcIndex` (audit G2) — the
    ///         wallet and the NAV/pull leg would point at different Core tokens.
    error CoreDepositWalletSystemAddressMismatch(address expected, address actual);
    /// @notice `tokenInfo(coreUsdcIndex).evmContract` resolved to something other
    ///         than the configured CoreDepositWallet (audit G2). Push and pull
    ///         would route through different contracts — fail closed.
    error CoreLinkMismatch(address wallet, address coreEvmContract);
    /// @notice {endNavBootstrap} called when the grace period is already over —
    ///         the transition to strict NAV reads is one-way (audit H-1).
    error NavBootstrapAlreadyEnded();
    /// @notice {prioritizeOverdue} called for an LP with no pending request (H2).
    error NoPendingRequest(address lp);
    /// @notice {prioritizeOverdue} called before the request's deadline lapses (H2).
    error RequestNotOverdue(address lp);
    /// @notice {prioritizeOverdue} called on an already-prioritized request (H2).
    error RequestAlreadyPrioritized(address lp);
    /// @notice deposit/mint into an LP (`receiver`) that has an open withdrawal
    ///         request — would corrupt the per-LP cost basis (audit M2). The LP
    ///         must {cancelWithdrawRequest} first.
    error PendingRequestBlocksDeposit(address receiver);
    /// @notice emergency-close `limitPx` deviates from the strict markPx beyond
    ///         `emergencyCloseBandBps` (audit M4). Use {emergencyClosePositionsForce}
    ///         only if the oracle itself is unusable.
    error EmergencyCloseBandExceeded(uint64 limitPx, uint64 markPx, uint16 bandBps);
    /// @notice A non-zero spot slippage band requires a calibrated, non-zero
    ///         `spotPxScaleFactor` (audit M6) — else the band gives false protection.
    error SpotBandRequiresScaleFactor(uint32 asset);
    /// @notice The vault received less than `expected` on deposit/mint (audit L1) —
    ///         the asset must be USDC-class (non-fee-on-transfer, non-rebasing).
    error DepositAmountNotReceived(uint256 expected, uint256 received);
    /// @notice A deposit/mint or market-deploying mover was attempted while the
    ///         vault is latched into ESCAPE mode (M5 — escape hatch §4). Entering a
    ///         forced unwind is wrong-way risk for a depositor; deploy paths are off.
    error EscapeModeActive();
    /// @notice An escape crank was called while the vault is NOT in ESCAPE mode
    ///         (M5 §4) — the cranks only run while the brake is armed.
    error EscapeModeNotActive();
    /// @notice An escape crank was called before the per-interval cooldown elapsed
    ///         (M5 §4) — bounds HyperCore action-rate exposure / forced-unwind grief.
    error EscapeCooldownActive(uint64 nextAllowedTs);
    /// @notice {exitEscape} called while an overdue-unfillable request still remains
    ///         (M5 §1) — the brake clears only once the backlog that armed it is gone.
    error EscapeBacklogRemains(address lp);
    /// @notice A cloid passed to {escapeCancelOrders} is not one the vault has issued
    ///         (>= the live `_cloidCounter`), so it cannot name a vault-placed resting
    ///         order (M5 §2 leg 1).
    error EscapeCloidOutOfRange(uint128 cloid, uint128 cloidCounter);
    /// @notice {triggerEscape} called for an `lp` whose request does NOT meet the
    ///         permissionless staleness gate (M5 §1, SOLU-3371): either there is no
    ///         escrowed request, the request has no SLA deadline (`fulfillmentDeadline
    ///         == 0` — a vault with no {requestFulfillmentWindow} has no armable
    ///         brake), the request is not yet overdue by `escapeGraceSeconds` BEYOND
    ///         its deadline, or its remaining claim does not exceed {availableIdleUsdc}
    ///         (an honored/honorable request can never arm the brake). Replaces the
    ///         interim {EscapeTriggerNotWired} placeholder.
    error EscapeConditionNotMet(address lp);
    /// @notice {setEscapeGraceSeconds} called with a value outside the compile-time
    ///         hard bounds [`ESCAPE_GRACE_MIN`, `ESCAPE_GRACE_MAX`] (M5 §1, SOLU-3371).
    ///         The bounds are constants so the timelock cannot quietly disable the
    ///         permissionless brake (set it absurdly long) nor make it hair-trigger
    ///         (set it ~0) — fail-closed, matching the repo's posture.
    error EscapeGraceOutOfRange(uint64 lo, uint64 hi);

    // -------------------------------------------------------------------------
    // Shared structs
    // -------------------------------------------------------------------------

    /// @notice One pending withdrawal request per LP (audit H2). Declared on the
    ///         interface so the vault and {VaultEscapeLib} share ONE struct type
    ///         across the M5 delegatecall boundary (the queue mapping is threaded
    ///         into the library by storage reference — same single-source-of-truth
    ///         posture as the `EnumerableSet.UintSet`s shared with {VaultTradeLib}).
    struct WithdrawalRequest {
        uint256 shares; // shares escrowed at the vault
        uint256 costBasisAtRequest; // 1e18-fixed snapshot of LP's cb at request time
        uint64 fulfillmentDeadline; // 0 = no SLA; else unix ts after which the request is overdue (H2)
        uint256 reservedAssets; // idle assets reserved for this overdue request (H2 priority over redeem)
    }

    /// @notice Escape-hatch latch + cooldown state (M5 §1/§4). Declared on the
    ///         interface so the vault and {VaultEscapeLib} share ONE struct type:
    ///         the vault threads it into the library by storage reference
    ///         (delegatecall: same slots), so the latch/cooldown bookkeeping AND the
    ///         crank loops both live in the library, out of the vault's EIP-170
    ///         budget. `active` is the ESCAPE-mode latch the deposit/trade gates read;
    ///         `lastCrankTs` backs the per-interval crank cooldown.
    struct EscapeState {
        bool active;
        uint64 lastCrankTs;
        /// @dev Permissionless-trigger grace window (M5 §1, SOLU-3371): seconds a
        ///      request must stay overdue BEYOND its SLA deadline before
        ///      {triggerEscape} arms the brake. Held INSIDE the escape struct (not a
        ///      standalone vault slot) so {VaultEscapeLib} reads/writes it by the same
        ///      storage reference it already threads — the governance setter
        ///      ({setEscapeGraceSeconds} -> {VaultEscapeLib.setGrace}) and the trigger
        ///      gate ({triggerIfStale}) both live in the library, out of the vault's
        ///      EIP-170 budget. Default 8h; bounded [4h, 30d] (the library constants).
        uint64 graceSeconds;
    }

    // -------------------------------------------------------------------------
    // CoreWriter submission events — these mirror what the legacy SDK response
    // gives the live-runner so the reconciliation step can port cleanly.
    //
    // IMPORTANT: "Submitted" means the EVM tx succeeded and the CoreWriter
    // event fired. It does NOT mean HyperCore accepted or filled the action.
    // Reconcilers should treat these as intents and confirm via L1 reads.
    // -------------------------------------------------------------------------

    event LimitOrderSubmitted(
        uint32 indexed asset,
        bool isBuy,
        uint64 limitPx,
        uint64 sz,
        bool reduceOnly,
        uint8 tif,
        uint128 indexed cloid,
        uint256 navSnapshot
    );

    event OrderCancelByCloidSubmitted(uint32 indexed asset, uint128 indexed cloid);
    event OrderCancelByOidSubmitted(uint32 indexed asset, uint64 indexed oid);
    event UsdClassTransferSubmitted(uint64 ntl, bool toPerp);
    /// @notice EVM USDC -> Core spot. Wallet mode: `approve + deposit` on the
    ///         CoreDepositWallet (the ERC20 `Transfer` goes to the wallet, not
    ///         the system address). Legacy mode: ERC20 transfer to the system
    ///         address. Route is fixed per-vault via {coreDepositWallet} (G2).
    event BridgeDeposit(uint64 amount);
    event BridgeWithdraw(uint64 amountWei); // Core spot -> EVM USDC (via system address)
    event OperatorSpotRecovered(address indexed to, uint64 token, uint64 amountWei); // Core spot -> arbitrary recipient
    event StrandedSwept(address indexed to, uint256 amount); // EVM asset sweep when totalSupply==0

    /// @notice Periodic NAV snapshot, emitted whenever fees accrue.
    event NavSnapshot(
        uint256 totalAssets,
        uint256 totalSupply,
        uint256 idleUsdc,
        uint256 coreSpotUsdc,
        uint256 perpEquity,
        uint256 timestamp
    );

    event MgmtFeeAccrued(uint256 shares, uint256 navAtAccrual);
    /// @notice Performance fee paid directly to `feeRecipient` in `asset()` terms,
    ///         deducted from the exiting LP's payout. Replaces the v1.x
    ///         `PerfFeeCrystallized` (which minted fee shares and silently
    ///         diluted other LPs — audit finding C-3).
    event PerfFeePaid(address indexed lp, uint256 feeAssets);

    event WithdrawalRequested(address indexed lp, uint256 shares);
    event WithdrawalFulfilled(address indexed lp, uint256 assets);
    /// @notice A withdrawal request was stamped with a fulfillment SLA deadline (H2).
    event WithdrawalDeadlineSet(address indexed lp, uint64 deadline);
    /// @notice An overdue request reserved `reservedAssets` of idle ahead of racing
    ///         direct redeems (audit H2 / Finding F). Surfaces an operator stall.
    event WithdrawalPrioritized(address indexed lp, uint256 reservedAssets, uint64 deadline);
    /// @notice Admin updated the withdrawal-request fulfillment SLA window (H2).
    event RequestFulfillmentWindowUpdated(uint64 window);
    /// @notice EMERGENCY_ROLE repatriated Core funds toward idle when the operator
    ///         is dark/compromised (audit H2). Works while paused.
    event EmergencyRepatriated(address indexed to, uint64 perpToSpotNtl, uint64 spotSendWei);

    /// @notice The permissionless escape-hatch brake latched ON (M5 §1) — the vault
    ///         entered ESCAPE mode: deposits/mints and market-deploying movers are
    ///         blocked, only the risk-reducing escape cranks + redemption run. `lp`
    ///         is the request that armed the brake (or `address(0)` for an admin arm).
    event EscapeActivated(address indexed by, address indexed lp);
    /// @notice The escape brake cleared (M5 §1) — ESCAPE mode lifted once no
    ///         overdue-unfillable request remained.
    event EscapeDeactivated(address indexed by);
    /// @notice An escape crank (leg 1 cancel / leg 2 flatten / leg 3 consolidate)
    ///         ran while latched (M5 §2) — surfaces the permissionless unwind on-chain.
    event EscapeCrankRun(address indexed by, uint8 indexed leg);
    /// @notice Admin updated the permissionless-trigger grace window (M5 §1,
    ///         SOLU-3371). `newGrace` is the seconds a request must stay overdue
    ///         BEYOND its SLA deadline before the brake is armable; always within the
    ///         compile-time hard bounds [`ESCAPE_GRACE_MIN`, `ESCAPE_GRACE_MAX`].
    event EscapeGraceSecondsUpdated(uint64 newGrace);

    event LeverageCapUpdated(uint16 oldCap, uint16 newCap);
    event SlippageBandUpdated(uint16 oldBand, uint16 newBand);
    event FeesUpdated(uint16 mgmtBps, uint16 perfBps);
    event WhitelistUpdated(uint32 indexed asset, bool isPerp, bool enabled);
    event DepositCapUpdated(uint256 oldCap, uint256 newCap);
    event PerAddressCapUpdated(uint256 oldCap, uint256 newCap);
    event EmergencyShutdownTriggered(address indexed by);
    /// @notice Admin (un)allowlisted a destination for `operatorRecoverSpot` (audit C-2).
    event SpotRecoverDestUpdated(address indexed dest, bool allowed);
    /// @notice Admin ended the fresh-vault NAV grace period; NAV reads are now
    ///         strict / fail-closed (audit H-1). One-way.
    event NavBootstrapEnded(address indexed by);
    /// @notice Admin set the spot slippage band + calibrated scale factor for
    ///         `asset` (audit H-3 / M6).
    event SpotSlippageBandUpdated(uint32 indexed asset, uint16 bps, uint64 scaleFactor);
    /// @notice Admin updated the emergency-close sanity band (audit M4).
    event EmergencyCloseBandUpdated(uint16 oldBps, uint16 newBps);
    /// @notice LEGACY MODE ONLY (no CoreDepositWallet configured): emitted at
    ///         deploy when the Core-USDC token's linked EVM contract
    ///         (`tokenInfo(coreUsdcIndex).evmContract`) is NOT the vault's
    ///         `asset()` (audit C1). Not fatal — the pre-G2 Path-B posture keeps
    ///         the unlinked asset as the share asset — but the mismatch is
    ///         surfaced on-chain rather than silently trusted. Wallet-mode vaults
    ///         hard-revert on a mismatch instead ({CoreLinkMismatch}).
    event CoreLinkUnverified(address indexed asset, address indexed coreEvmContract);
    /// @notice WALLET MODE: emitted at deploy when the live `tokenInfo` row
    ///         confirms the configured CoreDepositWallet IS the Core-USDC linked
    ///         EVM contract (audit G2) — the on-chain attestation that push and
    ///         pull route through the same official bridge. Absent on substrates
    ///         where the precompile is empty (fresh Core account, revm fork).
    event CoreLinkVerified(address indexed asset, address indexed coreDepositWallet);

    // -------------------------------------------------------------------------
    // Operator surface
    // -------------------------------------------------------------------------

    function placeLimitOrder(uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly, uint8 tif)
        external
        returns (uint128 cloid);

    function cancelOrderByCloid(uint32 asset, uint128 cloid) external;

    function pushToCore(uint64 amount) external;
    function pullFromCore(uint64 amountWei) external;
    function operatorRecoverSpot(address to, uint64 token, uint64 amountWei) external;
    function operatorSweepStranded(address to) external;

    function usdSpotToPerp(uint64 ntl) external;
    function usdPerpToSpot(uint64 ntl) external;

    function nextCloid() external view returns (uint128);

    // -------------------------------------------------------------------------
    // Admin (timelock) — audit-mitigation surface
    // -------------------------------------------------------------------------

    /// @notice Allowlist `dest` as a permitted `operatorRecoverSpot` recipient (audit C-2).
    function setSpotRecoverDest(address dest, bool allowed) external;
    function spotRecoverDest(address dest) external view returns (bool);

    /// @notice End the one-way fresh-vault NAV grace period (audit H-1). After this,
    ///         any revert from `spotBalance` / `withdrawable` bubbles up rather than
    ///         silently zeroing NAV (strict / fail-closed). Call after the vault's
    ///         Core account is initialised (any successful cross-chain action).
    function endNavBootstrap() external;
    /// @notice True while NAV reads are lenient (fresh-vault grace); false once
    ///         {endNavBootstrap} has switched them to strict (audit H-1).
    function navBootstrap() external view returns (bool);

    /// @notice Per-spot-asset slippage band in bps + calibrated spotPx->limitPx
    ///         scale factor (audit H-3 / M6). 0 bps = no band; a non-zero band
    ///         requires a non-zero scaleFactor. Compared against the NORMALIZED spotPx.
    function setSpotSlippageBand(uint32 asset_, uint16 bps, uint64 scaleFactor) external;
    function spotSlippageBandBps(uint32 asset_) external view returns (uint16);
    function spotPxScaleFactor(uint32 asset_) external view returns (uint64);
    /// @notice Suggested starting scale factor (10^(2+baseSzDecimals)) for calibrating
    ///         {setSpotSlippageBand} — guidance only; verify on a live order (audit M6).
    function suggestedSpotPxScaleFactor(uint32 asset_) external view returns (uint64);

    /// @notice Withdrawal-request fulfillment SLA window in seconds (audit H2). 0
    ///         disables deadlines. Used by {requestWithdraw}/{prioritizeOverdue}.
    function setRequestFulfillmentWindow(uint64 window) external;
    function requestFulfillmentWindow() external view returns (uint64);

    /// @notice Set the permissionless-trigger grace window in seconds (M5 §1,
    ///         SOLU-3371) — how long a request must stay overdue BEYOND its SLA
    ///         deadline before {triggerEscape} can arm the brake. REVERTS
    ///         {EscapeGraceOutOfRange} outside the compile-time hard bounds
    ///         [`ESCAPE_GRACE_MIN`, `ESCAPE_GRACE_MAX`] (fail-closed — the timelock
    ///         cannot disable the brake). Emits {EscapeGraceSecondsUpdated}.
    function setEscapeGraceSeconds(uint64 newGrace) external;

    // -------------------------------------------------------------------------
    // Emergency surface
    // -------------------------------------------------------------------------

    function pause() external;
    function unpause() external;
    function emergencyCancelByCloid(uint32[] calldata assets, uint128[][] calldata cloids) external;
    function emergencyCancelByOid(uint32 asset, uint64 oid) external;
    function emergencyClosePositions(uint32[] calldata perpAssets, uint64[] calldata limitPxs) external;
    /// @notice Emergency close that skips the {emergencyCloseBandBps} sanity band —
    ///         explicit last-resort override when the oracle is unusable (audit M4).
    function emergencyClosePositionsForce(uint32[] calldata perpAssets, uint64[] calldata limitPxs) external;
    function emergencyShutdown() external;
    /// @notice Sanity band (bps) for emergency-close prices vs strict markPx (audit M4).
    function setEmergencyCloseBand(uint16 bps) external;
    function emergencyCloseBandBps() external view returns (uint16);
    /// @notice EMERGENCY_ROLE escape hatch to repatriate Core funds toward idle
    ///         (perp->spot and/or spot-send to the bridge or an allowlisted
    ///         treasury) even while paused / operator-dark (audit H2).
    function emergencyRepatriate(address to, uint64 perpToSpotNtl, uint64 spotSendWei) external;

    // -------------------------------------------------------------------------
    // NAV / view helpers
    // -------------------------------------------------------------------------

    function nav() external view returns (uint256);
    function pricePerShare() external view returns (uint256);
    /// @notice Core spot token index treated as USDC for NAV (audit C1).
    function coreUsdcIndex() external view returns (uint64);
    /// @notice Core wei decimals for {coreUsdcIndex}, validated at deploy (audit C1/M5).
    function coreUsdcDecimals() external view returns (uint8);
    /// @notice Circle's CoreDepositWallet used by {pushToCore} (audit G2);
    ///         `address(0)` = legacy HIP-1 route. Immutable; validated at deploy.
    function coreDepositWallet() external view returns (address);
    function idleUsdc() external view returns (uint256);
    /// @notice Idle not reserved for overdue prioritized requests (audit H2).
    function availableIdleUsdc() external view returns (uint256);
    /// @notice Idle reserved for overdue prioritized requests (audit H2).
    function reservedIdleUsdc() external view returns (uint256);
    function coreSpotUsdc() external view returns (uint256);
    function perpWithdrawable() external view returns (uint256);
    function pendingMgmtFeeShares() external view returns (uint256);
    function isPerpWhitelisted(uint32 asset) external view returns (bool);
    function isSpotWhitelisted(uint32 asset) external view returns (bool);
    function whitelistedPerpsList() external view returns (uint256[] memory);
    function whitelistedSpotsList() external view returns (uint256[] memory);

    // -------------------------------------------------------------------------
    // Withdrawal queue (escape hatch)
    // -------------------------------------------------------------------------

    function requestWithdraw(uint256 shares) external;
    function cancelWithdrawRequest() external;
    function fulfillWithdraw(address lp) external;
    /// @notice Permissionless: reserve an overdue request's claim on idle ahead of
    ///         racing direct redeems, once its SLA deadline lapses (audit H2).
    function prioritizeOverdue(address lp) external;
    function pendingWithdrawalShares(address lp) external view returns (uint256);
    /// @notice Fulfillment SLA deadline for `lp`'s request (0 = none) (audit H2).
    function pendingWithdrawalDeadline(address lp) external view returns (uint64);
    /// @notice Idle reserved for `lp`'s prioritized request (audit H2).
    function pendingWithdrawalReserved(address lp) external view returns (uint256);
    /// @notice True iff `lp` has a request whose deadline has lapsed (audit H2).
    function requestIsOverdue(address lp) external view returns (bool);

    // -------------------------------------------------------------------------
    // Escape hatch — permissionless "dead man's brake" Phase 1 (M5)
    //
    // docs/ESCAPE_HATCH_SCOPE.md §2/§4/§7. While `escapeActive`, the vault is in
    // ESCAPE mode: deposits/mints + market-deploying movers are blocked, and the
    // three risk-reducing cranks below run permissionlessly (latch-gated +
    // nonReentrant + a per-interval cooldown), with all redemption paths unaffected.
    // -------------------------------------------------------------------------

    /// @notice True while the escape brake is armed and the vault is in ESCAPE mode (M5).
    function escapeActive() external view returns (bool);
    /// @notice Per-interval escape-crank cooldown in seconds (M5 §4).
    function escapeCrankInterval() external view returns (uint64);
    /// @notice Seconds a withdrawal request must stay overdue BEYOND its SLA deadline
    ///         before {triggerEscape} can arm the brake on it (M5 §1, SOLU-3371). The
    ///         grace STACKS on top of {requestFulfillmentWindow} so escape composes
    ///         with, and never preempts, the normal H2 priority flow. Default 8h;
    ///         admin-tunable within the hard bounds [`ESCAPE_GRACE_MIN`,
    ///         `ESCAPE_GRACE_MAX`] via {setEscapeGraceSeconds}.
    function escapeGraceSeconds() external view returns (uint64);

    /// @notice PERMISSIONLESS (M5 §1, SOLU-3371): arm the escape brake for `lp` when
    ///         its request is (a) overdue by AT LEAST {escapeGraceSeconds} beyond its
    ///         SLA deadline AND (b) has a remaining claim exceeding {availableIdleUsdc}.
    ///         The security is in the CONDITION, not the caller (anyone can deposit
    ///         dust and wait — §1 anti-grief). Reverts {EscapeConditionNotMet} when the
    ///         gate is unmet (including a request with no SLA deadline). `lp` is the
    ///         request that armed the brake (recorded in {EscapeActivated}).
    function triggerEscape(address lp) external;
    /// @notice Permissionlessly clear the brake (M5 §1) — succeeds only when no
    ///         overdue-unfillable request remains. `lps` is the set of LPs to check.
    function exitEscape(address[] calldata lps) external;

    /// @notice Leg 1 (M5 §2) — permissionlessly cancel the vault's resting orders on
    ///         `asset` by cloid while latched. Each cloid must be vault-issued.
    function escapeCancelOrders(uint32 asset, uint128[] calldata cloids) external;
    /// @notice Leg 2 (M5 §2) — permissionlessly flatten perps via reduce-only IOC
    ///         while latched, with the M4 markPx band MANDATORY (no force variant).
    function escapeFlattenPerps(uint32[] calldata perpAssets, uint64[] calldata limitPxs) external;
    /// @notice Leg 3 (M5 §2) — permissionlessly move all perp `withdrawable` equity
    ///         to Core spot while latched. Amount read on-chain (conservative).
    function escapeConsolidateToSpot() external;
}

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
    event BridgeDeposit(uint64 amount);  // EVM USDC -> Core spot
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
    /// @notice Admin set the spot slippage band for `asset` (audit H-3).
    event SpotSlippageBandUpdated(uint32 indexed asset, uint16 bps);
    /// @notice Admin updated the emergency-close sanity band (audit M4).
    event EmergencyCloseBandUpdated(uint16 oldBps, uint16 newBps);
    /// @notice Emitted at deploy when the Core-USDC token's linked EVM contract
    ///         (`tokenInfo(coreUsdcIndex).evmContract`) is NOT the vault's
    ///         `asset()` (audit C1). Not fatal — the deliberate Path-B posture
    ///         keeps the unlinked Circle USDC as the share asset — but the
    ///         mismatch is surfaced on-chain rather than silently trusted.
    event CoreLinkUnverified(address indexed asset, address indexed coreEvmContract);

    // -------------------------------------------------------------------------
    // Operator surface
    // -------------------------------------------------------------------------

    function placeLimitOrder(
        uint32 asset,
        bool isBuy,
        uint64 limitPx,
        uint64 sz,
        bool reduceOnly,
        uint8 tif
    ) external returns (uint128 cloid);

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

    /// @notice Per-spot-asset slippage band in bps (audit H-3). 0 = no band
    ///         (legacy / opt-out). Compared against `spotPx` from the precompile.
    function setSpotSlippageBand(uint32 asset_, uint16 bps) external;
    function spotSlippageBandBps(uint32 asset_) external view returns (uint16);

    /// @notice Withdrawal-request fulfillment SLA window in seconds (audit H2). 0
    ///         disables deadlines. Used by {requestWithdraw}/{prioritizeOverdue}.
    function setRequestFulfillmentWindow(uint64 window) external;
    function requestFulfillmentWindow() external view returns (uint64);

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
}

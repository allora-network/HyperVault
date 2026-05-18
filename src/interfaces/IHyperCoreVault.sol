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
    event PerfFeeCrystallized(address indexed lp, uint256 shares, uint256 gainAssets);

    event WithdrawalRequested(address indexed lp, uint256 shares);
    event WithdrawalFulfilled(address indexed lp, uint256 assets);

    event LeverageCapUpdated(uint16 oldCap, uint16 newCap);
    event SlippageBandUpdated(uint16 oldBand, uint16 newBand);
    event FeesUpdated(uint16 mgmtBps, uint16 perfBps);
    event WhitelistUpdated(uint32 indexed asset, bool isPerp, bool enabled);
    event DepositCapUpdated(uint256 oldCap, uint256 newCap);
    event PerAddressCapUpdated(uint256 oldCap, uint256 newCap);
    event EmergencyShutdownTriggered(address indexed by);

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
    // Emergency surface
    // -------------------------------------------------------------------------

    function pause() external;
    function unpause() external;
    function emergencyCancelByCloid(uint32[] calldata assets, uint128[][] calldata cloids) external;
    function emergencyCancelByOid(uint32 asset, uint64 oid) external;
    function emergencyClosePositions(uint32[] calldata perpAssets, uint64[] calldata limitPxs) external;
    function emergencyShutdown() external;

    // -------------------------------------------------------------------------
    // NAV / view helpers
    // -------------------------------------------------------------------------

    function nav() external view returns (uint256);
    function pricePerShare() external view returns (uint256);
    function idleUsdc() external view returns (uint256);
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
    function pendingWithdrawalShares(address lp) external view returns (uint256);
}

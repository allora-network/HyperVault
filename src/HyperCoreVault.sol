// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC4626, IERC20, ERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHyperCoreVault} from "./interfaces/IHyperCoreVault.sol";
import {CoreWriterLib} from "./libraries/CoreWriterLib.sol";
import {PrecompileLib} from "./libraries/PrecompileLib.sol";
import {SystemAddress} from "./libraries/SystemAddress.sol";
import {AssetId} from "./libraries/AssetId.sol";
import {Constants} from "./libraries/Constants.sol";

/// @title  HyperCoreVault — EIP-4626 vault that trades on HyperCore via CoreWriter
/// @notice One vault per strategy. Operator runs trades; depositors hold tokenized shares.
///         NAV is computed trustlessly from HyperCore precompiles.
///
///         See `docs/ARCHITECTURE.md` for design rationale and
///         `docs/INTEGRATION.md` for live-runner integration.
contract HyperCoreVault is IHyperCoreVault, ERC4626, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    // -------------------------------------------------------------------------
    // Roles
    // -------------------------------------------------------------------------

    bytes32 public constant OPERATOR_ROLE  = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // -------------------------------------------------------------------------
    // Constructor params (immutable per vault)
    // -------------------------------------------------------------------------

    struct Config {
        IERC20 asset;            // USDC ERC20 on HyperEVM
        string name;
        string symbol;
        address admin;           // DEFAULT_ADMIN_ROLE — should be a TimelockController
        address operator;
        address emergencyAdmin;
        address feeRecipient;
        uint16 leverageCapBps;
        uint16 slippageBandBps;
        uint16 mgmtFeeAnnualBps;
        uint16 perfFeeBps;
        uint256 depositCap;
        uint256 maxDepositPerAddress;
    }

    address public immutable feeRecipient;

    // -------------------------------------------------------------------------
    // Mutable config (admin / timelock)
    // -------------------------------------------------------------------------

    uint16 public leverageCapBps;
    uint16 public slippageBandBps;
    uint16 public mgmtFeeAnnualBps;
    uint16 public perfFeeBps;
    uint256 public depositCap;
    uint256 public maxDepositPerAddress;

    EnumerableSet.UintSet private _whitelistedPerps;
    EnumerableSet.UintSet private _whitelistedSpots;

    // -------------------------------------------------------------------------
    // Runtime state
    // -------------------------------------------------------------------------

    uint128 private _cloidCounter;          // monotonically increasing client order id
    uint64  private _lastAccrualTs;          // last management-fee accrual timestamp
    bool    public emergencyShutdownActive;  // one-way switch

    /// @notice Per-LP cost basis per share, 1e18-fixed (price-per-share at entry).
    /// @dev    Updated on mint and on transfer between non-vault parties. Used
    ///         for crystallize-on-redeem perf fee.
    mapping(address => uint256) private _costBasisPerShare;

    struct WithdrawalRequest {
        uint256 shares;             // shares escrowed at the vault
        uint256 costBasisAtRequest; // 1e18-fixed snapshot of LP's cb at request time
    }

    /// @notice One pending withdrawal request per LP. Issue a new one only after
    ///         cancelling the existing one.
    mapping(address => WithdrawalRequest) private _pendingWithdrawal;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(Config memory cfg)
        ERC4626(cfg.asset)
        ERC20(cfg.name, cfg.symbol)
    {
        if (
            cfg.admin == address(0) ||
            cfg.operator == address(0) ||
            cfg.emergencyAdmin == address(0) ||
            cfg.feeRecipient == address(0)
        ) revert ZeroAddress();
        if (cfg.mgmtFeeAnnualBps > 2_000 || cfg.perfFeeBps > 5_000) {
            // hard caps: 20% mgmt/yr and 50% perf — sanity, not a marketing limit
            revert InvalidFeeConfig(cfg.mgmtFeeAnnualBps, cfg.perfFeeBps);
        }

        feeRecipient         = cfg.feeRecipient;
        leverageCapBps       = cfg.leverageCapBps;
        slippageBandBps      = cfg.slippageBandBps;
        mgmtFeeAnnualBps     = cfg.mgmtFeeAnnualBps;
        perfFeeBps           = cfg.perfFeeBps;
        depositCap           = cfg.depositCap;
        maxDepositPerAddress = cfg.maxDepositPerAddress;
        _lastAccrualTs       = uint64(block.timestamp);
        _cloidCounter        = 1; // start at 1 — cloid 0 means "no cloid" in HL conventions

        _grantRole(DEFAULT_ADMIN_ROLE, cfg.admin);
        _grantRole(OPERATOR_ROLE,      cfg.operator);
        _grantRole(EMERGENCY_ROLE,     cfg.emergencyAdmin);
    }

    // -------------------------------------------------------------------------
    // ERC4626 overrides
    // -------------------------------------------------------------------------

    /// @notice 6 decimals offset — share token is 12dp. Mitigates inflation attack
    ///         per OpenZeppelin's virtual-shares pattern.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @notice NAV = idle EVM USDC + Core spot USDC (decimal-normalized) + perp withdrawable.
    ///         Intentionally excludes mark-price PnL — uses HL's conservative
    ///         `withdrawable` figure for perp equity.
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return idleUsdc() + coreSpotUsdc() + perpWithdrawable();
    }

    function maxDeposit(address receiver) public view override(ERC4626, IERC4626) returns (uint256) {
        if (paused() || emergencyShutdownActive) return 0;
        uint256 capRemaining = depositCap > totalAssets() ? depositCap - totalAssets() : 0;
        uint256 perAddrRemaining;
        if (maxDepositPerAddress == 0) {
            perAddrRemaining = type(uint256).max;
        } else {
            uint256 ownedAssets = convertToAssets(balanceOf(receiver));
            perAddrRemaining = maxDepositPerAddress > ownedAssets ? maxDepositPerAddress - ownedAssets : 0;
        }
        return Math.min(capRemaining, perAddrRemaining);
    }

    function maxMint(address receiver) public view override(ERC4626, IERC4626) returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    /// @notice CRITICAL: bounded by idle EVM USDC so ERC4626 integrators don't get
    ///         silently reverted when the operator has parked capital on Core.
    function maxWithdraw(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 ownedAssets = convertToAssets(balanceOf(owner));
        return Math.min(ownedAssets, idleUsdc());
    }

    function maxRedeem(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        return balanceOf(owner);
    }

    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (emergencyShutdownActive) revert EmergencyShutdownActive();
        _accrueMgmtFee();
        shares = super.deposit(assets, receiver);
        _absorbCostBasis(receiver, shares, assets);
    }

    function mint(uint256 shares, address receiver)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        if (emergencyShutdownActive) revert EmergencyShutdownActive();
        _accrueMgmtFee();
        assets = super.mint(shares, receiver);
        _absorbCostBasis(receiver, shares, assets);
    }

    /// @dev Bypasses `super.withdraw` to avoid OZ's `maxWithdraw` check, which
    ///      tightens as our fee accrual mints dilutive shares. We enforce the
    ///      idle-USDC cap here directly.
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256 shares)
    {
        uint256 idle = idleUsdc();
        if (assets > idle) revert WithdrawExceedsIdleBalance(assets, idle);

        _accrueMgmtFee();
        shares = previewWithdraw(assets);
        if (shares > balanceOf(owner)) revert WithdrawExceedsIdleBalance(assets, idle);

        _crystallizePerfFee(owner, shares);
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        _burn(owner, shares);
        IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256 assets)
    {
        if (shares > balanceOf(owner)) shares = balanceOf(owner);

        _accrueMgmtFee();
        _crystallizePerfFee(owner, shares);

        assets = previewRedeem(shares);
        uint256 idle = idleUsdc();
        if (assets > idle) {
            // Partial payout: scale down both legs proportionally
            assets = idle;
            uint256 scaled = previewWithdraw(assets);
            if (scaled < shares) shares = scaled;
        }

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        _burn(owner, shares);
        if (assets > 0) IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @dev   Cost-basis tracking on every share movement so perf fee follows shares.
    ///        - Mint paths set cost basis explicitly in `_absorbCostBasis`.
    ///        - Regular transfers between two LPs: receiver inherits a weighted
    ///          average of the two cost bases.
    ///        - Vault-as-counterparty (escrow during requestWithdraw,
    ///          cancellation): no cost basis update. The pending request stores
    ///          a snapshot separately.
    function _update(address from, address to, uint256 value) internal override {
        if (
            from != address(0) &&
            to != address(0) &&
            value > 0 &&
            from != to &&
            from != address(this) &&
            to != address(this)
        ) {
            uint256 senderCb = _costBasisPerShare[from];
            uint256 recvBalBefore = balanceOf(to);
            uint256 recvBalAfter = recvBalBefore + value;
            uint256 newCb;
            if (recvBalBefore == 0) {
                newCb = senderCb;
            } else {
                newCb = (recvBalBefore * _costBasisPerShare[to] + value * senderCb) / recvBalAfter;
            }
            _costBasisPerShare[to] = newCb;
            // sender keeps their cost basis on remaining shares
        }
        super._update(from, to, value);
    }

    // -------------------------------------------------------------------------
    // NAV decomposition (public for indexers and the frontend)
    // -------------------------------------------------------------------------

    function idleUsdc() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function coreSpotUsdc() public view returns (uint256) {
        uint64 totalCore = PrecompileLib.spotBalance(address(this), Constants.USDC_CORE_INDEX).total;
        return _coreToEvm(totalCore);
    }

    function perpWithdrawable() public view returns (uint256) {
        return uint256(PrecompileLib.withdrawable(address(this)).withdrawable);
    }

    function nav() external view returns (uint256) {
        return totalAssets();
    }

    function pricePerShare() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return Constants.WAD; // by definition 1.0 in 1e18 units
        return Math.mulDiv(totalAssets(), Constants.WAD, supply);
    }

    function pendingMgmtFeeShares() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0 || mgmtFeeAnnualBps == 0) return 0;
        uint256 dt = block.timestamp - _lastAccrualTs;
        uint256 currNav = totalAssets();
        if (currNav == 0 || dt == 0) return 0;
        uint256 feeAssets = (currNav * mgmtFeeAnnualBps * dt) / (Constants.BPS * Constants.SECONDS_PER_YEAR);
        if (feeAssets >= currNav) feeAssets = currNav / 2;
        return (feeAssets * supply) / (currNav - feeAssets);
    }

    function isPerpWhitelisted(uint32 asset_) external view returns (bool) {
        return _whitelistedPerps.contains(asset_);
    }

    function isSpotWhitelisted(uint32 asset_) external view returns (bool) {
        return _whitelistedSpots.contains(asset_);
    }

    function whitelistedPerpsList() external view returns (uint256[] memory) {
        return _whitelistedPerps.values();
    }

    function whitelistedSpotsList() external view returns (uint256[] memory) {
        return _whitelistedSpots.values();
    }

    function pendingWithdrawalShares(address lp) external view returns (uint256) {
        return _pendingWithdrawal[lp].shares;
    }

    function nextCloid() external view returns (uint128) {
        return _cloidCounter;
    }

    // -------------------------------------------------------------------------
    // Operator surface
    // -------------------------------------------------------------------------

    function placeLimitOrder(
        uint32 asset_,
        bool isBuy,
        uint64 limitPx,
        uint64 sz,
        bool reduceOnly,
        uint8 tif
    ) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant returns (uint128 cloid) {
        _accrueMgmtFee();

        // 1. Whitelist gate
        if (AssetId.isPerp(asset_)) {
            if (!_whitelistedPerps.contains(asset_)) revert AssetNotWhitelisted(asset_);
        } else {
            if (!_whitelistedSpots.contains(asset_)) revert AssetNotWhitelisted(asset_);
        }

        // 2. Slippage band — perps only.
        //    Scale mismatch: the `oraclePx` precompile returns price in
        //    `human * 10^(6-szDecimals)` scale, while `placeLimitOrder`'s
        //    `limitPx` arg is in `human * 10^(8-szDecimals)` scale (per the
        //    `limit_order` action encoding). Ratio is always 100×, regardless
        //    of szDecimals. Normalize oraclePx up by 100 before comparing.
        if (AssetId.isPerp(asset_) && slippageBandBps > 0) {
            uint64 oraclePxRaw = PrecompileLib.oraclePx(asset_);
            if (oraclePxRaw > 0) {
                uint256 oracleNorm = uint256(oraclePxRaw) * 100;
                uint256 limitPxU = uint256(limitPx);
                uint256 diff = limitPxU > oracleNorm ? limitPxU - oracleNorm : oracleNorm - limitPxU;
                uint256 maxDiff = (oracleNorm * slippageBandBps) / Constants.BPS;
                if (diff > maxDiff) revert SlippageBandExceeded(limitPx, oraclePxRaw, slippageBandBps);
            }
        }

        // 3. Leverage cap — incremental new-order notional + sum of open perp notionals
        if (!reduceOnly && AssetId.isPerp(asset_) && leverageCapBps > 0) {
            uint256 navNow = totalAssets();
            uint256 gross = _grossOpenPerpNotional6dp() + _orderNotional6dp(sz, limitPx);
            uint256 capUsd = (navNow * leverageCapBps) / Constants.BPS;
            if (gross > capUsd) revert LeverageCapExceeded(gross, navNow, leverageCapBps);
        }

        // 4. Assign cloid, dispatch
        cloid = _cloidCounter++;
        CoreWriterLib.placeLimitOrder(asset_, isBuy, limitPx, sz, reduceOnly, tif, cloid);
        emit LimitOrderSubmitted(asset_, isBuy, limitPx, sz, reduceOnly, tif, cloid, totalAssets());
    }

    function cancelOrderByCloid(uint32 asset_, uint128 cloid) external onlyRole(OPERATOR_ROLE) nonReentrant {
        CoreWriterLib.cancelOrderByCloid(asset_, cloid);
        emit OrderCancelByCloidSubmitted(asset_, cloid);
    }

    function pushToCore(uint64 amount) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant {
        // ERC20 transfer to USDC bridge — Core credits 8dp wei after scaling by evmExtraWeiDecimals
        IERC20(asset()).safeTransfer(SystemAddress.usdc(), amount);
        emit BridgeDeposit(amount);
    }

    function pullFromCore(uint64 amountWei) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant {
        // spot_send to USDC system address — system tx then transfers ERC20 back to this vault
        CoreWriterLib.spotSend(SystemAddress.usdc(), Constants.USDC_CORE_INDEX, amountWei);
        emit BridgeWithdraw(amountWei);
    }

    /// @notice Send a Core spot token from the vault's Core account to any address.
    /// @dev    Generalised escape hatch needed when the canonical EVM↔Core USDC
    ///         bridge isn't deployed for the chosen asset (the current mainnet
    ///         situation — Circle USDC on EVM is not linked to Core USDC). The
    ///         operator uses this to send realised PnL or rebalancing funds to
    ///         a treasury / re-deposit address.
    ///
    ///         Note: this is `OPERATOR_ROLE` gated, not `EMERGENCY_ROLE`,
    ///         because it's part of the normal rebalance flow when the bridge
    ///         is non-functional. In a deployment with a functional bridge,
    ///         `pullFromCore` is preferred and this can be considered an
    ///         emergency-only path — operators should restrict their key
    ///         accordingly (e.g., via a multisig).
    function operatorRecoverSpot(address to, uint64 token, uint64 amountWei)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        CoreWriterLib.spotSend(to, token, amountWei);
        emit OperatorSpotRecovered(to, token, amountWei);
    }

    /// @notice Sweep EVM-side `asset()` balance when there are no LPs.
    /// @dev    Recovery path for the "donation-to-empty-vault" trap: OZ's
    ///         virtual-shares math leaves arbitrary funds in the vault when
    ///         someone bridges/transfers asset before the first real deposit.
    ///         Once `totalSupply == 0`, no LP has any claim on the asset
    ///         balance — it's safe to sweep. Reverts if shares exist.
    function operatorSweepStranded(address to) external onlyRole(OPERATOR_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (totalSupply() != 0) revert StrandedSweepRequiresZeroSupply();
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (bal > 0) {
            IERC20(asset()).safeTransfer(to, bal);
            emit StrandedSwept(to, bal);
        }
    }

    function usdSpotToPerp(uint64 ntl) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant {
        CoreWriterLib.usdClassTransfer(ntl, true);
        emit UsdClassTransferSubmitted(ntl, true);
    }

    function usdPerpToSpot(uint64 ntl) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant {
        CoreWriterLib.usdClassTransfer(ntl, false);
        emit UsdClassTransferSubmitted(ntl, false);
    }

    // -------------------------------------------------------------------------
    // Emergency surface
    // -------------------------------------------------------------------------

    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    function emergencyCancelByCloid(uint32[] calldata assets, uint128[][] calldata cloids)
        external
        onlyRole(EMERGENCY_ROLE)
        nonReentrant
    {
        require(assets.length == cloids.length, "len");
        for (uint256 i; i < assets.length; ++i) {
            uint32 a = assets[i];
            uint128[] calldata cs = cloids[i];
            for (uint256 j; j < cs.length; ++j) {
                CoreWriterLib.cancelOrderByCloid(a, cs[j]);
                emit OrderCancelByCloidSubmitted(a, cs[j]);
            }
        }
    }

    function emergencyCancelByOid(uint32 asset_, uint64 oid) external onlyRole(EMERGENCY_ROLE) nonReentrant {
        CoreWriterLib.cancelOrderByOid(asset_, oid);
        emit OrderCancelByOidSubmitted(asset_, oid);
    }

    /// @notice Close open perp positions via opposite-side IOC orders at the
    ///         caller-supplied `limitPxs` (recommend: mark px ± slippage).
    /// @dev    Caller is responsible for sizing — read each `position(this, a).szi`
    ///         off-chain and pass the matching `limitPx`. Iterates serially.
    function emergencyClosePositions(uint32[] calldata perpAssets, uint64[] calldata limitPxs)
        external
        onlyRole(EMERGENCY_ROLE)
        nonReentrant
    {
        require(perpAssets.length == limitPxs.length, "len");
        for (uint256 i; i < perpAssets.length; ++i) {
            uint32 a = perpAssets[i];
            int64 szi = PrecompileLib.position(address(this), a).szi;
            if (szi == 0) continue;
            uint64 absSz = szi < 0 ? uint64(-szi) : uint64(szi);
            bool isBuy = szi < 0; // long if currently short, vice versa
            uint128 cloid = _cloidCounter++;
            CoreWriterLib.placeLimitOrder(a, isBuy, limitPxs[i], absSz, true, Constants.TIF_IOC, cloid);
            emit LimitOrderSubmitted(a, isBuy, limitPxs[i], absSz, true, Constants.TIF_IOC, cloid, totalAssets());
        }
    }

    /// @notice One-way switch. Blocks deposits forever; redeems remain open
    ///         once the operator has rebalanced funds back to idle EVM.
    function emergencyShutdown() external onlyRole(EMERGENCY_ROLE) {
        emergencyShutdownActive = true;
        emit EmergencyShutdownTriggered(msg.sender);
    }

    // -------------------------------------------------------------------------
    // Admin (timelock) — guardrail mutations
    // -------------------------------------------------------------------------

    function setWhitelistPerp(uint32 asset_, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (enabled) _whitelistedPerps.add(asset_);
        else _whitelistedPerps.remove(asset_);
        emit WhitelistUpdated(asset_, true, enabled);
    }

    function setWhitelistSpot(uint32 asset_, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (enabled) _whitelistedSpots.add(asset_);
        else _whitelistedSpots.remove(asset_);
        emit WhitelistUpdated(asset_, false, enabled);
    }

    function setLeverageCap(uint16 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit LeverageCapUpdated(leverageCapBps, newCap);
        leverageCapBps = newCap;
    }

    function setSlippageBand(uint16 newBand) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit SlippageBandUpdated(slippageBandBps, newBand);
        slippageBandBps = newBand;
    }

    function setFees(uint16 newMgmt, uint16 newPerf) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMgmt > 2_000 || newPerf > 5_000) revert InvalidFeeConfig(newMgmt, newPerf);
        _accrueMgmtFee(); // settle at old rate
        mgmtFeeAnnualBps = newMgmt;
        perfFeeBps = newPerf;
        emit FeesUpdated(newMgmt, newPerf);
    }

    function setDepositCap(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit DepositCapUpdated(depositCap, newCap);
        depositCap = newCap;
    }

    function setMaxDepositPerAddress(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit PerAddressCapUpdated(maxDepositPerAddress, newCap);
        maxDepositPerAddress = newCap;
    }

    /// @notice Recover non-asset tokens that landed at the vault. Cannot sweep `asset()`.
    function sweep(IERC20 token, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(token) == asset()) revert SweepingAsset();
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, token.balanceOf(address(this)));
    }

    // -------------------------------------------------------------------------
    // Withdrawal queue (escape hatch for illiquid moments)
    //
    // Single pending request per LP. Shares are escrowed at the vault address
    // so the LP cannot transfer or redeem them while a request is open. The
    // LP's cost basis is snapshotted at request time; perf fee at fulfilment
    // uses that snapshot vs. the current pricePerShare.
    // -------------------------------------------------------------------------

    function requestWithdraw(uint256 shares) external nonReentrant {
        if (shares == 0) return;
        uint256 bal = balanceOf(msg.sender);
        if (shares > bal) revert WithdrawExceedsIdleBalance(shares, bal);
        if (_pendingWithdrawal[msg.sender].shares != 0) revert WithdrawExceedsIdleBalance(shares, 0);

        _pendingWithdrawal[msg.sender] = WithdrawalRequest({
            shares: shares,
            costBasisAtRequest: _costBasisPerShare[msg.sender]
        });
        _transfer(msg.sender, address(this), shares);
        emit WithdrawalRequested(msg.sender, shares);
    }

    function cancelWithdrawRequest() external nonReentrant {
        WithdrawalRequest memory req = _pendingWithdrawal[msg.sender];
        if (req.shares == 0) return;
        delete _pendingWithdrawal[msg.sender];
        _transfer(address(this), msg.sender, req.shares);
        // cb is preserved on receive (from == address(this) skipped in _update)
    }

    /// @notice Anyone may call (keeper-friendly). Pays out as much of the request
    ///         as idle USDC allows, partial fills supported.
    function fulfillWithdraw(address lp) external nonReentrant {
        WithdrawalRequest memory req = _pendingWithdrawal[lp];
        if (req.shares == 0) return;

        _accrueMgmtFee();

        uint256 assetsPossible = previewRedeem(req.shares);
        uint256 idle = idleUsdc();
        uint256 outAssets;
        uint256 outShares;

        if (assetsPossible <= idle) {
            outAssets = assetsPossible;
            outShares = req.shares;
        } else {
            outAssets = idle;
            outShares = previewWithdraw(idle);
            if (outShares > req.shares) outShares = req.shares;
        }
        if (outShares == 0 || outAssets == 0) return;

        _crystallizePerfFeeWithCb(lp, outShares, req.costBasisAtRequest);

        if (outShares == req.shares) {
            delete _pendingWithdrawal[lp];
        } else {
            _pendingWithdrawal[lp].shares = req.shares - outShares;
        }

        _burn(address(this), outShares);
        IERC20(asset()).safeTransfer(lp, outAssets);

        emit Withdraw(msg.sender, lp, lp, outAssets, outShares);
        emit WithdrawalFulfilled(lp, outAssets);
    }

    // -------------------------------------------------------------------------
    // Internal — fee accounting
    // -------------------------------------------------------------------------

    function _accrueMgmtFee() internal {
        uint256 supply = totalSupply();
        uint64 nowTs = uint64(block.timestamp);
        if (supply == 0 || mgmtFeeAnnualBps == 0) {
            _lastAccrualTs = nowTs;
            return;
        }
        uint256 dt = nowTs - _lastAccrualTs;
        if (dt == 0) return;
        uint256 navNow = totalAssets();
        if (navNow == 0) {
            _lastAccrualTs = nowTs;
            return;
        }
        uint256 feeAssets = (navNow * mgmtFeeAnnualBps * dt) / (Constants.BPS * Constants.SECONDS_PER_YEAR);
        if (feeAssets >= navNow) feeAssets = navNow / 2; // sanity cap on absurd dt
        uint256 feeShares = (feeAssets * supply) / (navNow - feeAssets);
        if (feeShares > 0) {
            _mint(feeRecipient, feeShares);
            _absorbCostBasis(feeRecipient, feeShares, feeAssets);
            emit MgmtFeeAccrued(feeShares, navNow);
        }
        _lastAccrualTs = nowTs;
        emit NavSnapshot(navNow, totalSupply(), idleUsdc(), coreSpotUsdc(), perpWithdrawable(), block.timestamp);
    }

    function _crystallizePerfFee(address lp, uint256 shares) internal {
        _crystallizePerfFeeWithCb(lp, shares, _costBasisPerShare[lp]);
    }

    function _crystallizePerfFeeWithCb(address lp, uint256 shares, uint256 cb) internal {
        if (perfFeeBps == 0 || shares == 0) return;
        uint256 cur = pricePerShare();
        if (cur <= cb) return;
        uint256 gainPerShare = cur - cb;
        uint256 gainAssets = Math.mulDiv(gainPerShare, shares, Constants.WAD);
        uint256 feeAssets = (gainAssets * perfFeeBps) / Constants.BPS;
        if (feeAssets == 0) return;

        uint256 navNow = totalAssets();
        uint256 supply = totalSupply();
        if (feeAssets >= navNow) return; // safety
        uint256 feeShares = (feeAssets * supply) / (navNow - feeAssets);
        if (feeShares > 0) {
            _mint(feeRecipient, feeShares);
            _absorbCostBasis(feeRecipient, feeShares, feeAssets);
            emit PerfFeeCrystallized(lp, feeShares, gainAssets);
        }
    }

    /// @dev   Sets the LP's cost basis from the effective entry price
    ///        `entryPps = newAssets * WAD / newShares`. Derived this way to
    ///        cover the first depositor correctly (no pre-existing PPS) and to
    ///        keep fee-mint cost basis consistent with how feeShares are sized.
    function _absorbCostBasis(address lp, uint256 newShares, uint256 newAssets) internal {
        if (newShares == 0) return;
        uint256 entryPps = Math.mulDiv(newAssets, Constants.WAD, newShares);
        uint256 totalShares = balanceOf(lp);
        uint256 oldShares = totalShares - newShares;
        if (oldShares == 0) {
            _costBasisPerShare[lp] = entryPps;
        } else {
            _costBasisPerShare[lp] =
                (oldShares * _costBasisPerShare[lp] + newShares * entryPps) / totalShares;
        }
    }

    // -------------------------------------------------------------------------
    // Internal — leverage cap helpers
    // -------------------------------------------------------------------------

    /// @dev   Sum of |size * markPx| over all whitelisted perps, in 6dp USD.
    ///        Scale derivation:
    ///          sz raw         = human_sz * 10^szDec
    ///          markPx precomp = human_px * 10^(6 - szDec)
    ///          product        = human_sz * human_px * 10^6 = direct 6dp USD
    ///        (no divisor needed). Different scale than `_orderNotional6dp`
    ///        which takes `limitPx` in the limit-order-action 8-decimal scale.
    function _grossOpenPerpNotional6dp() internal view returns (uint256 total) {
        uint256[] memory perps = _whitelistedPerps.values();
        for (uint256 i; i < perps.length; ++i) {
            uint32 a = uint32(perps[i]);
            int64 szi = PrecompileLib.position(address(this), a).szi;
            if (szi == 0) continue;
            uint64 markPx = PrecompileLib.markPx(a);
            if (markPx == 0) continue;
            uint64 absSz = szi < 0 ? uint64(-szi) : uint64(szi);
            total += uint256(absSz) * uint256(markPx);
        }
    }

    function _orderNotional6dp(uint64 sz, uint64 limitPx) internal pure returns (uint256) {
        return (uint256(sz) * uint256(limitPx)) / 100;
    }

    // -------------------------------------------------------------------------
    // Internal — decimal normalization for USDC
    // -------------------------------------------------------------------------

    function _coreToEvm(uint64 coreWei) internal pure returns (uint256) {
        uint256 cwei = uint256(coreWei);
        if (Constants.USDC_CORE_DECIMALS >= Constants.USDC_EVM_DECIMALS) {
            // Core has more decimals → divide
            return cwei / (10 ** (Constants.USDC_CORE_DECIMALS - Constants.USDC_EVM_DECIMALS));
        } else {
            // EVM has more decimals → multiply
            return cwei * (10 ** (Constants.USDC_EVM_DECIMALS - Constants.USDC_CORE_DECIMALS));
        }
    }

    // -------------------------------------------------------------------------
    // ERC165 — required by AccessControl + ERC4626 inheritance
    // -------------------------------------------------------------------------

    function supportsInterface(bytes4 id) public view virtual override(AccessControl) returns (bool) {
        return super.supportsInterface(id);
    }
}

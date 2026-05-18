// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Constants} from "./Constants.sol";

/// @notice Typed, safe wrappers around the HyperCore L1 read precompiles
///         (0x0800–0x0810). Each wrapper does a `staticcall`, decodes the
///         protocol's reply struct, and returns it. If the precompile reverts
///         (e.g. the account has never touched the market in question), the
///         wrapper returns a zero-initialized struct instead of bubbling the
///         revert — this matches the semantics the vault needs for NAV math.
///
/// @dev    Struct layouts mirror the Hyperliquid spec / `hyperliquid-dev/hyper-evm-lib`
///         reference. If a layout changes in a protocol upgrade, update here in
///         a single place. All values are unscaled — callers normalize.
library PrecompileLib {
    // -------------------------------------------------------------------------
    // Errors (strict variants)
    // -------------------------------------------------------------------------

    /// @notice Strict read failed: precompile reverted or returned empty data.
    /// @dev    Used by `*Strict` variants. Lenient `_read` swallows this case.
    error PrecompileRevert(address precompile);

    /// @notice Strict read returned a zero where zero is not a valid value
    ///         (e.g. oracle / mark / spot price of a live market must be > 0).
    error PrecompileZero(address precompile);

    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    struct Position {
        int64 szi;            // signed size in szDecimals lots (negative = short)
        uint64 entryNtl;      // notional at entry
        int64 isolatedRawUsd; // for isolated margin positions
        uint32 leverage;      // leverage in tenths (e.g. 50 = 5x)
        bool isIsolated;
    }

    struct SpotBalance {
        uint64 total;     // total balance in core wei
        uint64 hold;      // amount locked in open orders
        uint64 entryNtl;  // cost basis (informational)
    }

    struct Withdrawable {
        uint64 withdrawable; // perp account exitable equity, 6dp USD
    }

    struct UserVaultEquity {
        uint64 equity;
        uint64 lockedUntilTimestamp;
    }

    struct AccountMarginSummary {
        int64 accountValue;       // 6dp USD — INCLUDES mark-price PnL; do NOT use for NAV
        uint64 marginUsed;
        uint64 ntlPos;            // total notional position
        int64 rawUsd;             // free USD margin
    }

    struct PerpAssetInfo {
        string coin;
        uint32 marginTableId;
        uint8 szDecimals;
        uint8 maxLeverage;
        bool onlyIsolated;
    }

    struct SpotInfo {
        string name;
        uint64[2] tokens; // [baseTokenIdx, quoteTokenIdx]
    }

    struct TokenInfo {
        string name;
        uint64[] spots;          // spot market indices this token participates in
        uint64 deployerTradingFeeShare;
        address deployer;
        address evmContract;     // the linked HyperEVM ERC20 — used by factory validation
        uint8 szDecimals;
        uint8 weiDecimals;
        int8 evmExtraWeiDecimals;
    }

    struct Bbo {
        uint64 bid;
        uint64 ask;
    }

    // -------------------------------------------------------------------------
    // Internal helper — staticcall with safe fallback
    // -------------------------------------------------------------------------

    /// @dev Returns `(ok, retdata)`. On precompile revert returns `(false, "")`.
    function _read(address precompile, bytes memory input) private view returns (bool ok, bytes memory ret) {
        (ok, ret) = precompile.staticcall(input);
        // Treat zero-length return as not-ok so callers fall through to zero.
        if (ok && ret.length == 0) ok = false;
    }

    /// @dev Strict variant: reverts with `PrecompileRevert` on staticcall failure
    ///      or empty return. Used by `*Strict` wrappers where silent fallback
    ///      to zero would be a security issue (NAV reads, trade-gate oracle
    ///      reads). Callers further reject zero with `PrecompileZero` when
    ///      zero is not a valid value (e.g. live market prices).
    function _readStrict(address precompile, bytes memory input) private view returns (bytes memory ret) {
        bool ok;
        (ok, ret) = precompile.staticcall(input);
        if (!ok || ret.length == 0) revert PrecompileRevert(precompile);
    }

    // -------------------------------------------------------------------------
    // NAV-critical reads
    // -------------------------------------------------------------------------

    /// @notice Spot balance for `user` on Core token `tokenIndex`. Returns zeros
    ///         if the account has no row for that token.
    function spotBalance(address user, uint64 tokenIndex) internal view returns (SpotBalance memory bal) {
        (bool ok, bytes memory ret) = _read(
            Constants.SPOT_BALANCE_PRECOMPILE,
            abi.encode(user, tokenIndex)
        );
        if (ok) bal = abi.decode(ret, (SpotBalance));
    }

    /// @notice Strict variant of {spotBalance}: reverts if the precompile
    ///         reverts or returns empty data. Use after the vault's Core account
    ///         has been initialised (any cross-chain action), at which point
    ///         a revert indicates a system failure rather than "no row yet."
    function spotBalanceStrict(address user, uint64 tokenIndex) internal view returns (SpotBalance memory bal) {
        bytes memory ret = _readStrict(
            Constants.SPOT_BALANCE_PRECOMPILE,
            abi.encode(user, tokenIndex)
        );
        bal = abi.decode(ret, (SpotBalance));
    }

    /// @notice Perp account "withdrawable" equity in 6dp USD. This is HL's own
    ///         conservative redeemable-margin figure and is the right number to
    ///         use in NAV — `accountMarginSummary.accountValue` includes
    ///         mark-price PnL and is manipulable on thin markets.
    function withdrawable(address user) internal view returns (Withdrawable memory w) {
        (bool ok, bytes memory ret) = _read(Constants.WITHDRAWABLE_PRECOMPILE, abi.encode(user));
        if (ok) w = abi.decode(ret, (Withdrawable));
    }

    /// @notice Strict variant of {withdrawable}. See {spotBalanceStrict}.
    function withdrawableStrict(address user) internal view returns (Withdrawable memory w) {
        bytes memory ret = _readStrict(Constants.WITHDRAWABLE_PRECOMPILE, abi.encode(user));
        w = abi.decode(ret, (Withdrawable));
    }

    /// @notice Single position. Used by the leverage-cap pre-check.
    function position(address user, uint32 perpIndex) internal view returns (Position memory p) {
        (bool ok, bytes memory ret) = _read(
            Constants.POSITION_PRECOMPILE,
            abi.encode(user, perpIndex)
        );
        if (ok) p = abi.decode(ret, (Position));
    }

    /// @notice Full margin summary. Informational only — do not use accountValue for NAV.
    function accountMarginSummary(address user) internal view returns (AccountMarginSummary memory s) {
        (bool ok, bytes memory ret) = _read(Constants.ACCOUNT_MARGIN_PRECOMPILE, abi.encode(user));
        if (ok) s = abi.decode(ret, (AccountMarginSummary));
    }

    // -------------------------------------------------------------------------
    // Price reads (slippage band)
    // -------------------------------------------------------------------------

    /// @notice Oracle (median, 1-min EMA) price for a perp. Used by the slippage band.
    function oraclePx(uint32 perpIndex) internal view returns (uint64 px) {
        (bool ok, bytes memory ret) = _read(Constants.ORACLE_PX_PRECOMPILE, abi.encode(perpIndex));
        if (ok) px = abi.decode(ret, (uint64));
    }

    /// @notice Strict variant of {oraclePx}: reverts on precompile failure
    ///         AND on a zero return. Use in trade gates — a zero oracle is
    ///         not a legitimate value for any live market.
    function oraclePxStrict(uint32 perpIndex) internal view returns (uint64 px) {
        bytes memory ret = _readStrict(Constants.ORACLE_PX_PRECOMPILE, abi.encode(perpIndex));
        px = abi.decode(ret, (uint64));
        if (px == 0) revert PrecompileZero(Constants.ORACLE_PX_PRECOMPILE);
    }

    /// @notice Mark price (closer to mid). Useful for emergency-close pricing.
    function markPx(uint32 perpIndex) internal view returns (uint64 px) {
        (bool ok, bytes memory ret) = _read(Constants.MARK_PX_PRECOMPILE, abi.encode(perpIndex));
        if (ok) px = abi.decode(ret, (uint64));
    }

    /// @notice Strict variant of {markPx}. See {oraclePxStrict}.
    function markPxStrict(uint32 perpIndex) internal view returns (uint64 px) {
        bytes memory ret = _readStrict(Constants.MARK_PX_PRECOMPILE, abi.encode(perpIndex));
        px = abi.decode(ret, (uint64));
        if (px == 0) revert PrecompileZero(Constants.MARK_PX_PRECOMPILE);
    }

    /// @notice Spot mid price for spot index `spotIndex`.
    function spotPx(uint32 spotIndex) internal view returns (uint64 px) {
        (bool ok, bytes memory ret) = _read(Constants.SPOT_PX_PRECOMPILE, abi.encode(spotIndex));
        if (ok) px = abi.decode(ret, (uint64));
    }

    /// @notice Strict variant of {spotPx}. See {oraclePxStrict}.
    function spotPxStrict(uint32 spotIndex) internal view returns (uint64 px) {
        bytes memory ret = _readStrict(Constants.SPOT_PX_PRECOMPILE, abi.encode(spotIndex));
        px = abi.decode(ret, (uint64));
        if (px == 0) revert PrecompileZero(Constants.SPOT_PX_PRECOMPILE);
    }

    /// @notice Best bid / offer.
    function bbo(uint32 asset) internal view returns (Bbo memory b) {
        (bool ok, bytes memory ret) = _read(Constants.BBO_PRECOMPILE, abi.encode(asset));
        if (ok) b = abi.decode(ret, (Bbo));
    }

    // -------------------------------------------------------------------------
    // Metadata reads (used by factory + integration tooling)
    // -------------------------------------------------------------------------

    function perpAssetInfo(uint32 perpIndex) internal view returns (PerpAssetInfo memory info) {
        (bool ok, bytes memory ret) = _read(Constants.PERP_ASSET_INFO_PRECOMPILE, abi.encode(perpIndex));
        if (ok) info = abi.decode(ret, (PerpAssetInfo));
    }

    function spotInfo(uint32 spotIndex) internal view returns (SpotInfo memory info) {
        (bool ok, bytes memory ret) = _read(Constants.SPOT_INFO_PRECOMPILE, abi.encode(spotIndex));
        if (ok) info = abi.decode(ret, (SpotInfo));
    }

    function tokenInfo(uint32 tokenIndex) internal view returns (TokenInfo memory info) {
        (bool ok, bytes memory ret) = _read(Constants.TOKEN_INFO_PRECOMPILE, abi.encode(tokenIndex));
        if (ok) info = abi.decode(ret, (TokenInfo));
    }

    function l1BlockNumber() internal view returns (uint64 n) {
        (bool ok, bytes memory ret) = _read(Constants.L1_BLOCK_NUMBER_PRECOMPILE, "");
        if (ok) n = abi.decode(ret, (uint64));
    }
}

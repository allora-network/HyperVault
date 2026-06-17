// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {CoreWriterLib} from "./CoreWriterLib.sol";
import {PrecompileLib} from "./PrecompileLib.sol";
import {AssetId} from "./AssetId.sol";
import {Constants} from "./Constants.sol";

/// @title  VaultTradeLib — externalized trade-gate + emergency-close logic
/// @notice Audit G2 (EIP-170): factored out of {HyperCoreVault} so the vault's
///         runtime bytecode fits the 24576-byte contract-size limit (HyperEVM
///         enforces it). Every function here is invoked by the vault via
///         DELEGATECALL, so `address(this)` is the vault: CoreWriter sees the
///         vault as the order's sender and the precompile reads resolve the
///         vault's own Core positions, exactly as when this code was inlined.
///
/// @dev    Behaviour is byte-for-byte preserved from the prior inlined version
///         (slippage bands H-3/H-4, leverage cap, bug_009 size scaling, M4
///         close band, cloid sequencing, emitted log). The events and errors
///         below MIRROR {IHyperCoreVault} with identical signatures, so logs
///         (topic0) and revert selectors are indistinguishable from the
///         in-vault originals across the delegatecall boundary. Storage is NOT
///         touched here: NAV / open-notional / cloid are computed by the vault
///         and threaded in by value; the vault persists the returned cloid.
library VaultTradeLib {
    using EnumerableSet for EnumerableSet.UintSet;

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

    error SlippageBandExceeded(uint64 limitPx, uint64 oraclePx, uint16 bandBps);
    error LeverageCapExceeded(uint256 grossNotional, uint256 nav, uint16 capBps);
    error EmergencyCloseBandExceeded(uint64 limitPx, uint64 markPx, uint16 bandBps);
    error AssetNotWhitelisted(uint32 asset);

    /// @dev Bundled args for {placeOrderChecked}. A single calldata struct keeps
    ///      the external-library call within the EVM stack limit (the gate needs
    ///      >16 live values otherwise) without forcing a project-wide via-IR
    ///      build. `nav`/`cloid` are computed and issued by the vault; the
    ///      band/cap config is read from vault storage by the wrapper. The
    ///      whitelist sets and open-notional sum are evaluated here (the sets are
    ///      passed by storage reference) so the loop + EnumerableSet machinery
    ///      lives in this library, not in the vault's bytecode.
    struct OrderParams {
        uint32 asset;
        bool isBuy;
        uint64 limitPx;
        uint64 sz;
        bool reduceOnly;
        uint8 tif;
        uint128 cloid;
        uint16 slippageBandBps;
        uint16 spotBand;
        uint64 spotScale;
        uint16 leverageCapBps;
        uint256 nav;
    }

    /// @notice Slippage-band + leverage-cap gate, then dispatch the limit order.
    /// @dev    The whitelist gate, management-fee accrual and cloid issuance stay
    ///         in the vault wrapper (they touch vault storage). `nav` is the
    ///         vault's {totalAssets} read; it doubles as the event's navSnapshot
    ///         (a CoreWriter submit does not settle synchronously, so NAV is
    ///         unchanged across the call — identical to the value the inlined
    ///         code emitted). `grossExisting` is the vault's
    ///         `_grossOpenPerpNotional6dp()` (0 when the leverage check is not
    ///         applicable). Perp band reads `slippageBandBps`; spot band reads
    ///         the per-asset `spotBand` + calibrated `spotScale` (M6).
    function placeOrderChecked(
        OrderParams calldata p,
        EnumerableSet.UintSet storage whitelistedPerps,
        EnumerableSet.UintSet storage whitelistedSpots
    ) external {
        // Whitelist gate — perps and spots are tracked in separate sets.
        if (AssetId.isPerp(p.asset)) {
            if (!whitelistedPerps.contains(p.asset)) revert AssetNotWhitelisted(p.asset);
        } else {
            if (!whitelistedSpots.contains(p.asset)) revert AssetNotWhitelisted(p.asset);
        }

        // Slippage band — perps use oraclePx, spots use spotPx (audit H-3, H-4).
        // Scale reconciliation (verified on HyperEVM mainnet):
        //   oraclePx precompile        = human * 10^(6 - szDecimals)
        //   limit_order action limitPx = human * 10^8   (UNIFORM; NOT szDecimals-based)
        // Normalize oraclePx UP to the 10^8 action scale: factor 10^(2 + szDecimals).
        // Audit H-4: oraclePx AND szDecimals are read strictly — a zero/reverting
        // oracle, or a failed asset-info read, fails the trade closed.
        if (AssetId.isPerp(p.asset) && p.slippageBandBps > 0) {
            uint64 oraclePxRaw = PrecompileLib.oraclePxStrict(p.asset);
            uint256 szDec = uint256(PrecompileLib.perpAssetInfoStrict(p.asset).szDecimals);
            uint256 oracleNorm = uint256(oraclePxRaw) * (10 ** (szDec + 2));
            uint256 limitPxU = uint256(p.limitPx);
            uint256 diff = limitPxU > oracleNorm ? limitPxU - oracleNorm : oracleNorm - limitPxU;
            uint256 maxDiff = (oracleNorm * p.slippageBandBps) / Constants.BPS;
            if (diff > maxDiff) revert SlippageBandExceeded(p.limitPx, oraclePxRaw, p.slippageBandBps);
        } else if (AssetId.isSpot(p.asset)) {
            // Audit H-3 + M6: per-spot-asset slippage band. Normalize spotPx
            // (precompile scale) to the 10^8 action scale with the admin's
            // calibrated, asset-specific `spotScale` before comparing.
            if (p.spotBand > 0) {
                uint64 spotPxRaw = PrecompileLib.spotPxStrict(AssetId.indexOf(p.asset));
                uint256 spotPxNorm = uint256(spotPxRaw) * uint256(p.spotScale);
                uint256 limitPxU = uint256(p.limitPx);
                uint256 diff = limitPxU > spotPxNorm ? limitPxU - spotPxNorm : spotPxNorm - limitPxU;
                uint256 maxDiff = (spotPxNorm * p.spotBand) / Constants.BPS;
                if (diff > maxDiff) revert SlippageBandExceeded(p.limitPx, spotPxRaw, p.spotBand);
            }
        }

        // Leverage cap — incremental new-order notional + sum of open perp notionals.
        // order notional: sz, limitPx both in the 10^8 action scale, so
        // sz*limitPx = human*human*10^16; /1e10 -> 6dp USD.
        if (!p.reduceOnly && AssetId.isPerp(p.asset) && p.leverageCapBps > 0) {
            uint256 gross = _grossOpenPerpNotional6dp(whitelistedPerps) + (uint256(p.sz) * uint256(p.limitPx)) / 1e10;
            uint256 capUsd = (p.nav * p.leverageCapBps) / Constants.BPS;
            if (gross > capUsd) revert LeverageCapExceeded(gross, p.nav, p.leverageCapBps);
        }

        CoreWriterLib.placeLimitOrder(p.asset, p.isBuy, p.limitPx, p.sz, p.reduceOnly, p.tif, p.cloid);
        emit LimitOrderSubmitted(p.asset, p.isBuy, p.limitPx, p.sz, p.reduceOnly, p.tif, p.cloid, p.nav);
    }

    /// @dev Sum of |position| * markPx over the whitelisted perps, in the 10^8*10^8
    ///      product scale used by the leverage cap. Ultrareview bug_007: positions
    ///      are read leniently on purpose — the loop spans ALL whitelisted perps
    ///      and HyperCore reverts/returns empty for a flat perp, so a strict read
    ///      would revert every trade whenever any whitelisted perp is flat. markPx
    ///      is read strictly. Residual (a POSITION failure on a HELD perp
    ///      under-counts its notional) is documented best-effort in docs/SECURITY.md.
    function _grossOpenPerpNotional6dp(EnumerableSet.UintSet storage whitelistedPerps)
        private
        view
        returns (uint256 total)
    {
        uint256[] memory perps = whitelistedPerps.values();
        for (uint256 i; i < perps.length; ++i) {
            uint32 a = uint32(perps[i]);
            int64 szi = PrecompileLib.position(address(this), a).szi;
            if (szi == 0) continue;
            uint64 mPx = PrecompileLib.markPxStrict(a);
            // Audit L3: widen through int256 so `-szi` cannot overflow at int64.min.
            uint64 absSz = uint64(szi < 0 ? uint256(-int256(szi)) : uint256(int256(szi)));
            total += uint256(absSz) * uint256(mPx);
        }
    }

    /// @notice Close open perp positions via opposite-side reduce-only IOC orders.
    /// @dev    Issues cloids from `startCloid`, returns the next free cloid for
    ///         the vault to persist. `nav` is the event snapshot (constant across
    ///         the loop; CoreWriter is async). Audit M4: when `enforceBand` and
    ///         `band > 0`, each supplied price is sanity-bounded against the
    ///         strict markPx (normalized to the 10^8 action scale). bug_009: the
    ///         position `szi` (szDecimals lots) is rescaled to the uniform 10^8
    ///         action size; szDecimals/markPx are read strictly (fail closed).
    function emergencyClose(
        uint32[] calldata perpAssets,
        uint64[] calldata limitPxs,
        bool enforceBand,
        uint16 band,
        uint128 startCloid,
        uint256 nav
    ) external returns (uint128 nextCloid) {
        require(perpAssets.length == limitPxs.length, "len");
        nextCloid = startCloid;
        for (uint256 i; i < perpAssets.length; ++i) {
            // Per-position work lives in a helper so the loop's live-variable set
            // stays within the EVM stack limit (avoids a project-wide via-IR build).
            if (_closeOnePosition(perpAssets[i], limitPxs[i], enforceBand, band, nextCloid, nav)) {
                nextCloid++;
            }
        }
    }

    /// @dev Close one perp position with an opposite-side reduce-only IOC. Returns
    ///      true when an order was placed (a cloid was consumed), false when the
    ///      position was flat. See {emergencyClose} for the audit references.
    function _closeOnePosition(uint32 a, uint64 limitPx, bool enforceBand, uint16 band, uint128 cloid, uint256 nav)
        private
        returns (bool placed)
    {
        int64 szi = PrecompileLib.position(address(this), a).szi;
        if (szi == 0) return false;
        // Audit L3: widen through int256 so `-szi` cannot overflow at int64.min.
        uint64 absSz = uint64(szi < 0 ? uint256(-int256(szi)) : uint256(int256(szi)));
        uint8 szDec = PrecompileLib.perpAssetInfoStrict(a).szDecimals;

        if (enforceBand && band > 0) {
            uint64 markRaw = PrecompileLib.markPxStrict(a);
            uint256 markNorm = uint256(markRaw) * (10 ** (uint256(szDec) + 2));
            uint256 lpx = uint256(limitPx);
            uint256 diff = lpx > markNorm ? lpx - markNorm : markNorm - lpx;
            if (diff > (markNorm * band) / Constants.BPS) {
                revert EmergencyCloseBandExceeded(limitPx, markRaw, band);
            }
        }

        // bug_009: rescale szDecimals lots -> uniform 10^8 action size.
        uint64 sz = uint64(uint256(absSz) * (10 ** (8 - szDec)));
        bool isBuy = szi < 0; // close: sell if currently long, buy if currently short
        CoreWriterLib.placeLimitOrder(a, isBuy, limitPx, sz, true, Constants.TIF_IOC, cloid);
        emit LimitOrderSubmitted(a, isBuy, limitPx, sz, true, Constants.TIF_IOC, cloid, nav);
        return true;
    }

    /// @notice Audit M6: the factor the admin should START from when calibrating
    ///         {HyperCoreVault.setSpotSlippageBand} — derived by mirroring the perp
    ///         band, i.e. 10^(2 + baseTokenSzDecimals) where the base token is
    ///         `spotInfo(idx).tokens[0]`. This ASSUMES spotPx follows the perp
    ///         `human * 10^(6 - szDecimals)` family; because that is not guaranteed
    ///         for every spot market, this is guidance only — the admin MUST confirm
    ///         it against a live test order before calling {setSpotSlippageBand}.
    /// @dev    EIP-170 (M4 / SOLU-3366): hoisted out of the vault into this library
    ///         (the established VaultTradeLib split). In the vault the `10 ** x` here
    ///         dragged in the full runtime-exponentiation routine (~1.2 KB) that the
    ///         vault otherwise never needs; this library already uses `10 ** x` for
    ///         its price scaling, so the routine is SHARED here at ~no incremental
    ///         cost, freeing the headroom the soft redemption barriers need. Same
    ///         signature, pure-read (no storage), so the vault wrapper is behaviour-
    ///         identical under delegatecall (`address(this)` == the vault).
    function suggestedSpotPxScaleFactor(uint32 asset_) external view returns (uint64) {
        uint32 idx = AssetId.indexOf(asset_);
        uint64 baseToken = PrecompileLib.spotInfo(idx).tokens[0];
        uint256 szDec = uint256(PrecompileLib.tokenInfo(uint32(baseToken)).szDecimals);
        return uint64(10 ** (szDec + 2));
    }
}

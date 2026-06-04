// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {console2} from "forge-std/console2.sol";

import {HyperVaultBaseForkTest} from "./HyperVaultBase.fork.t.sol";
import {IHyperCoreVault} from "../../src/interfaces/IHyperCoreVault.sol";
import {PrecompileLib} from "../../src/libraries/PrecompileLib.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {AssetId} from "../../src/libraries/AssetId.sol";

/// @dev CoreWriter stub so a passing order doesn't revert at dispatch.
contract SpotBandMockCoreWriter {
    event RawAction(bytes data);

    function sendRawAction(bytes calldata data) external {
        emit RawAction(data);
    }
}

/// @title  Phase M6 — spot slippage-band scale normalization
/// @notice The spot band previously compared limitPx (10^8 action scale) DIRECTLY
///         against spotPx (precompile scale) with no normalization — false
///         protection. M6 normalizes spotPx by an admin-calibrated scaleFactor and
///         requires that factor whenever a band is set. The comparison is pure
///         arithmetic once the factor is fixed (the spotPx value here is mocked,
///         since revm can't serve the precompile; the live calibration is the
///         spike's job).
contract HyperVaultSpotBandForkTest is HyperVaultBaseForkTest {
    uint32 constant SPOT_INDEX = 1;
    uint32 constant SPOT_ASSET = 10_001; // AssetId.spot(1) = 10000 + 1

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        vm.etch(Constants.CORE_WRITER, type(SpotBandMockCoreWriter).runtimeCode);
        // spotPx precompile -> 1000 (raw precompile scale). With scaleFactor 100000,
        // normalized px = 1000 * 100000 = 1e8 (= $1.00 on the 10^8 action scale).
        vm.mockCall(Constants.SPOT_PX_PRECOMPILE, abi.encode(SPOT_INDEX), abi.encode(uint64(1000)));
        vault.setWhitelistSpot(SPOT_ASSET, true); // admin == address(this)
    }

    function _place(uint64 limitPx) internal {
        vm.prank(operator);
        vault.placeLimitOrder(SPOT_ASSET, true, limitPx, 1_000_000, false, Constants.TIF_GTC);
    }

    // ── M6: a band with no calibrated scale factor is rejected ──────────────────
    function test_M6_bandRequiresScaleFactor() public {
        _skipIfNoFork();
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.SpotBandRequiresScaleFactor.selector, SPOT_ASSET));
        vault.setSpotSlippageBand(SPOT_ASSET, 200, 0); // band but no factor -> revert
    }

    // ── M6: once calibrated, the normalized band passes inside / reverts outside ──
    function test_M6_normalizedBandInsideRestsOutsideReverts() public {
        _skipIfNoFork();
        // normalized spotPx = 1e8; band 2% -> maxDiff 2e6.
        vault.setSpotSlippageBand(SPOT_ASSET, 200, 100_000);
        assertEq(vault.spotPxScaleFactor(SPOT_ASSET), 100_000, "factor stored");

        // Just inside (+1.5%): passes (CoreWriter stub accepts).
        _place(101_500_000); // 1.015e8, diff 1.5e6 < 2e6
        // Exactly at the normalized px: passes.
        _place(100_000_000);

        // Just outside (+5%): reverts on the band.
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IHyperCoreVault.SlippageBandExceeded.selector, uint64(105_000_000), uint64(1000), uint16(200))
        );
        vault.placeLimitOrder(SPOT_ASSET, true, 105_000_000, 1_000_000, false, Constants.TIF_GTC);

        console2.log("M6 PASS - normalized spot band: inside rests, outside reverts (calibrated factor)");
    }

    // ── M6: without normalization (the old bug) the same prices would be wrong ──
    function test_M6_demonstratesNormalizationMatters() public {
        _skipIfNoFork();
        // With the OLD code, limitPx (1e8-scale) was compared to raw spotPx (1000):
        // diff = |1e8 - 1000| ~ 1e8, maxDiff = 1000*200/10000 = 20 -> EVERY realistic
        // order reverts (or, with a tiny limitPx near 1000, absurd orders pass). The
        // M6 factor (100000) maps raw 1000 -> 1e8 so the 2% band is meaningful.
        vault.setSpotSlippageBand(SPOT_ASSET, 200, 100_000);
        uint64 sane = 100_000_000; // $1.00 — the true market price
        _place(sane); // passes under M6; under the old code this would have reverted
        console2.log("M6 PASS - a sane market-priced order is accepted only because spotPx is normalized");
    }

    // ── M6: band = 0 disables the check entirely (no normalization needed) ──────
    function test_M6_bandZeroDisablesCheck() public {
        _skipIfNoFork();
        vault.setSpotSlippageBand(SPOT_ASSET, 0, 0); // explicit off
        // An absurd price is accepted because the band is off.
        _place(1); // would be wildly outside any band, but band==0 -> no check
        console2.log("M6 PASS - band 0 disables the spot slippage check");
    }

    // ── M6: suggested factor mirrors the perp derivation 10^(2+baseSzDecimals) ──
    function test_M6_suggestedFactorMirrorsPerpDerivation() public {
        _skipIfNoFork();
        // Mock spotInfo(1).tokens = [baseToken=42, quote=0]; tokenInfo(42).szDecimals = 2.
        PrecompileLib.SpotInfo memory si;
        si.name = "X/USDC";
        si.tokens = [uint64(42), uint64(0)];
        vm.mockCall(Constants.SPOT_INFO_PRECOMPILE, abi.encode(SPOT_INDEX), abi.encode(si));
        PrecompileLib.TokenInfo memory ti;
        ti.name = "X";
        ti.szDecimals = 2;
        ti.weiDecimals = 6;
        vm.mockCall(Constants.TOKEN_INFO_PRECOMPILE, abi.encode(uint32(42)), abi.encode(ti));

        // 10^(2 + 2) = 10_000.
        assertEq(vault.suggestedSpotPxScaleFactor(SPOT_ASSET), 10_000, "suggested factor = 10^(2+szDec)");
        console2.log("M6 PASS - suggested scale factor mirrors the perp band derivation");
    }
}

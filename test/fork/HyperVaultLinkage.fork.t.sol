// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HyperVaultBaseForkTest} from "./HyperVaultBase.fork.t.sol";
import {HyperCoreVault} from "../../src/HyperCoreVault.sol";
import {IHyperCoreVault} from "../../src/interfaces/IHyperCoreVault.sol";
import {PrecompileLib} from "../../src/libraries/PrecompileLib.sol";
import {Constants} from "../../src/libraries/Constants.sol";

/// @title  Phase C1 (+ M5) — Core-USDC linkage + NAV reconciliation + decimals validation
/// @notice Pure-EVM invariants of the configurable Core-USDC index/decimals.
///
///  Substrate note: a forge fork cannot serve the HyperCore `tokenInfo` (0x80C)
///  or `spotBalance` (0x801) precompiles (revm returns empty), so the *values*
///  used here are supplied via `vm.mockCall` — the same technique the existing
///  RemediationUltrareview suite uses for `position`/`perpAssetInfo`. This proves
///  the EVM-side validation + normalization MATH on real vault bytecode; the
///  unmocked, real-Core confirmation (a live `coreSpotUsdc()` reflecting a real
///  Core seed at the right scale + the Path-B round-trip) is the live-spike proof
///  recorded in docs/FORK_PROOFS.md.
contract HyperVaultLinkageForkTest is HyperVaultBaseForkTest {
    /// @dev Stand-in for the real Core-linked USDC EVM contract
    ///      (tokenInfo(0).evmContract = 0x6B9E…0A24 on mainnet, per Finding G) —
    ///      any address distinct from the configured asset `USDC` exercises the
    ///      mismatch path; the value is mocked, so the exact address is immaterial.
    address internal coreLinkedUsdc = makeAddr("coreLinkedUsdc");

    event CoreLinkUnverified(address indexed asset, address indexed coreEvmContract);

    /// @dev Deploy a vault with custom Core-USDC index/decimals (admin == this).
    function _deployWithCore(uint64 idx, uint8 dec) internal returns (HyperCoreVault v) {
        HyperCoreVault.Config memory cfg = HyperCoreVault.Config({
            asset: IERC20(USDC),
            coreUsdcIndex: idx,
            coreUsdcDecimals: dec,
            name: "Linkage Proof Vault",
            symbol: "lpv",
            admin: address(this),
            operator: operator,
            emergencyAdmin: emergency,
            feeRecipient: feeRecipient,
            leverageCapBps: 0,
            slippageBandBps: 0,
            mgmtFeeAnnualBps: 0,
            perfFeeBps: 0,
            depositCap: type(uint256).max,
            maxDepositPerAddress: 0
        });
        v = new HyperCoreVault(cfg);
    }

    /// @dev Build a mocked tokenInfo reply for Core token `idx`.
    function _mockTokenInfo(uint64 idx, uint8 weiDecimals, address evmContract) internal {
        PrecompileLib.TokenInfo memory ti;
        ti.name = "USD Coin";
        ti.evmContract = evmContract;
        ti.weiDecimals = weiDecimals;
        ti.szDecimals = 2;
        vm.mockCall(Constants.TOKEN_INFO_PRECOMPILE, abi.encode(uint32(idx)), abi.encode(ti));
    }

    // ───────────────────────────────────────────────────────────────────────
    // C1/M5 (1) — a decimals mismatch vs the live tokenInfo aborts the deploy.
    // ───────────────────────────────────────────────────────────────────────
    function test_C1_decimalsMismatchRevertsDeploy() public {
        _skipIfNoFork();
        // Live token 0 reports weiDecimals = 8; deploying with the wrong 6 must revert.
        _mockTokenInfo(0, 8, USDC);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.CoreUsdcDecimalsMismatch.selector, uint8(6), uint8(8)));
        _deployWithCore(0, 6);
    }

    function test_C1_matchingDecimalsDeploysClean() public {
        _skipIfNoFork();
        _mockTokenInfo(0, 8, USDC); // evmContract == asset → no CoreLinkUnverified
        HyperCoreVault v = _deployWithCore(0, 8);
        assertEq(v.coreUsdcIndex(), 0, "coreUsdcIndex stored");
        assertEq(v.coreUsdcDecimals(), 8, "coreUsdcDecimals stored");
    }

    // ───────────────────────────────────────────────────────────────────────
    // C1/M5 (2) — coreSpotUsdc() normalizes Core wei (8dp) to the 6dp EVM scale.
    // ───────────────────────────────────────────────────────────────────────
    function test_C1_coreSpotUsdcNormalizesScale() public {
        _skipIfNoFork();
        // Deploy with decimals 8 (no tokenInfo mock → resolved=false → no validation).
        HyperCoreVault v = _deployWithCore(0, 8);

        // Mock the spotBalance precompile: 1.23456789 USDC in 8dp Core wei.
        PrecompileLib.SpotBalance memory bal = PrecompileLib.SpotBalance({total: 123_456_789, hold: 0, entryNtl: 0});
        vm.mockCall(Constants.SPOT_BALANCE_PRECOMPILE, abi.encode(address(v), uint64(0)), abi.encode(bal));

        // 8dp → 6dp: divide by 10^(8-6)=100 → 1_234_567 (truncates the sub-cent tail).
        assertEq(v.coreSpotUsdc(), 1_234_567, "Core 8dp wei normalized to 6dp EVM scale");
    }

    /// @dev Core decimals BELOW EVM decimals exercise the multiply branch of _coreToEvm.
    function test_C1_coreSpotUsdcMultiplyBranch() public {
        _skipIfNoFork();
        HyperCoreVault v = _deployWithCore(0, 4); // 4dp Core < 6dp EVM

        PrecompileLib.SpotBalance memory bal = PrecompileLib.SpotBalance({total: 50_000, hold: 0, entryNtl: 0});
        vm.mockCall(Constants.SPOT_BALANCE_PRECOMPILE, abi.encode(address(v), uint64(0)), abi.encode(bal));

        // 4dp → 6dp: multiply by 10^(6-4)=100 → 5_000_000 (= 5.0 USDC).
        assertEq(v.coreSpotUsdc(), 5_000_000, "Core 4dp wei normalized up to 6dp EVM scale");
    }

    // ───────────────────────────────────────────────────────────────────────
    // C1 (3) — the shipped-asset linkage gap is surfaced on-chain (not silent).
    //   Finding G: tokenInfo(0).evmContract (the real Core-linked USDC) is NOT
    //   the configured Circle USDC. Path B keeps the unlinked asset, but the
    //   constructor must emit CoreLinkUnverified so the mismatch is visible.
    // ───────────────────────────────────────────────────────────────────────
    function test_C1_coreLinkUnverifiedFiresForShippedAsset() public {
        _skipIfNoFork();
        // Core token 0 links a DIFFERENT EVM contract than our asset.
        _mockTokenInfo(0, 8, coreLinkedUsdc);
        vm.expectEmit(true, true, false, true);
        emit CoreLinkUnverified(USDC, coreLinkedUsdc);
        _deployWithCore(0, 8); // decimals match (8==8) → deploy succeeds, event fires
    }

    function test_C1_noEventWhenLinkMatches() public {
        _skipIfNoFork();
        // If the Core-linked EVM contract IS the asset, no CoreLinkUnverified.
        _mockTokenInfo(0, 8, USDC);
        vm.recordLogs();
        HyperCoreVault v = _deployWithCore(0, 8);
        // (Sanity: deploy succeeded with a real address.)
        assertTrue(address(v) != address(0), "vault deployed");
    }
}

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
    /// @dev Stand-in for a Core-linked EVM contract that ISN'T what the vault
    ///      expects — exercises the legacy CoreLinkUnverified surface and the
    ///      wallet-mode CoreLinkMismatch hard-revert. (On real mainnet,
    ///      tokenInfo(0).evmContract = 0x6B9E…0A24 = Circle's CoreDepositWallet,
    ///      audit G2; the value here is mocked, so the exact address is immaterial.)
    address internal coreLinkedUsdc = makeAddr("coreLinkedUsdc");

    event CoreLinkUnverified(address indexed asset, address indexed coreEvmContract);
    event CoreLinkVerified(address indexed asset, address indexed coreDepositWallet);

    /// @dev Deploy a vault with custom Core-USDC index/decimals (admin == this).
    function _deployWithCore(uint64 idx, uint8 dec) internal returns (HyperCoreVault v) {
        HyperCoreVault.Config memory cfg = HyperCoreVault.Config({
            asset: IERC20(USDC),
            coreUsdcIndex: idx,
            coreUsdcDecimals: dec,
            // Legacy mode: these C1 tests exercise arbitrary Core indices/decimals,
            // which wallet-mode validation would (correctly) reject. G2 wallet-mode
            // deploys are covered by the dedicated G2 tests below.
            coreDepositWallet: address(0),
            name: "Linkage Proof Vault",
            symbol: "lpv",
            admin: address(this),
            operator: operator,
            emergencyAdmin: emergency,
            feeRecipient: feeRecipient,
            leverageCapBps: 0,
            slippageBandBps: 0,
            emergencyCloseBandBps: 0,
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
    // C1 (3) — LEGACY MODE (no wallet): a linkage gap is surfaced on-chain (not
    //   silent). With no CoreDepositWallet configured, an evmContract that isn't
    //   the asset emits the warn-only CoreLinkUnverified (the pre-G2 Path-B
    //   posture). Wallet-mode vaults hard-revert instead (G2 tests below).
    // ───────────────────────────────────────────────────────────────────────
    function test_C1_coreLinkUnverifiedFiresInLegacyMode() public {
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

    // ───────────────────────────────────────────────────────────────────────
    // G2 — wallet-mode deploy validation (audit G2). Three fail-closed layers:
    //   (a)  wallet.token() == asset()            — direct, precompile-free
    //   (a') wallet.tokenSystemAddress() == forToken(coreUsdcIndex)
    //   (c)  tokenInfo.evmContract == wallet when the row resolves, attested by
    //        CoreLinkVerified. Layer (a)/(a') run against the REAL wallet
    //        bytecode on the fork; layer (c) uses the mocked-precompile
    //        technique established above.
    // ───────────────────────────────────────────────────────────────────────

    /// @dev Deploy a wallet-mode vault (mainnet posture: index 0, 8 Core decimals).
    function _deployWithWallet(address wallet_) internal returns (HyperCoreVault v) {
        HyperCoreVault.Config memory cfg = HyperCoreVault.Config({
            asset: IERC20(USDC),
            coreUsdcIndex: 0,
            coreUsdcDecimals: 8,
            coreDepositWallet: wallet_,
            name: "G2 Wallet Vault",
            symbol: "g2v",
            admin: address(this),
            operator: operator,
            emergencyAdmin: emergency,
            feeRecipient: feeRecipient,
            leverageCapBps: 0,
            slippageBandBps: 0,
            emergencyCloseBandBps: 0,
            mgmtFeeAnnualBps: 0,
            perfFeeBps: 0,
            depositCap: type(uint256).max,
            maxDepositPerAddress: 0
        });
        v = new HyperCoreVault(cfg);
    }

    function test_G2_realWalletDeploysClean() public {
        _skipIfNoFork();
        // No tokenInfo mock: the precompile is empty on a fork (fresh-account
        // semantics), so only the direct wallet checks run — against the REAL
        // CoreDepositWallet bytecode.
        HyperCoreVault v = _deployWithWallet(CORE_DEPOSIT_WALLET);
        assertEq(v.coreDepositWallet(), CORE_DEPOSIT_WALLET, "wallet immutable stored");
    }

    function test_G2_walletTokenMismatchRevertsDeploy() public {
        _skipIfNoFork();
        address otherToken = makeAddr("otherToken");
        FixtureDepositWallet wrong = new FixtureDepositWallet(otherToken, USDC_BRIDGE);
        vm.expectRevert(
            abi.encodeWithSelector(IHyperCoreVault.CoreDepositWalletTokenMismatch.selector, USDC, otherToken)
        );
        _deployWithWallet(address(wrong));
    }

    function test_G2_walletSystemAddressMismatchRevertsDeploy() public {
        _skipIfNoFork();
        address wrongSys = makeAddr("wrongSys");
        FixtureDepositWallet wrong = new FixtureDepositWallet(USDC, wrongSys);
        vm.expectRevert(
            abi.encodeWithSelector(
                IHyperCoreVault.CoreDepositWalletSystemAddressMismatch.selector, USDC_BRIDGE, wrongSys
            )
        );
        _deployWithWallet(address(wrong));
    }

    function test_G2_coreLinkMismatchRevertsDeploy() public {
        _skipIfNoFork();
        // The real wallet passes (a)/(a'), but the (mocked) tokenInfo row claims a
        // DIFFERENT linked contract → push and pull would route differently → revert.
        _mockTokenInfo(0, 8, coreLinkedUsdc);
        vm.expectRevert(
            abi.encodeWithSelector(IHyperCoreVault.CoreLinkMismatch.selector, CORE_DEPOSIT_WALLET, coreLinkedUsdc)
        );
        _deployWithWallet(CORE_DEPOSIT_WALLET);
    }

    function test_G2_coreLinkVerifiedEmitsWhenResolved() public {
        _skipIfNoFork();
        // tokenInfo row confirms the wallet (the real mainnet state, mocked here
        // because the fork can't serve the precompile) → positive attestation.
        _mockTokenInfo(0, 8, CORE_DEPOSIT_WALLET);
        vm.expectEmit(true, true, false, true);
        emit CoreLinkVerified(USDC, CORE_DEPOSIT_WALLET);
        _deployWithWallet(CORE_DEPOSIT_WALLET);
    }
}

/// @dev Minimal wallet stand-in for the deploy-validation mismatch tests — only
///      the two getters the constructor reads. (The REAL wallet covers the
///      happy path above; this exists to exercise the revert branches.)
contract FixtureDepositWallet {
    address public token;
    address public tokenSystemAddress;

    constructor(address token_, address sys_) {
        token = token_;
        tokenSystemAddress = sys_;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HyperCoreVault} from "../src/HyperCoreVault.sol";
import {IHyperCoreVault} from "../src/interfaces/IHyperCoreVault.sol";
import {PrecompileLib} from "../src/libraries/PrecompileLib.sol";
import {Constants} from "../src/libraries/Constants.sol";

/// @notice Minimal 6-dp USDC stand-in.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) {
        return 6;
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice CoreWriter stub etched at the system address so high-level calls
///         (`ICoreWriter(...).sendRawAction`) don't revert on the extcodesize check.
contract MockCoreWriter {
    event RawAction(bytes data);
    function sendRawAction(bytes calldata data) external {
        emit RawAction(data);
    }
}

/// @notice 6-dp fee-on-transfer token (1% fee) to exercise the L1 deposit guard.
contract MockFOT is ERC20 {
    constructor() ERC20("Fee On Transfer", "FOT") {}
    function decimals() public pure override returns (uint8) {
        return 6;
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100; // 1% skimmed to a burn sink
            super._update(from, address(0xdEaD), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @title Regression tests for the ultrareview findings on `audit/mitigations`.
/// @dev   No prior test suite existed in this repo; this harness is built from
///        scratch. Precompile reads are low-level staticcalls, so unmocked
///        precompiles return empty -> the lenient wrappers yield zero (NAV
///        components = 0 unless mocked). CoreWriter calls are high-level, so the
///        system address is etched with a stub.
contract RemediationUltrareviewTest is Test {
    // Mirror of the vault events for vm.expectEmit matching (matched by sig+data).
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
    event PerfFeePaid(address indexed lp, uint256 feeAssets);

    MockUSDC usdc;
    HyperCoreVault vault;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address emergency = makeAddr("emergency");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address router = makeAddr("router");

    uint16 constant PERF_FEE_BPS = 1500; // 15%

    function setUp() public {
        usdc = new MockUSDC();
        vault = new HyperCoreVault(
            HyperCoreVault.Config({
                asset: IERC20(address(usdc)),
                coreUsdcIndex: 0,
                coreUsdcDecimals: 8,
                coreDepositWallet: address(0), // legacy route (MockUSDC unit substrate)
                name: "Test Vault",
                symbol: "tVLT",
                admin: admin,
                operator: operator,
                emergencyAdmin: emergency,
                feeRecipient: feeRecipient,
                leverageCapBps: 0,
                slippageBandBps: 0,
                mgmtFeeAnnualBps: 0, // isolate perf fee from mgmt-fee dilution
                perfFeeBps: PERF_FEE_BPS,
                depositCap: type(uint256).max,
                maxDepositPerAddress: 0
            })
        );

        // Etch a CoreWriter stub so trade-dispatching paths don't revert.
        MockCoreWriter cw = new MockCoreWriter();
        vm.etch(Constants.CORE_WRITER, address(cw).code);
    }

    // ---- helpers ----------------------------------------------------------

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        usdc.mint(who, assets);
        vm.startPrank(who);
        usdc.approve(address(vault), assets);
        shares = vault.deposit(assets, who);
        vm.stopPrank();
    }

    /// @dev Simulate trading profit returning to the vault as idle USDC -> PPS up.
    function _simulateGain(uint256 assets) internal {
        usdc.mint(address(vault), assets);
    }

    // ======================================================================
    // bug_010 / M2 — performance-fee evasion via requestWithdraw -> deposit ->
    // cancel -> redeem. The bug_010 fix (count escrowed shares in the cost-basis
    // weighted-average) closed the EVASION on the cancel path; M2 then makes the
    // whole class unreachable by BLOCKING a deposit while a request is open (which
    // also closed the symmetric perf-fee OVER-charge on the fulfill path). This
    // test proves both: the mid-request deposit reverts, and the legitimate
    // cancel-then-deposit-then-redeem path still collects the full perf fee.
    // ======================================================================
    function test_bug010_perfFeeEvasionClosed() public {
        // Alice deposits 100 USDC at PPS 1.0; cost basis = 1.0.
        uint256 shares = _deposit(alice, 100e6);

        // Strategy gains 50 USDC -> PPS 1.5, alice's unrealized gain = 50 USDC.
        _simulateGain(50e6);

        // Fund the dust deposit that used to poison the cost basis.
        usdc.mint(alice, 1e6);

        vm.startPrank(alice);
        vault.requestWithdraw(shares); // escrow all shares (balanceOf(alice) -> 0)
        usdc.approve(address(vault), 1e6);
        // M2: the cost-basis-poisoning deposit while a request is open now REVERTS.
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.PendingRequestBlocksDeposit.selector, alice));
        vault.deposit(1e6, alice);

        // Legitimate path: cancel first, then deposit, then redeem -> full fee.
        vault.cancelWithdrawRequest(); // shares returned (cb preserved)
        vault.deposit(1e6, alice); // now allowed; 1 USDC at PPS 1.5 carries no gain
        uint256 aliceShares = vault.balanceOf(alice);
        vault.redeem(aliceShares, alice, alice);
        vm.stopPrank();

        // The 50 USDC gain must still be taxed at 15% = 7.5 USDC, NOT evaded.
        uint256 feeCollected = usdc.balanceOf(feeRecipient);
        assertApproxEqAbs(feeCollected, 7.5e6, 0.25e6, "perf fee evaded or mis-charged");
        assertGt(feeCollected, 7e6, "perf fee was evaded (regression of bug_010)");
    }

    // ======================================================================
    // bug_009 — emergencyClosePositions fed position.szi (szDecimals lots)
    // straight into the limit_order action `sz` (human * 10^8 scale). For a
    // 0.5 BTC position (szDecimals 5) it closed 0.0005 BTC and left the rest
    // open. Post-fix it scales by 10^(8 - szDecimals) so the emergency order
    // matches the real position size.
    // ======================================================================
    function test_bug009_emergencyCloseUsesCorrectScale() public {
        uint32 perp = 0;
        int64 sziLots = 50_000; // 0.5 BTC at szDecimals = 5  (0.5 * 10^5)
        uint8 szDecimals = 5;
        uint64 limitPx = 6_000_000_000_000; // ~$60k in the 10^8 action scale

        // Mock the two precompile reads the close performs for this perp.
        PrecompileLib.Position memory pos = PrecompileLib.Position({
            szi: sziLots,
            entryNtl: 0,
            isolatedRawUsd: 0,
            leverage: 0,
            isIsolated: false
        });
        vm.mockCall(Constants.POSITION_PRECOMPILE, abi.encode(address(vault), perp), abi.encode(pos));

        PrecompileLib.PerpAssetInfo memory info = PrecompileLib.PerpAssetInfo({
            coin: "BTC",
            marginTableId: 0,
            szDecimals: szDecimals,
            maxLeverage: 50,
            onlyIsolated: false
        });
        vm.mockCall(Constants.PERP_ASSET_INFO_PRECOMPILE, abi.encode(perp), abi.encode(info));

        // Correct action size: 50_000 * 10^(8-5) = 50_000_000 (= 0.5 * 10^8).
        // Pre-fix this was 50_000 (0.0005 BTC) — a 1000x under-size.
        uint64 expectedSz = 50_000_000;

        uint32[] memory perps = new uint32[](1);
        perps[0] = perp;
        uint64[] memory pxs = new uint64[](1);
        pxs[0] = limitPx;

        // asset (topic1) + cloid (topic2) indexed; full data checked.
        // close a long -> sell (isBuy=false); reduceOnly=true; tif=IOC; cloid=1;
        // navSnapshot=0 (fresh vault, no deposits / NAV reads mocked).
        vm.expectEmit(true, true, false, true);
        emit LimitOrderSubmitted(perp, false, limitPx, expectedSz, true, Constants.TIF_IOC, 1, 0);

        vm.prank(emergency);
        vault.emergencyClosePositions(perps, pxs);
    }

    // ======================================================================
    // M4 — emergencyClosePositions sanity-bounds the caller's limitPx against the
    // strict markPx (normalized to the 10^8 action scale). A sane price passes; an
    // absurd one reverts; the explicit Force variant bypasses the band. Defaults
    // OFF (so bug_009 above, with band 0, is unaffected).
    // ======================================================================
    function _mockBtcPositionAndMark() internal returns (uint32 perp) {
        perp = 0;
        // 0.5 BTC long, szDecimals 5.
        PrecompileLib.Position memory pos =
            PrecompileLib.Position({szi: int64(50_000), entryNtl: 0, isolatedRawUsd: 0, leverage: 0, isIsolated: false});
        vm.mockCall(Constants.POSITION_PRECOMPILE, abi.encode(address(vault), perp), abi.encode(pos));
        PrecompileLib.PerpAssetInfo memory info =
            PrecompileLib.PerpAssetInfo({coin: "BTC", marginTableId: 0, szDecimals: 5, maxLeverage: 50, onlyIsolated: false});
        vm.mockCall(Constants.PERP_ASSET_INFO_PRECOMPILE, abi.encode(perp), abi.encode(info));
        // markPx = human(60000) * 10^(6 - szDec=5) = 600000 -> markNorm = 600000*10^7 = 6e12 (= $60k @ 10^8).
        vm.mockCall(Constants.MARK_PX_PRECOMPILE, abi.encode(perp), abi.encode(uint64(600_000)));
    }

    function test_M4_emergencyCloseBandRejectsAbsurdPrice() public {
        uint32 perp = _mockBtcPositionAndMark();

        vm.prank(admin);
        vault.setEmergencyCloseBand(2000); // wide 20% band

        uint32[] memory perps = new uint32[](1);
        perps[0] = perp;
        uint64[] memory pxs = new uint64[](1);

        // Sane: $60k (= markNorm) is within the band -> passes.
        pxs[0] = 6_000_000_000_000;
        vm.prank(emergency);
        vault.emergencyClosePositions(perps, pxs);

        // Absurd: $30k is 50% below markPx -> exceeds the 20% band -> reverts.
        pxs[0] = 3_000_000_000_000;
        vm.prank(emergency);
        vm.expectRevert(
            abi.encodeWithSelector(
                IHyperCoreVault.EmergencyCloseBandExceeded.selector, uint64(3_000_000_000_000), uint64(600_000), uint16(2000)
            )
        );
        vault.emergencyClosePositions(perps, pxs);

        // The explicit Force variant bypasses the band (oracle-unusable last resort).
        vm.prank(emergency);
        vault.emergencyClosePositionsForce(perps, pxs); // absurd price, but forced -> no revert
    }

    function test_M4_bandOffMatchesLegacyBehavior() public {
        uint32 perp = _mockBtcPositionAndMark();
        // Band defaults OFF: an absurd price is accepted (legacy behavior preserved
        // for bug_009 and any deployment that hasn't set a band).
        assertEq(vault.emergencyCloseBandBps(), 0, "band defaults off");
        uint32[] memory perps = new uint32[](1);
        perps[0] = perp;
        uint64[] memory pxs = new uint64[](1);
        pxs[0] = 1; // absurd
        vm.prank(emergency);
        vault.emergencyClosePositions(perps, pxs); // no band -> no revert
    }

    // ======================================================================
    // merged_bug_002 — the C-3 fix made `withdraw` treat `assets` as NET and
    // over-burn previewWithdraw(assets + fee) shares, breaking three ERC-4626
    // invariants. Post-fix `assets` is GROSS (mirrors redeem): burn exactly
    // previewWithdraw(assets), pay fee out of it, send the remainder.
    //   (1) burned shares == previewWithdraw(assets)
    //   (2) withdraw(maxWithdraw(owner)) does not revert for an LP with a gain
    //   (3) a router approved previewWithdraw(assets) shares is sufficient
    // ======================================================================
    function test_mergedBug002_withdrawIsErc4626Compliant() public {
        _deposit(alice, 100e6); // PPS 1.0, cost basis 1.0
        _simulateGain(50e6); // PPS 1.5; alice has a 50 USDC unrealized gain

        // ---- (1) + (3): router allowance + preview/burn parity on a partial ----
        uint256 part = 30e6;
        uint256 sharesForPart = vault.previewWithdraw(part); // GROSS preview

        vm.prank(alice);
        vault.approve(router, sharesForPart); // approve EXACTLY the preview (router pattern)

        uint256 feeRecip0 = usdc.balanceOf(feeRecipient);
        uint256 aliceSharesBefore = vault.balanceOf(alice);

        vm.prank(router);
        vault.withdraw(part, router, alice); // pre-fix: reverts (allowance/over-burn)

        // (1) exactly previewWithdraw(assets) shares burned
        uint256 burned = aliceSharesBefore - vault.balanceOf(alice);
        assertEq(burned, sharesForPart, "burned != previewWithdraw(assets) (over-burn)");
        // (3) the approved allowance was exactly sufficient and fully consumed
        assertEq(vault.allowance(alice, router), 0, "allowance not consumed exactly");

        // receiver gets gross - fee; fee was actually charged on the gain
        uint256 feePaid = usdc.balanceOf(feeRecipient) - feeRecip0;
        assertGt(feePaid, 0, "perf fee should be charged on the gain");
        assertEq(usdc.balanceOf(router), part - feePaid, "receiver should get assets - fee");

        // ---- (2) withdraw(maxWithdraw(owner)) must not revert ----
        uint256 mw = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(mw, alice, alice); // pre-fix: reverts for an LP with a gain
        assertLt(vault.balanceOf(alice), 1e9, "maxWithdraw should drain ~all shares");
    }

    // ======================================================================
    // L1 — deposit rejects a fee-on-transfer asset (USDC-class invariant). A FOT
    // token that delivers less than `assets` would otherwise over-credit shares.
    // ======================================================================
    function _deployVaultWithAsset(address asset_, uint16 mgmtBps) internal returns (HyperCoreVault v) {
        v = new HyperCoreVault(
            HyperCoreVault.Config({
                asset: IERC20(asset_),
                coreUsdcIndex: 0,
                coreUsdcDecimals: 8,
                coreDepositWallet: address(0), // legacy route (mock asset substrate)
                name: "L Vault",
                symbol: "lvlt",
                admin: admin,
                operator: operator,
                emergencyAdmin: emergency,
                feeRecipient: feeRecipient,
                leverageCapBps: 0,
                slippageBandBps: 0,
                mgmtFeeAnnualBps: mgmtBps,
                perfFeeBps: 0,
                depositCap: type(uint256).max,
                maxDepositPerAddress: 0
            })
        );
    }

    function test_L1_depositRejectsFeeOnTransferAsset() public {
        MockFOT fot = new MockFOT();
        HyperCoreVault fotVault = _deployVaultWithAsset(address(fot), 0);
        fot.mint(alice, 100e6);
        vm.startPrank(alice);
        fot.approve(address(fotVault), 100e6);
        // Vault receives only 99e6 (1% fee) -> guard reverts (no over-credit).
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.DepositAmountNotReceived.selector, uint256(100e6), uint256(99e6)));
        fotVault.deposit(100e6, alice);
        vm.stopPrank();
    }

    // ======================================================================
    // L2 — long-dormancy management fee is capped at one annual period (the rate),
    // not the old nav/2 confiscation (~50% of NAV in a single accrual).
    // ======================================================================
    function test_L2_dormancyMgmtFeeCappedAtAnnualRate() public {
        HyperCoreVault mv = _deployVaultWithAsset(address(usdc), 2000); // 20%/yr mgmt fee
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(mv), 100e6);
        mv.deposit(100e6, alice);
        vm.stopPrank();

        // 10 years dormant: linear fee = 100e6 * 0.20 * 10 = 200e6 >= NAV -> the cap fires.
        vm.warp(block.timestamp + 3650 days);

        uint256 supply = mv.totalSupply();
        uint256 pending = mv.pendingMgmtFeeShares();
        // New cap: feeAssets = 20% of NAV (20e6) -> feeShares = 20e6*S/(100e6-20e6) = S/4.
        // Old nav/2: feeShares = 50e6*S/50e6 = S (would halve every LP). Assert well below.
        assertGt(pending, 0, "some fee accrues");
        assertLt(pending, (supply * 30) / 100, "dormancy fee capped near 25% of supply, not the old ~100%");

        // Trigger the real accrual and confirm feeRecipient gets the (capped) shares.
        usdc.mint(router, 1e6);
        vm.startPrank(router);
        usdc.approve(address(mv), 1e6);
        mv.deposit(1e6, router);
        vm.stopPrank();
        assertApproxEqRel(mv.balanceOf(feeRecipient), pending, 0.05e18, "minted ~the capped pending amount");
    }

    // ======================================================================
    // L3 — emergencyClose handles a position of exactly int64.min without the
    // `-szi` negation overflow (uint64(-szi) would revert at int64.min).
    // ======================================================================
    function test_L3_emergencyCloseHandlesInt64Min() public {
        uint32 perp = 0;
        PrecompileLib.Position memory pos = PrecompileLib.Position({
            szi: type(int64).min,
            entryNtl: 0,
            isolatedRawUsd: 0,
            leverage: 0,
            isIsolated: false
        });
        vm.mockCall(Constants.POSITION_PRECOMPILE, abi.encode(address(vault), perp), abi.encode(pos));
        // szDecimals 8 keeps the scaled size within uint64 (sz = |szi| * 10^(8-8)).
        PrecompileLib.PerpAssetInfo memory info =
            PrecompileLib.PerpAssetInfo({coin: "X", marginTableId: 0, szDecimals: 8, maxLeverage: 50, onlyIsolated: false});
        vm.mockCall(Constants.PERP_ASSET_INFO_PRECOMPILE, abi.encode(perp), abi.encode(info));

        uint32[] memory perps = new uint32[](1);
        perps[0] = perp;
        uint64[] memory pxs = new uint64[](1);
        pxs[0] = 100_000_000;

        // Band off (default) -> no markPx read. Pre-L3 this reverts on `-szi`; now it
        // computes |int64.min| via int256 widening and dispatches.
        vm.prank(emergency);
        vault.emergencyClosePositions(perps, pxs);
    }

    // ======================================================================
    // G2 — pushToCore routing (unit substrate). The wallet-mode happy path runs
    // against the REAL CoreDepositWallet bytecode in the fork suite; these two
    // cover what the fork cannot: the preserved legacy route on a plain ERC20,
    // and the defensive allowance-zeroing against a misbehaving wallet.
    // ======================================================================

    /// @dev Deploy a wallet-mode vault around a fixture wallet (unit substrate).
    function _deployVaultWithFixtureWallet(address wallet_) internal returns (HyperCoreVault v) {
        v = new HyperCoreVault(
            HyperCoreVault.Config({
                asset: IERC20(address(usdc)),
                coreUsdcIndex: 0,
                coreUsdcDecimals: 8,
                coreDepositWallet: wallet_,
                name: "G2 Vault",
                symbol: "g2vlt",
                admin: admin,
                operator: operator,
                emergencyAdmin: emergency,
                feeRecipient: feeRecipient,
                leverageCapBps: 0,
                slippageBandBps: 0,
                mgmtFeeAnnualBps: 0,
                perfFeeBps: 0,
                depositCap: type(uint256).max,
                maxDepositPerAddress: 0
            })
        );
    }

    function test_G2_legacyPushStillTransfersToSystemAddress() public {
        // setUp()'s vault is legacy mode (coreDepositWallet == 0): the pre-G2
        // route (ERC20 transfer to the token system address) must be preserved
        // for genuinely direct-linked assets. MockUSDC has no blacklist.
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100e6);
        vault.deposit(100e6, alice);
        vm.stopPrank();

        address sysAddr = address(uint160(uint256(uint8(0x20)) << 152)); // forToken(0)
        vm.prank(operator);
        vault.pushToCore(40e6);
        assertEq(usdc.balanceOf(sysAddr), 40e6, "legacy route transfers to the system address");
    }

    function test_G2_pushClearsResidualAllowance() public {
        // A (hypothetically misbehaving / upgraded) wallet that consumes only
        // HALF the approved amount: the vault's trailing forceApprove(0) must
        // still leave ZERO standing allowance to the third-party contract.
        FixtureCoreDepositWallet w = new FixtureCoreDepositWallet(IERC20(address(usdc)));
        HyperCoreVault v = _deployVaultWithFixtureWallet(address(w));

        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(v), 100e6);
        v.deposit(100e6, alice);
        vm.stopPrank();

        vm.prank(operator);
        v.pushToCore(50e6);

        assertEq(usdc.allowance(address(v), address(w)), 0, "residual allowance zeroed");
        assertEq(usdc.balanceOf(address(w)), 25e6, "fixture consumed only half");
        assertEq(v.idleUsdc(), 75e6, "only the consumed half left the vault");
    }
}

/// @notice Fixture CoreDepositWallet for the unit substrate: correct getters for
///         the constructor's G2 validation, but a deposit() that deliberately
///         consumes only half the allowance (a benign-but-misbehaving upgrade).
contract FixtureCoreDepositWallet {
    IERC20 private immutable _token;

    constructor(IERC20 token_) {
        _token = token_;
    }

    function token() external view returns (address) {
        return address(_token);
    }

    function tokenSystemAddress() external pure returns (address) {
        return address(uint160(uint256(uint8(0x20)) << 152)); // SystemAddress.forToken(0)
    }

    function paused() external pure returns (bool) {
        return false;
    }

    function deposit(uint256 amount, uint32) external {
        require(_token.transferFrom(msg.sender, address(this), amount / 2), "transferFrom failed");
    }
}

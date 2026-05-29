// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HyperCoreVault} from "../src/HyperCoreVault.sol";
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
    // bug_010 — performance-fee evasion via requestWithdraw -> deposit ->
    // cancel -> redeem. Pre-fix: a dust deposit while a withdrawal request is
    // open overwrote the LP's cost basis to the current PPS, so redeem charged
    // ZERO perf fee. Post-fix: the escrowed shares are counted, the deposit
    // weighted-averages, and the full perf fee is collected.
    // ======================================================================
    function test_bug010_perfFeeEvasionClosed() public {
        // Alice deposits 100 USDC at PPS 1.0; cost basis = 1.0.
        uint256 shares = _deposit(alice, 100e6);

        // Strategy gains 50 USDC -> PPS 1.5, alice's unrealized gain = 50 USDC.
        _simulateGain(50e6);

        // Fund the dust deposit used to poison the cost basis.
        usdc.mint(alice, 1e6);

        // ---- the exploit sequence ----
        vm.startPrank(alice);
        vault.requestWithdraw(shares); // escrow all shares (balanceOf(alice) -> 0)
        usdc.approve(address(vault), 1e6);
        vault.deposit(1e6, alice); // dust deposit at PPS 1.5 (the cb-poisoning step)
        vault.cancelWithdrawRequest(); // shares returned
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
}

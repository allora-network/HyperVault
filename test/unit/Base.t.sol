// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HyperCoreVault} from "../../src/HyperCoreVault.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockCoreWriter} from "../mocks/MockCoreWriter.sol";
import {MockPrecompiles} from "../mocks/MockPrecompiles.sol";

/// @notice Shared fixture for vault unit tests.
abstract contract VaultBaseTest is Test {
    MockUSDC internal usdc;
    HyperCoreVault internal vault;

    address internal admin     = makeAddr("admin");
    address internal operator  = makeAddr("operator");
    address internal emergency = makeAddr("emergency");
    address internal feeWallet = makeAddr("feeRecipient");
    address internal alice     = makeAddr("alice");
    address internal bob       = makeAddr("bob");

    uint16 internal constant LEV_CAP_BPS  = 30_000;  // 3x
    uint16 internal constant SLIP_BAND    = 100;     // 1%
    uint16 internal constant MGMT_FEE     = 200;     // 2%/yr
    uint16 internal constant PERF_FEE     = 1500;    // 15%

    function setUp() public virtual {
        usdc = new MockUSDC();

        // Etch MockCoreWriter at the canonical CoreWriter address.
        MockCoreWriter mock = new MockCoreWriter();
        vm.etch(Constants.CORE_WRITER, address(mock).code);

        HyperCoreVault.Config memory cfg = HyperCoreVault.Config({
            asset: IERC20(address(usdc)),
            name: "Test Strategy",
            symbol: "tSTR",
            admin: admin,
            operator: operator,
            emergencyAdmin: emergency,
            feeRecipient: feeWallet,
            leverageCapBps: LEV_CAP_BPS,
            slippageBandBps: SLIP_BAND,
            mgmtFeeAnnualBps: MGMT_FEE,
            perfFeeBps: PERF_FEE,
            depositCap: 1_000_000_000_000, // 1M USDC
            maxDepositPerAddress: 100_000_000_000 // 100k USDC
        });
        vault = new HyperCoreVault(cfg);

        // Fund test users
        usdc.mint(alice, 100_000 * 1e6);
        usdc.mint(bob, 100_000 * 1e6);

        // Default precompile responses: all zeros (account has no Core history)
        MockPrecompiles.setSpotBalance(vm, address(vault), Constants.USDC_CORE_INDEX, 0, 0);
        MockPrecompiles.setWithdrawable(vm, address(vault), 0);

        // Admin grants nothing extra here; tests can prank as admin to setup whitelist.
    }

    function _depositAs(address who, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _whitelistPerp(uint32 asset) internal {
        vm.prank(admin);
        vault.setWhitelistPerp(asset, true);
    }

    function _coreWriter() internal pure returns (MockCoreWriter) {
        return MockCoreWriter(Constants.CORE_WRITER);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HyperCoreVault} from "../../src/HyperCoreVault.sol";
import {HyperCoreVaultFactory} from "../../src/HyperCoreVaultFactory.sol";
import {HyperCoreVaultRegistry} from "../../src/HyperCoreVaultRegistry.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockCoreWriter} from "../mocks/MockCoreWriter.sol";
import {MockPrecompiles} from "../mocks/MockPrecompiles.sol";
import {Constants} from "../../src/libraries/Constants.sol";

contract FactoryTest is Test {
    MockUSDC internal usdc;
    HyperCoreVaultRegistry internal registry;
    HyperCoreVaultFactory internal factory;

    address internal deployer  = makeAddr("deployer");
    address internal operator  = makeAddr("operator");
    address internal emergency = makeAddr("emergency");
    address internal feeWallet = makeAddr("feeWallet");

    function setUp() public {
        usdc = new MockUSDC();
        MockCoreWriter mock = new MockCoreWriter();
        vm.etch(Constants.CORE_WRITER, address(mock).code);

        vm.prank(deployer);
        registry = new HyperCoreVaultRegistry(deployer);
        vm.prank(deployer);
        factory = new HyperCoreVaultFactory(registry, deployer, false /* strict off for test */);
        vm.prank(deployer);
        registry.setFactory(address(factory));
    }

    function _cfg() internal view returns (HyperCoreVault.Config memory) {
        return HyperCoreVault.Config({
            asset: IERC20(address(usdc)),
            name: "Test Strat A",
            symbol: "tsA",
            admin: address(0), // factory sets to timelock
            operator: operator,
            emergencyAdmin: emergency,
            feeRecipient: feeWallet,
            leverageCapBps: 30000,
            slippageBandBps: 100,
            mgmtFeeAnnualBps: 200,
            perfFeeBps: 1500,
            depositCap: 1_000_000_000_000,
            maxDepositPerAddress: 100_000_000_000
        });
    }

    function test_deployVault_registeredAndCallable() public {
        // Predict address relies on knowing the timelock-to-be (CREATE-derived
        // from factory nonce). We assert the easier invariant: deployed vault
        // is registered and addressable.
        HyperCoreVault.Config memory cfg = _cfg();
        vm.prank(deployer);
        (address vault,) = factory.deployVault(cfg, 0);
        assertTrue(registry.isRegistered(vault));
        assertEq(HyperCoreVault(vault).name(), cfg.name);
    }

    function test_deployVault_registerEntryCorrect() public {
        HyperCoreVault.Config memory cfg = _cfg();
        vm.prank(deployer);
        (address vault, address timelock) = factory.deployVault(cfg, 0);

        HyperCoreVaultRegistry.VaultMetadata memory m = registry.getVault(0);
        assertEq(m.vault, vault);
        assertEq(m.asset, address(usdc));
        assertEq(m.operator, operator);
        assertEq(m.timelock, timelock);
        assertEq(m.name, "Test Strat A");
    }

    function test_strictValidation_revertsOnMismatch() public {
        vm.prank(deployer);
        factory.setStrictAssetValidation(true);

        // Mock the precompile to return a different address as USDC
        MockPrecompiles.setTokenInfoUsdc(vm, makeAddr("realUsdc"));

        vm.prank(deployer);
        vm.expectRevert();
        factory.deployVault(_cfg(), 0);
    }
}

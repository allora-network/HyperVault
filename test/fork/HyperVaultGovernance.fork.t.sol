// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {HyperVaultBaseForkTest} from "./HyperVaultBase.fork.t.sol";
import {HyperCoreVault} from "../../src/HyperCoreVault.sol";
import {HyperCoreVaultFactory} from "../../src/HyperCoreVaultFactory.sol";
import {HyperCoreVaultRegistry} from "../../src/HyperCoreVaultRegistry.sol";

/// @title  Governance / deploy-config finding proofs (C, I)
/// @notice Ties the findings to the ACTUAL shipped artifact: each test reads
///         deployments/configs/mainnet-tier1.json and then reproduces the real deploy
///         topology on the fork to demonstrate the consequence on real bytecode.
contract HyperVaultGovernanceForkTest is HyperVaultBaseForkTest {
    string constant TIER1 = "deployments/configs/mainnet-tier1.json";

    /// @dev Deploy a vault with explicit admin + a single shared role key, mirroring a
    ///      tier config (operator == emergencyAdmin == feeRecipient).
    function _deployWithSharedKey(address admin_, address single) internal returns (HyperCoreVault v) {
        HyperCoreVault.Config memory cfg = HyperCoreVault.Config({
            asset: IERC20(USDC),
            coreUsdcIndex: 0,
            coreUsdcDecimals: 8,
            name: "Gov Proof Vault",
            symbol: "gpv",
            admin: admin_,
            operator: single,
            emergencyAdmin: single,
            feeRecipient: single,
            leverageCapBps: 30000,
            slippageBandBps: 200,
            mgmtFeeAnnualBps: 200,
            perfFeeBps: 1500,
            depositCap: 100e6,
            maxDepositPerAddress: 100e6
        });
        v = new HyperCoreVault(cfg);
    }

    // ───────────────────────────────────────────────────────────────────────
    // Finding C remediation (H3) — the shipped config no longer collapses roles or
    //   ships a 0-delay timelock, and the deploy surfaces (factory + Deploy.s.sol)
    //   refuse to mint that footgun. Three proofs: (1) the fixed tier1 artifact,
    //   (2) the factory floor + distinct-role guards revert on real bytecode,
    //   (3) a real 24h TimelockController gates an admin change (blocks then allows).
    // ───────────────────────────────────────────────────────────────────────

    function _factory() internal returns (HyperCoreVaultFactory f) {
        HyperCoreVaultRegistry reg = new HyperCoreVaultRegistry(address(this));
        f = new HyperCoreVaultFactory(reg, address(this), false);
        reg.setFactory(address(f));
    }

    function _facCfg(address op, address em, address fee) internal view returns (HyperCoreVault.Config memory cfg) {
        cfg = HyperCoreVault.Config({
            asset: IERC20(USDC),
            coreUsdcIndex: 0,
            coreUsdcDecimals: 8,
            name: "Factory Vault",
            symbol: "facv",
            admin: address(0), // factory overwrites with the per-vault timelock
            operator: op,
            emergencyAdmin: em,
            feeRecipient: fee,
            leverageCapBps: 0,
            slippageBandBps: 0,
            mgmtFeeAnnualBps: 0,
            perfFeeBps: 0,
            depositCap: type(uint256).max,
            maxDepositPerAddress: 0
        });
    }

    function test_C_shippedConfigNowDistinctWithRealDelay() public {
        _skipIfNoFork();
        string memory json = vm.readFile(TIER1);
        address op = vm.parseJsonAddress(json, ".operator");
        address em = vm.parseJsonAddress(json, ".emergencyAdmin");
        address fee = vm.parseJsonAddress(json, ".feeRecipient");
        uint256 delay = vm.parseJsonUint(json, ".timelockMinDelaySec");
        assertTrue(op != em && op != fee && em != fee, "tier1: roles now distinct (H3)");
        assertGe(delay, 24 hours, "tier1: timelock delay now >= 24h (H3)");
        console2.log("C PASS - shipped tier1 config: distinct roles + >=24h timelock (H3)");
    }

    function test_C_factoryEnforcesTimelockFloor() public {
        _skipIfNoFork();
        HyperCoreVaultFactory f = _factory();
        HyperCoreVault.Config memory cfg = _facCfg(operator, emergency, feeRecipient); // distinct roles

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreVaultFactory.TimelockDelayBelowFloor.selector, uint256(0), uint256(24 hours))
        );
        f.deployVault(cfg, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreVaultFactory.TimelockDelayBelowFloor.selector, uint256(23 hours), uint256(24 hours)
            )
        );
        f.deployVault(cfg, 23 hours);

        console2.log("C PASS - factory rejects sub-24h timelock delay (H3)");
    }

    function test_C_factoryRejectsSharedRoles() public {
        _skipIfNoFork();
        HyperCoreVaultFactory f = _factory();
        address single = makeAddr("single");

        vm.expectRevert(HyperCoreVaultFactory.RolesNotDistinct.selector);
        f.deployVault(_facCfg(single, single, single), 24 hours);

        // partial overlap also rejected (operator == feeRecipient)
        vm.expectRevert(HyperCoreVaultFactory.RolesNotDistinct.selector);
        f.deployVault(_facCfg(single, makeAddr("em"), single), 24 hours);

        console2.log("C PASS - factory rejects shared operator/emergency/feeRecipient keys (H3)");
    }

    function test_C_factoryAcceptsCompliantConfig() public {
        _skipIfNoFork();
        HyperCoreVaultFactory f = _factory();
        (address vaultAddr, address timelock) =
            f.deployVault(_facCfg(operator, emergency, feeRecipient), 24 hours);
        assertTrue(vaultAddr != address(0) && timelock != address(0), "compliant config deploys");
        assertEq(HyperCoreVault(vaultAddr).feeRecipient(), feeRecipient, "feeRecipient wired");
        console2.log("C PASS - factory deploys a compliant (distinct roles + 24h) config (H3)");
    }

    function test_C_timelock24hGateBlocksThenAllows() public {
        _skipIfNoFork();
        uint256 delay = 24 hours;
        address[] memory self = new address[](1);
        self[0] = address(this);
        TimelockController tl = new TimelockController(delay, self, self, address(this));
        // Role separation is tested above; here we isolate the TIMELOCK gate, so a
        // single operating key under a real 24h timelock is fine for the proof.
        HyperCoreVault v = _deployWithSharedKey(address(tl), makeAddr("single"));

        bytes memory data = abi.encodeCall(HyperCoreVault.setLeverageCap, (uint16(123)));
        bytes32 salt = bytes32(uint256(1));
        tl.schedule(address(v), 0, data, bytes32(0), salt, delay);

        // Before the delay elapses, execution reverts (operation not ready).
        vm.expectRevert();
        tl.execute(address(v), 0, data, bytes32(0), salt);

        // After 24h, the same execution succeeds.
        vm.warp(block.timestamp + delay + 1);
        tl.execute(address(v), 0, data, bytes32(0), salt);
        assertEq(v.leverageCapBps(), 123, "admin change executed only after the 24h timelock");

        console2.log("C PASS - real 24h TimelockController blocks before delay, allows after (H3)");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Finding I — Deposit caps are test values ($100), enforced on real bytecode.
    //   Source:  deployments/configs/mainnet-tier1.json (depositCap == maxDepositPerAddress == 100e6).
    //   Fork-provable: FULL.
    // ───────────────────────────────────────────────────────────────────────
    function test_I_capsAreHundredDollarTestValues() public {
        _skipIfNoFork();

        string memory json = vm.readFile(TIER1);
        uint256 cap = vm.parseJsonUint(json, ".depositCap");
        uint256 perAddr = vm.parseJsonUint(json, ".maxDepositPerAddress");
        assertEq(cap, 100e6, "shipped config: depositCap == $100 (6dp)");
        assertEq(perAddr, 100e6, "shipped config: maxDepositPerAddress == $100 (6dp)");

        // Reproduce and enforce on real bytecode.
        HyperCoreVault v = _deployWithSharedKey(address(this), makeAddr("single"));
        assertEq(v.maxDeposit(alice), 100e6, "fresh: maxDeposit clamped to the $100 cap");

        deal(USDC, alice, 200e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(v), 200e6);
        v.deposit(100e6, alice); // exactly at the cap
        assertEq(v.maxDeposit(alice), 0, "per-address cap reached after a $100 deposit");
        vm.expectRevert(); // ERC4626 ExceededMaxDeposit
        v.deposit(1, alice);
        vm.stopPrank();

        console2.log("I PASS - $100 caps are real and enforced; production must raise them");
    }
}

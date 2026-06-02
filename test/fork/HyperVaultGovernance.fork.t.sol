// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {HyperVaultBaseForkTest} from "./HyperVaultBase.fork.t.sol";
import {HyperCoreVault} from "../../src/HyperCoreVault.sol";

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
    // Finding C — Shipped config collapses operator/emergency/feeRecipient into one key,
    //             and the 0-delay timelock offers no protection (instant execution).
    //   Source:  deployments/configs/mainnet-tier1.json (operator==emergencyAdmin==
    //            feeRecipient; timelockMinDelaySec == 0).
    //   Fork-provable: FULL (real OZ TimelockController + vault bytecode).
    // ───────────────────────────────────────────────────────────────────────
    function test_C_shippedConfigCollapsesRolesAndTimelock() public {
        _skipIfNoFork();

        // (1) Prove the collapse is in the SHIPPED artifact, not invented here.
        string memory json = vm.readFile(TIER1);
        address cfgOperator = vm.parseJsonAddress(json, ".operator");
        address cfgEmergency = vm.parseJsonAddress(json, ".emergencyAdmin");
        address cfgFeeRecipient = vm.parseJsonAddress(json, ".feeRecipient");
        uint256 cfgDelay = vm.parseJsonUint(json, ".timelockMinDelaySec");
        assertEq(cfgOperator, cfgEmergency, "shipped config: operator == emergencyAdmin");
        assertEq(cfgOperator, cfgFeeRecipient, "shipped config: operator == feeRecipient");
        assertEq(cfgDelay, 0, "shipped config: timelockMinDelaySec == 0");
        console2.log("C: shipped tier1 single key =", cfgOperator);

        // (2) Reproduce the real topology on the fork: a 0-delay timelock as admin, with the
        //     same address holding OPERATOR + EMERGENCY + feeRecipient.
        address[] memory selfArr = new address[](1);
        selfArr[0] = address(this); // the "deployer" (proposer + executor), as in Deploy.s.sol
        TimelockController tl = new TimelockController(cfgDelay, selfArr, selfArr, address(this));
        HyperCoreVault v = _deployWithSharedKey(address(tl), cfgOperator);

        // Role collapse: one key can trade, trigger emergency, AND receive fees.
        assertTrue(v.hasRole(v.OPERATOR_ROLE(), cfgOperator), "single key holds OPERATOR_ROLE");
        assertTrue(v.hasRole(v.EMERGENCY_ROLE(), cfgOperator), "single key holds EMERGENCY_ROLE");
        assertEq(v.feeRecipient(), cfgOperator, "single key is the feeRecipient");

        // 0-delay timelock = no protection: schedule + execute a guardrail change in ONE block.
        bytes memory data = abi.encodeCall(HyperCoreVault.setLeverageCap, (uint16(123)));
        tl.schedule(address(v), 0, data, bytes32(0), bytes32(0), 0);
        tl.execute(address(v), 0, data, bytes32(0), bytes32(0));
        assertEq(v.leverageCapBps(), 123, "0-delay timelock executed an admin change with zero notice");

        console2.log("C PASS - role collapse + 0-delay timelock execute instantly (no protection window)");
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

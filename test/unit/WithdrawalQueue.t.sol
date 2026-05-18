// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {VaultBaseTest} from "./Base.t.sol";
import {IHyperCoreVault} from "../../src/interfaces/IHyperCoreVault.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {MockPrecompiles} from "../mocks/MockPrecompiles.sol";

contract WithdrawalQueueTest is VaultBaseTest {
    function test_request_escrowsShares() public {
        _depositAs(alice, 1_000 * 1e6);
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.requestWithdraw(shares);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(vault)), shares);
        assertEq(vault.pendingWithdrawalShares(alice), shares);
    }

    function test_cancel_returnsShares() public {
        _depositAs(alice, 1_000 * 1e6);
        uint256 shares = vault.balanceOf(alice);

        vm.startPrank(alice);
        vault.requestWithdraw(shares);
        vault.cancelWithdrawRequest();
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.pendingWithdrawalShares(alice), 0);
    }

    function test_fulfill_payoutWhenIdleSufficient() public {
        _depositAs(alice, 1_000 * 1e6);
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.requestWithdraw(shares);

        // Anyone can fulfill
        vm.prank(bob);
        vault.fulfillWithdraw(alice);

        // Alice received ~1000 USDC; pending cleared
        assertApproxEqRel(usdc.balanceOf(alice) - 99_000 * 1e6, 1_000 * 1e6, 0.001e18);
        assertEq(vault.pendingWithdrawalShares(alice), 0);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_fulfill_partialWhenIdleLow() public {
        _depositAs(alice, 1_000 * 1e6);
        uint256 shares = vault.balanceOf(alice);

        // Move 800 USDC out of vault (simulating push to Core).
        // ALSO mock the Core spot balance so NAV stays at ~1000 USDC; otherwise
        // NAV would drop to 200 (idle alone) and Alice could fully redeem at
        // the depreciated pps.
        vm.prank(address(vault));
        usdc.transfer(makeAddr("bridge"), 800 * 1e6);
        // Core USDC weiDecimals = 8, so 800 USDC = 800 * 1e8 Core wei
        bytes32 mockSpotKey = keccak256(abi.encode(address(vault), Constants.USDC_CORE_INDEX));
        mockSpotKey; // silence unused
        // Use library helper for clarity:
        // (vm.mockCall is global, no need to track key)
        MockPrecompiles_setSpot(address(vault), 800 * 1e8);

        vm.prank(alice);
        vault.requestWithdraw(shares);

        vm.prank(bob);
        vault.fulfillWithdraw(alice);

        // Alice received ~200 USDC; pending still has remainder (~800 USDC worth)
        uint256 received = usdc.balanceOf(alice) - 99_000 * 1e6;
        assertApproxEqRel(received, 200 * 1e6, 0.01e18);
        assertGt(vault.pendingWithdrawalShares(alice), 0);
    }

    function MockPrecompiles_setSpot(address user, uint64 total) internal {
        MockPrecompiles.setSpotBalance(vm, user, Constants.USDC_CORE_INDEX, total, 0);
    }

    function test_request_revertsOnDoubleRequest() public {
        _depositAs(alice, 1_000 * 1e6);
        uint256 shares = vault.balanceOf(alice);

        vm.startPrank(alice);
        vault.requestWithdraw(shares / 2);
        vm.expectRevert();
        vault.requestWithdraw(shares / 2);
        vm.stopPrank();
    }
}

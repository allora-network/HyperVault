// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {AssetId} from "../../src/libraries/AssetId.sol";
import {Constants} from "../../src/libraries/Constants.sol";

contract AssetIdTest is Test {
    function test_perpEncoding_passThrough() public pure {
        assertEq(AssetId.perp(0), 0);
        assertEq(AssetId.perp(1), 1);
        assertEq(AssetId.perp(9_999), 9_999);
    }

    function test_spotEncoding_offsets() public pure {
        assertEq(AssetId.spot(0), 10_000);
        assertEq(AssetId.spot(5), 10_005);
    }

    function test_isSpot() public pure {
        assertTrue(AssetId.isSpot(10_000));
        assertTrue(AssetId.isSpot(10_001));
        assertFalse(AssetId.isSpot(0));
        assertFalse(AssetId.isSpot(9_999));
    }

    function test_isPerp() public pure {
        assertTrue(AssetId.isPerp(0));
        assertTrue(AssetId.isPerp(9_999));
        assertFalse(AssetId.isPerp(10_000));
    }

    function test_indexOf() public pure {
        assertEq(AssetId.indexOf(5), 5);
        assertEq(AssetId.indexOf(10_005), 5);
    }

    function test_perp_revertsOnSpotRange() public {
        vm.expectRevert(abi.encodeWithSelector(AssetId.InvalidPerpIndex.selector, uint32(10_000)));
        this.callPerp(10_000);
    }

    /// @dev Helper to bubble the library revert through an external call so
    ///      `vm.expectRevert` can intercept it.
    function callPerp(uint32 x) external pure returns (uint32) {
        return AssetId.perp(x);
    }
}

contract SystemAddressTest is Test {
    function test_usdcBridgeAddress() public pure {
        // USDC = index 0 → address = 0x20 || 19 zero bytes
        address expected = 0x2000000000000000000000000000000000000000;
        address got = address(uint160(uint256(uint8(0x20)) << 152));
        assertEq(got, expected);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {CoreWriterLib} from "../../src/libraries/CoreWriterLib.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {MockCoreWriter} from "../mocks/MockCoreWriter.sol";

/// @notice Bit-exact encoding tests. If these break, the protocol changed an
///         action layout — re-check Hyperliquid CoreWriter docs.
contract CoreWriterLibTest is Test {
    function setUp() public {
        MockCoreWriter m = new MockCoreWriter();
        vm.etch(Constants.CORE_WRITER, address(m).code);
    }

    function _coreWriter() internal pure returns (MockCoreWriter) {
        return MockCoreWriter(Constants.CORE_WRITER);
    }

    function test_limitOrder_encoding() public {
        CoreWriterLib.placeLimitOrder(0, true, 50_000_00000000, 100, false, Constants.TIF_GTC, 42);
        bytes memory got = _coreWriter().lastAction();

        bytes memory expected = abi.encodePacked(
            uint8(1),            // version
            uint24(1),           // action id LIMIT_ORDER
            abi.encode(uint32(0), true, uint64(50_000_00000000), uint64(100), false, uint8(1), uint128(42))
        );
        assertEq(got, expected);
    }

    function test_spotSend_encoding() public {
        address dest = address(0x2000000000000000000000000000000000000000);
        CoreWriterLib.spotSend(dest, 0, 1_00000000);
        bytes memory got = _coreWriter().lastAction();

        bytes memory expected = abi.encodePacked(
            uint8(1),
            uint24(6),
            abi.encode(dest, uint64(0), uint64(1_00000000))
        );
        assertEq(got, expected);
    }

    function test_usdClassTransfer_encoding() public {
        CoreWriterLib.usdClassTransfer(100 * 1e6, true);
        bytes memory got = _coreWriter().lastAction();
        bytes memory expected = abi.encodePacked(
            uint8(1),
            uint24(7),
            abi.encode(uint64(100 * 1e6), true)
        );
        assertEq(got, expected);
    }

    function test_cancelByCloid_encoding() public {
        CoreWriterLib.cancelOrderByCloid(0, 12345);
        bytes memory got = _coreWriter().lastAction();
        bytes memory expected = abi.encodePacked(
            uint8(1),
            uint24(11),
            abi.encode(uint32(0), uint128(12345))
        );
        assertEq(got, expected);
    }

    function test_cancelByOid_encoding() public {
        CoreWriterLib.cancelOrderByOid(0, 12345);
        bytes memory got = _coreWriter().lastAction();
        bytes memory expected = abi.encodePacked(
            uint8(1),
            uint24(10),
            abi.encode(uint32(0), uint64(12345))
        );
        assertEq(got, expected);
    }
}

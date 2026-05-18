// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Vm} from "forge-std/Vm.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {PrecompileLib} from "../../src/libraries/PrecompileLib.sol";

/// @notice Helpers for `vm.mockCall`-ing the L1 read precompiles in unit tests.
///
///         Usage:
///             MockPrecompiles.setSpotBalance(vm, vault, USDC_IDX, total, hold);
///             MockPrecompiles.setWithdrawable(vm, vault, 5_000_000); // 5 USDC at 6dp
///             MockPrecompiles.setOraclePx(vm, perpIdx, 50_000_00000000); // 50000.0 at 8dp
library MockPrecompiles {
    function setSpotBalance(Vm vm, address user, uint64 tokenIdx, uint64 total, uint64 hold) internal {
        PrecompileLib.SpotBalance memory bal = PrecompileLib.SpotBalance({
            total: total,
            hold: hold,
            entryNtl: 0
        });
        vm.mockCall(
            Constants.SPOT_BALANCE_PRECOMPILE,
            abi.encode(user, tokenIdx),
            abi.encode(bal)
        );
    }

    function setWithdrawable(Vm vm, address user, uint64 amount6dp) internal {
        vm.mockCall(
            Constants.WITHDRAWABLE_PRECOMPILE,
            abi.encode(user),
            abi.encode(PrecompileLib.Withdrawable({withdrawable: amount6dp}))
        );
    }

    function setPosition(Vm vm, address user, uint32 perpIdx, int64 szi, uint64 entryNtl) internal {
        PrecompileLib.Position memory p = PrecompileLib.Position({
            szi: szi,
            entryNtl: entryNtl,
            isolatedRawUsd: 0,
            leverage: 10,
            isIsolated: false
        });
        vm.mockCall(
            Constants.POSITION_PRECOMPILE,
            abi.encode(user, perpIdx),
            abi.encode(p)
        );
    }

    function setOraclePx(Vm vm, uint32 perpIdx, uint64 px) internal {
        vm.mockCall(Constants.ORACLE_PX_PRECOMPILE, abi.encode(perpIdx), abi.encode(px));
    }

    function setMarkPx(Vm vm, uint32 perpIdx, uint64 px) internal {
        vm.mockCall(Constants.MARK_PX_PRECOMPILE, abi.encode(perpIdx), abi.encode(px));
    }

    function setTokenInfoUsdc(Vm vm, address evmContract) internal {
        PrecompileLib.TokenInfo memory info;
        info.evmContract = evmContract;
        info.weiDecimals = Constants.USDC_CORE_DECIMALS;
        info.szDecimals = 0;
        info.evmExtraWeiDecimals = int8(int16(int8(Constants.USDC_EVM_DECIMALS)) - int8(Constants.USDC_CORE_DECIMALS));
        vm.mockCall(
            Constants.TOKEN_INFO_PRECOMPILE,
            abi.encode(uint32(Constants.USDC_CORE_INDEX)),
            abi.encode(info)
        );
    }
}

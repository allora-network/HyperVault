// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ICoreWriter} from "../../src/interfaces/ICoreWriter.sol";

/// @notice Test double for the CoreWriter system contract. Captures every
///         `sendRawAction` payload for later inspection / assertion.
///
///         Install at the canonical CoreWriter address with `vm.etch`:
///             MockCoreWriter m = new MockCoreWriter();
///             vm.etch(Constants.CORE_WRITER, address(m).code);
///         After etch, storage at that address is empty — the contract uses
///         storage that is safe to initialise lazily (push to dynamic array).
contract MockCoreWriter is ICoreWriter {
    bytes[] private _actions;

    function sendRawAction(bytes calldata data) external override {
        _actions.push(data);
        emit RawAction(msg.sender, data);
    }

    function actionCount() external view returns (uint256) {
        return _actions.length;
    }

    function actions(uint256 i) external view returns (bytes memory) {
        return _actions[i];
    }

    function lastAction() external view returns (bytes memory) {
        return _actions[_actions.length - 1];
    }

    function clear() external {
        delete _actions;
    }
}

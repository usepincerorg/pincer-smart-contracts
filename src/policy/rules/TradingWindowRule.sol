// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PolicyRuleBase} from "./PolicyRuleBase.sol";
import {CheckCodes} from "../../common/CheckCodes.sol";

/// @title Calendar-based transfer restriction
/// @notice Transfers are blocked outside the time windows the company has configured.
/// @dev Configuration is `abi.encode(Window[] windows, bool allowDuringLiquidityWindows, address liquidityWindow)`.
///      When `allowDuringLiquidityWindows` is set, any transfer to or from the company's WindowMarket passes, because
///      that contract only moves tokens for windows the company opened, even when the movement (settlement, for
///      example) happens after the window has closed. Mints always pass.
contract TradingWindowRule is PolicyRuleBase {
    uint256 public constant MAX_WINDOWS = 64;

    struct Window {
        uint40 opensAt;
        uint40 closesAt;
    }

    Window[] private _windows;
    bool public allowDuringLiquidityWindows;
    address public liquidityWindow;

    function moduleId() external pure returns (bytes32) {
        return "TRANSFER_WINDOW";
    }

    function windows() external view returns (Window[] memory) {
        return _windows;
    }

    function isOpen() public view returns (bool) {
        for (uint256 i; i < _windows.length; ++i) {
            if (block.timestamp >= _windows[i].opensAt && block.timestamp < _windows[i].closesAt) return true;
        }
        return false;
    }

    function check(address from, address to, uint256) external view returns (bytes32) {
        if (from == address(0)) return CheckCodes.OK;
        if (allowDuringLiquidityWindows && (from == liquidityWindow || to == liquidityWindow)) return CheckCodes.OK;
        return isOpen() ? CheckCodes.OK : CheckCodes.WINDOW_CLOSED;
    }

    function _configure(bytes calldata config) internal override {
        (Window[] memory windows_, bool allow, address lw) = abi.decode(config, (Window[], bool, address));
        if (windows_.length > MAX_WINDOWS) revert InvalidConfig();
        delete _windows;
        for (uint256 i; i < windows_.length; ++i) {
            if (windows_[i].closesAt <= windows_[i].opensAt) revert InvalidConfig();
            _windows.push(windows_[i]);
        }
        allowDuringLiquidityWindows = allow;
        liquidityWindow = lw;
    }
}

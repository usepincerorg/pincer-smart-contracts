// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HolderBalanceRuleBase} from "./PolicyRuleBase.sol";
import {CheckCodes} from "../../common/CheckCodes.sol";

/// @title Maximum number of distinct holders
/// @notice Caps the number of different identities that may hold the share class simultaneously.
/// @dev Configuration is `abi.encode(uint32 maxHolders)`. Agents are not counted. Once the cap is reached, a transfer
///      still passes if the recipient already holds shares, if both wallets belong to the same identity, or if the
///      sending identity is transferring its whole position.
contract HolderLimitRule is HolderBalanceRuleBase {
    uint32 public maxHolders;
    uint32 public holderCount;

    function moduleId() external pure returns (bytes32) {
        return "HOLDER_CAP";
    }

    function check(address from, address to, uint256 amount) external view returns (bytes32) {
        if (_isSystem(to)) return CheckCodes.OK;
        address toId = _identity(to);
        if (toId == address(0) || identityBalance[toId] != 0) return CheckCodes.OK;
        if (!_isSystem(from)) {
            address fromId = _identity(from);
            if (fromId == toId || identityBalance[fromId] == amount) return CheckCodes.OK;
        }
        return holderCount < maxHolders ? CheckCodes.OK : CheckCodes.HOLDER_CAP_REACHED;
    }

    function _onIdentityFunded(address) internal override {
        ++holderCount;
    }

    function _onIdentityEmptied(address) internal override {
        --holderCount;
    }

    function _configure(bytes calldata config) internal override {
        maxHolders = abi.decode(config, (uint32));
        if (maxHolders == 0) revert InvalidConfig();
    }
}

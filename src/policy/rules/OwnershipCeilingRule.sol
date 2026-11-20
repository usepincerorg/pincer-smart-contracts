// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HolderBalanceRuleBase} from "./PolicyRuleBase.sol";
import {CheckCodes} from "../../common/CheckCodes.sol";

/// @title Ownership cap per identity
/// @notice Prevents any one identity from holding more than a set number of basis points of total supply.
/// @dev Configuration is `abi.encode(uint16 maxBps, bool applyToMints, address[] exemptIdentities)`, giving the cap
///      in basis points, whether mints are checked, and the identities exempt from it. With `applyToMints` false the
///      cap covers transfers only, which lets the registrar import a cap table in any order.
contract OwnershipCeilingRule is HolderBalanceRuleBase {
    uint256 public constant MAX_EXEMPT = 32;

    uint16 public maxBps;
    bool public applyToMints;
    address[] private _exempt;
    mapping(address => bool) public isExempt;

    function moduleId() external pure returns (bytes32) {
        return "MAX_OWNERSHIP";
    }

    function exemptIdentities() external view returns (address[] memory) {
        return _exempt;
    }

    function check(address from, address to, uint256 amount) external view returns (bytes32) {
        if (_isSystem(to)) return CheckCodes.OK;
        if (from == address(0) && !applyToMints) return CheckCodes.OK;
        address toId = _identity(to);
        if (toId == address(0) || isExempt[toId]) return CheckCodes.OK;
        if (from != address(0) && !_isSystem(from) && _identity(from) == toId) return CheckCodes.OK;
        uint256 supply = token.totalSupply() + (from == address(0) ? amount : 0);
        if (supply == 0) return CheckCodes.OK;
        uint256 next = identityBalance[toId] + amount;
        return next * 10_000 > uint256(maxBps) * supply ? CheckCodes.MAX_OWNERSHIP_EXCEEDED : CheckCodes.OK;
    }

    function _configure(bytes calldata config) internal override {
        (uint16 bps, bool mints, address[] memory exempt) = abi.decode(config, (uint16, bool, address[]));
        if (bps == 0 || bps > 10_000 || exempt.length > MAX_EXEMPT) revert InvalidConfig();
        maxBps = bps;
        applyToMints = mints;
        for (uint256 i; i < _exempt.length; ++i) {
            isExempt[_exempt[i]] = false;
        }
        delete _exempt;
        for (uint256 i; i < exempt.length; ++i) {
            address id = exempt[i];
            if (id == address(0)) revert InvalidConfig();
            // Repeated entries are skipped so exemptIdentities() lists each identity once.
            if (isExempt[id]) continue;
            isExempt[id] = true;
            _exempt.push(id);
        }
    }
}

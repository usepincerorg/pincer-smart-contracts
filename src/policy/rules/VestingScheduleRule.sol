// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {HolderBalanceRuleBase} from "./PolicyRuleBase.sol";
import {CheckCodes} from "../../common/CheckCodes.sol";
import {AccessRoles} from "../../common/AccessRoles.sol";

/// @title Locks employee shares that have not vested
/// @notice Unvested shares of an employee remain locked and unlock as the vesting schedule advances. Schedules are
///         tied to the identity, so a person using several wallets is treated as a single holder.
/// @dev Configuration arrives via the engine, which means via the CompanyTimelock, encoded as
///      `abi.encode(uint8 action, bytes payload)`. How `payload` is read depends on the action:
///      - action 0 turns acceleration on or off, with `payload = abi.encode(bool accelerationEnabled)`.
///      - action 1 fully vests one grant, with `payload = abi.encode(address identity, uint256 index)`. It reverts
///        when acceleration is turned off.
///      `addGrants` works differently: because grants come from the cap table, an account with REGISTRAR on the
///      token calls it directly.
///      `cliff` and `duration` are measured from `start`. Before the cliff nothing is vested. After it, vesting is
///      linear from `start` and rounds down, so the amount accrued up to the cliff unlocks at once. Vested shares
///      remain subject to all other rules.
contract VestingScheduleRule is HolderBalanceRuleBase {
    uint256 public constant MAX_GRANTS = 16;
    uint8 public constant ACTION_SET = 0;
    uint8 public constant ACTION_ACCELERATE = 1;

    struct Grant {
        uint64 start;
        uint64 cliff;
        uint64 duration;
        uint256 total;
        bool accelerated;
    }

    event GrantAdded(
        address indexed identity, uint256 index, uint64 start, uint64 cliff, uint64 duration, uint256 total
    );
    event GrantAccelerated(address indexed identity, uint256 index);

    error NotRegistrar();
    error AccelerationDisabled();
    error TooManyGrants();

    bool public accelerationEnabled;
    mapping(address => Grant[]) private _grants;

    function moduleId() external pure returns (bytes32) {
        return "EMPLOYEE_VESTING";
    }

    function grantsOf(address identity) external view returns (Grant[] memory) {
        return _grants[identity];
    }

    function addGrants(address identity, Grant[] calldata grants) external {
        if (!IAccessControl(address(token)).hasRole(AccessRoles.REGISTRAR, msg.sender)) revert NotRegistrar();
        Grant[] storage list = _grants[identity];
        if (list.length + grants.length > MAX_GRANTS) revert TooManyGrants();
        for (uint256 i; i < grants.length; ++i) {
            Grant calldata g = grants[i];
            if (g.duration == 0 || g.cliff > g.duration) revert InvalidConfig();
            list.push(Grant({start: g.start, cliff: g.cliff, duration: g.duration, total: g.total, accelerated: false}));
            emit GrantAdded(identity, list.length - 1, g.start, g.cliff, g.duration, g.total);
        }
    }

    function unvestedOf(address identity) public view returns (uint256 unvested) {
        Grant[] storage list = _grants[identity];
        for (uint256 i; i < list.length; ++i) {
            Grant storage g = list[i];
            unvested += g.total - _vested(g);
        }
    }

    function check(address from, address, uint256 amount) external view returns (bytes32) {
        if (_isSystem(from)) return CheckCodes.OK;
        address id = _identity(from);
        if (id == address(0)) return CheckCodes.OK;
        uint256 unvested = unvestedOf(id);
        if (unvested == 0) return CheckCodes.OK;
        return amount + unvested > identityBalance[id] ? CheckCodes.UNVESTED : CheckCodes.OK;
    }

    function lockedBalance(address holder) external view override returns (uint256) {
        uint256 unvested = unvestedOf(_identity(holder));
        uint256 balance = token.balanceOf(holder);
        return unvested > balance ? balance : unvested;
    }

    function _vested(Grant storage g) private view returns (uint256) {
        if (g.accelerated || block.timestamp >= uint256(g.start) + g.duration) return g.total;
        if (block.timestamp < uint256(g.start) + g.cliff) return 0;
        return (g.total * (block.timestamp - g.start)) / g.duration;
    }

    function _configure(bytes calldata config) internal override {
        (uint8 action, bytes memory payload) = abi.decode(config, (uint8, bytes));
        if (action == ACTION_SET) {
            accelerationEnabled = abi.decode(payload, (bool));
        } else if (action == ACTION_ACCELERATE) {
            if (!accelerationEnabled) revert AccelerationDisabled();
            (address identity, uint256 index) = abi.decode(payload, (address, uint256));
            _grants[identity][index].accelerated = true;
            emit GrantAccelerated(identity, index);
        } else {
            revert InvalidConfig();
        }
    }
}

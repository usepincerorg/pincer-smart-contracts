// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {ITransferPolicy} from "../interfaces/ITransferPolicy.sol";
import {IPolicyRule} from "../interfaces/IPolicyRule.sol";
import {CheckCodes} from "../common/CheckCodes.sol";

/// @title Runs a share class's transfer rules in order
/// @notice Each transfer rule of a share class lives in its own module contract, and this contract invokes them one
///         after another. Companies can therefore add, remove or reconfigure rules without upgrading the token. All
///         such changes need DEFAULT_ADMIN_ROLE, held by the company's CompanyTimelock, which delays module changes
///         by 24 hours by default.
contract TransferPolicy is ITransferPolicy, AccessControl, Initializable {
    uint256 public constant MAX_MODULES = 10;

    error OnlyToken();
    error InvalidModule();
    error ModuleExists();
    error ModuleMissing();
    error TooManyModules();
    error LengthMismatch();

    address private _token;
    address[] private _modules;
    mapping(address => bool) private _enabled;

    constructor() {
        _disableInitializers();
    }

    function initialize(address token_, address admin, address[] calldata modules_, bytes[] calldata configs)
        external
        initializer
    {
        if (token_ == address(0) || admin == address(0)) revert InvalidModule();
        if (modules_.length != configs.length) revert LengthMismatch();
        _token = token_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        for (uint256 i; i < modules_.length; ++i) {
            _add(modules_[i], configs[i]);
        }
    }

    function token() external view returns (address) {
        return _token;
    }

    function modules() external view returns (address[] memory) {
        return _modules;
    }

    function hasModule(bytes32 moduleId) external view returns (bool) {
        for (uint256 i; i < _modules.length; ++i) {
            if (IPolicyRule(_modules[i]).moduleId() == moduleId) return true;
        }
        return false;
    }

    function check(address from, address to, uint256 amount) external view returns (bytes32) {
        for (uint256 i; i < _modules.length; ++i) {
            bytes32 code = IPolicyRule(_modules[i]).check(from, to, amount);
            if (code != CheckCodes.OK) return code;
        }
        return CheckCodes.OK;
    }

    function transferred(address from, address to, uint256 amount, address operator) external {
        if (msg.sender != _token) revert OnlyToken();
        for (uint256 i; i < _modules.length; ++i) {
            IPolicyRule(_modules[i]).onTransfer(from, to, amount, operator);
        }
    }

    function lockedBalance(address holder) external view returns (uint256 total) {
        for (uint256 i; i < _modules.length; ++i) {
            total += IPolicyRule(_modules[i]).lockedBalance(holder);
        }
    }

    function addModule(address module, bytes calldata config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _add(module, config);
    }

    function removeModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_enabled[module]) revert ModuleMissing();
        _enabled[module] = false;
        uint256 n = _modules.length;
        for (uint256 i; i < n; ++i) {
            if (_modules[i] == module) {
                // Shift the later entries down rather than moving the last one into the gap, so the order the
                // company set up, which the loops above follow, is preserved.
                for (uint256 j = i; j + 1 < n; ++j) {
                    _modules[j] = _modules[j + 1];
                }
                _modules.pop();
                break;
            }
        }
        emit ModuleRemoved(module);
    }

    function configureModule(address module, bytes calldata config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_enabled[module]) revert ModuleMissing();
        IPolicyRule(module).configure(config);
        emit ModuleConfigured(module, keccak256(config));
    }

    function _add(address module, bytes calldata config) private {
        if (module == address(0) || IPolicyRule(module).engine() != address(this)) revert InvalidModule();
        if (_enabled[module]) revert ModuleExists();
        if (_modules.length >= MAX_MODULES) revert TooManyModules();
        _enabled[module] = true;
        _modules.push(module);
        IPolicyRule(module).configure(config);
        emit ModuleAdded(module);
        emit ModuleConfigured(module, keccak256(config));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {IPolicyRule} from "../../interfaces/IPolicyRule.sol";
import {IPincerEquityToken} from "../../interfaces/IPincerEquityToken.sol";
import {IHolderRegistry} from "../../interfaces/IHolderRegistry.sol";

/// @title Shared base for transfer rule modules
/// @notice Provides the plumbing that all rules share. A module instance is bound to a single engine and a single
///         token.
/// @dev "System" parties are the zero address (a mint or burn) and agents, which are escrow contracts and approved
///      venues. Recipient-side rules skip system recipients and sender-side rules skip system senders, so rules
///      apply to the actual holders on each side of a trade.
abstract contract PolicyRuleBase is IPolicyRule, Initializable {
    error OnlyEngine();
    error InvalidConfig();

    address public engine;
    IPincerEquityToken public token;
    IHolderRegistry public registry;

    constructor() {
        _disableInitializers();
    }

    function initialize(address engine_, address token_) external initializer {
        if (engine_ == address(0) || token_ == address(0)) revert InvalidConfig();
        engine = engine_;
        token = IPincerEquityToken(token_);
        registry = IPincerEquityToken(token_).identityRegistry();
    }

    modifier onlyEngine() {
        if (msg.sender != engine) revert OnlyEngine();
        _;
    }

    function configure(bytes calldata config) external onlyEngine {
        _configure(config);
    }

    function onTransfer(address from, address to, uint256 amount, address operator) external onlyEngine {
        _onTransfer(from, to, amount, operator);
    }

    function lockedBalance(address) external view virtual returns (uint256) {
        return 0;
    }

    function _configure(bytes calldata config) internal virtual;

    function _onTransfer(address from, address to, uint256 amount, address operator) internal virtual {}

    function _isSystem(address account) internal view returns (bool) {
        return account == address(0) || token.isAgent(account);
    }

    function _identity(address wallet) internal view returns (address) {
        return registry.identityOf(wallet);
    }
}

/// @title Rule module base that tracks balances per identity
/// @notice Modules for holder caps, ownership caps and vesting need an identity's total across all of its wallets,
///         so they extend this contract. Tracking only starts when the module is added, so a share class should get
///         these modules when it is deployed, before anything is minted.
abstract contract HolderBalanceRuleBase is PolicyRuleBase {
    mapping(address => uint256) public identityBalance;

    function _onTransfer(address from, address to, uint256 amount, address) internal virtual override {
        address fromId = _isSystem(from) ? address(0) : _identity(from);
        address toId = _isSystem(to) ? address(0) : _identity(to);
        if (fromId == toId) return;
        if (fromId != address(0)) {
            uint256 before = identityBalance[fromId];
            uint256 next = before > amount ? before - amount : 0;
            identityBalance[fromId] = next;
            if (before != 0 && next == 0) _onIdentityEmptied(fromId);
        }
        if (toId != address(0)) {
            uint256 before = identityBalance[toId];
            identityBalance[toId] = before + amount;
            if (before == 0 && amount != 0) _onIdentityFunded(toId);
        }
    }

    function _onIdentityEmptied(address identity) internal virtual {}

    function _onIdentityFunded(address identity) internal virtual {}
}

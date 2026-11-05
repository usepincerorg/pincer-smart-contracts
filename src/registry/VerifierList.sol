// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {IVerifierList} from "../interfaces/IVerifierList.sol";

/// @title Allowlist of claim verifiers for one company
/// @notice Tracks which verifier keys may sign each claim topic for a single company. The initial list is set at
///         deployment and defaults to Pincer's identity providers if the company supplies none. After that, the
///         company's CompanyTimelock is responsible for adding and removing verifiers.
contract VerifierList is IVerifierList, AccessControl, Initializable {
    uint256 public constant MAX_TOPICS = 16;

    error InvalidVerifier();
    error TooManyTopics();
    error UnknownVerifier();
    error LengthMismatch();

    mapping(address => mapping(bytes32 => bool)) private _trusted;
    mapping(address => bytes32[]) private _topics;

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address[] calldata verifiers, bytes32[][] calldata topics) external initializer {
        if (verifiers.length != topics.length) revert LengthMismatch();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        for (uint256 i; i < verifiers.length; ++i) {
            _add(verifiers[i], topics[i]);
        }
    }

    function addVerifier(address verifier, bytes32[] calldata topics) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _remove(verifier);
        _add(verifier, topics);
    }

    function removeVerifier(address verifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_topics[verifier].length == 0) revert UnknownVerifier();
        _remove(verifier);
        emit VerifierRemoved(verifier);
    }

    function isTrusted(address verifier, bytes32 topic) external view returns (bool) {
        return _trusted[verifier][topic];
    }

    function topicsOf(address verifier) external view returns (bytes32[] memory) {
        return _topics[verifier];
    }

    function _add(address verifier, bytes32[] calldata topics) private {
        if (verifier == address(0)) revert InvalidVerifier();
        if (topics.length > MAX_TOPICS) revert TooManyTopics();
        for (uint256 i; i < topics.length; ++i) {
            if (!_trusted[verifier][topics[i]]) {
                _trusted[verifier][topics[i]] = true;
                _topics[verifier].push(topics[i]);
            }
        }
        emit VerifierAdded(verifier, topics);
    }

    function _remove(address verifier) private {
        bytes32[] storage list = _topics[verifier];
        for (uint256 i; i < list.length; ++i) {
            _trusted[verifier][list[i]] = false;
        }
        delete _topics[verifier];
    }
}

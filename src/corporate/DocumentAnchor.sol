// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {AccessRoles} from "../common/AccessRoles.sol";

/// @title Registry that anchors company document hashes on-chain
/// @notice Only a hash of each company document lives here; the files themselves stay off-chain behind whatever
///         access control the company uses. Anyone holding a copy can verify it by hashing it with SHA-256 and
///         comparing the result to the stored entry. Using SHA-256 is an agreement among anchorers, not something
///         enforced on-chain: the only hash value refused here is zero.
contract DocumentAnchor is AccessControl, Initializable {
    bytes32 public constant SHARE_CLASS_TERMS = "SHARE_CLASS_TERMS";
    bytes32 public constant OFFERING_DOCUMENT = "OFFERING_DOCUMENT";
    bytes32 public constant FINANCIAL_STATEMENT = "FINANCIAL_STATEMENT";
    bytes32 public constant COMPANY_UPDATE = "COMPANY_UPDATE";
    bytes32 public constant BOARD_RESOLUTION = "BOARD_RESOLUTION";
    bytes32 public constant VALUATION_REPORT = "VALUATION_REPORT";

    struct Document {
        bytes32 kind;
        bytes32 hash;
        string uri;
        uint64 timestamp;
    }

    event DocumentAnchored(uint256 indexed documentId, bytes32 indexed kind, bytes32 hash, string uri);

    error InvalidKind();
    error InvalidHash();
    error UnknownDocument();
    error AlreadyAnchored(uint256 documentId);

    bytes32 private _companyId;
    Document[] private _documents;
    mapping(bytes32 => uint256) public documentIdByHash;
    /// @notice For each kind, the id of the most recently anchored document, or 0 if nothing of that kind exists yet.
    mapping(bytes32 => uint256) public latestDocumentIdOfKind;

    constructor() {
        _disableInitializers();
    }

    function initialize(bytes32 companyId_, address admin, address[] calldata anchorers) external initializer {
        _companyId = companyId_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        for (uint256 i; i < anchorers.length; ++i) {
            _grantRole(AccessRoles.ANCHORER, anchorers[i]);
        }
    }

    function companyId() external view returns (bytes32) {
        return _companyId;
    }

    /// @notice Reverts on a hash that is already anchored, so `documentIdByHash` always resolves to the original
    ///         record for it.
    /// @return documentId Ids start at 1, which leaves 0 free to mean "no document".
    function anchor(bytes32 kind, bytes32 hash, string calldata uri)
        external
        onlyRole(AccessRoles.ANCHORER)
        returns (uint256 documentId)
    {
        if (!isKnownKind(kind)) revert InvalidKind();
        if (hash == bytes32(0)) revert InvalidHash();
        if (documentIdByHash[hash] != 0) revert AlreadyAnchored(documentIdByHash[hash]);
        _documents.push(Document({kind: kind, hash: hash, uri: uri, timestamp: uint64(block.timestamp)}));
        documentId = _documents.length;
        documentIdByHash[hash] = documentId;
        latestDocumentIdOfKind[kind] = documentId;
        emit DocumentAnchored(documentId, kind, hash, uri);
    }

    function document(uint256 documentId) external view returns (Document memory) {
        if (documentId == 0 || documentId > _documents.length) revert UnknownDocument();
        return _documents[documentId - 1];
    }

    /// @notice Most recent document of `kind`. Reverts with UnknownDocument if none of that kind has been anchored.
    function latestDocumentOfKind(bytes32 kind) external view returns (Document memory) {
        uint256 documentId = latestDocumentIdOfKind[kind];
        if (documentId == 0) revert UnknownDocument();
        return _documents[documentId - 1];
    }

    /// @notice True when `hash` has been anchored, which is all a holder needs to check that their copy of a
    ///         document is one the company published.
    function isAnchored(bytes32 hash) external view returns (bool) {
        return documentIdByHash[hash] != 0;
    }

    function documentCount() external view returns (uint256) {
        return _documents.length;
    }

    function isKnownKind(bytes32 kind) public pure returns (bool) {
        return kind == SHARE_CLASS_TERMS || kind == OFFERING_DOCUMENT || kind == FINANCIAL_STATEMENT
            || kind == COMPANY_UPDATE || kind == BOARD_RESOLUTION || kind == VALUATION_REPORT;
    }
}

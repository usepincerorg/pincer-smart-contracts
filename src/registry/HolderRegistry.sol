// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {IHolderRegistry} from "../interfaces/IHolderRegistry.sol";
import {IVerifierList} from "../interfaces/IVerifierList.sol";
import {ClaimTopics} from "../common/ClaimTopics.sol";
import {AccessRoles} from "../common/AccessRoles.sol";

/// @title Identity directory and claim store for a single company
/// @notice Maps every holder wallet of a company to an identity and stores the claims that trusted verifiers have
///         made about it. No personal data is stored. Each claim is only a topic, the verifier, an expiry and a short
///         machine-readable value such as a tier, a country code or a company id. Since the contract does not look
///         at that value, verifiers are responsible for keeping personal data out of it.
/// @dev An identity is a plain address. It can be a dedicated identity contract or simply a stable identifier that
///      Pincer assigns, and several wallets can share one identity. Verifiers may submit claims directly, or anyone
///      with an EIP-712 signature from the verifier may relay the claim. Each relayed signature is accepted only
///      once, so an old signature cannot bring back a claim that was revoked.
contract HolderRegistry is IHolderRegistry, AccessControl, Initializable, EIP712 {
    bytes32 public constant CLAIM_TYPEHASH = keccak256(
        "Claim(address identity,bytes32 topic,bytes32 dataHash,uint64 expiry,bytes32 companyId,address registry)"
    );

    error InvalidAddress();
    error UntrustedVerifier();
    error InvalidSignature();
    error SignatureUsed();
    error ClaimExpired();
    error NotAuthorized();
    error UnknownIdentity();
    error NoClaim();

    bytes32 private _companyId;
    IVerifierList private _verifiers;

    mapping(address => address) private _identityOf;
    mapping(address => mapping(bytes32 => Claim)) private _claims;
    mapping(bytes32 => bool) public usedDigests;

    constructor() EIP712("Pincer", "1") {
        _disableInitializers();
    }

    function initialize(bytes32 companyId_, address trustedVerifiers_, address admin, address operator)
        external
        initializer
    {
        if (trustedVerifiers_ == address(0) || admin == address(0)) revert InvalidAddress();
        _companyId = companyId_;
        _verifiers = IVerifierList(trustedVerifiers_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(AccessRoles.OPERATOR, operator);
    }

    function companyId() external view returns (bytes32) {
        return _companyId;
    }

    function trustedVerifiers() external view returns (IVerifierList) {
        return _verifiers;
    }

    // ===== Wallet to identity links =====

    function registerIdentity(address wallet, address identity) external onlyRole(AccessRoles.OPERATOR) {
        if (wallet == address(0) || identity == address(0)) revert InvalidAddress();
        _identityOf[wallet] = identity;
        emit IdentityRegistered(wallet, identity);
    }

    function removeIdentity(address wallet) external onlyRole(AccessRoles.OPERATOR) {
        if (_identityOf[wallet] == address(0)) revert UnknownIdentity();
        delete _identityOf[wallet];
        emit IdentityRemoved(wallet);
    }

    function identityOf(address wallet) public view returns (address) {
        return _identityOf[wallet];
    }

    // ===== Claim submission and revocation =====

    function claimDigest(address identity, bytes32 topic, bytes calldata data, uint64 expiry)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(CLAIM_TYPEHASH, identity, topic, keccak256(data), expiry, _companyId, address(this)))
        );
    }

    function addClaim(
        address identity,
        bytes32 topic,
        bytes calldata data,
        uint64 expiry,
        address verifier,
        bytes calldata signature
    ) external {
        if (identity == address(0)) revert InvalidAddress();
        if (expiry <= block.timestamp) revert ClaimExpired();
        if (!_verifiers.isTrusted(verifier, topic)) revert UntrustedVerifier();

        if (msg.sender != verifier) {
            bytes32 digest = claimDigest(identity, topic, data, expiry);
            if (usedDigests[digest]) revert SignatureUsed();
            if (!SignatureChecker.isValidSignatureNow(verifier, digest, signature)) revert InvalidSignature();
            usedDigests[digest] = true;
        }

        _claims[identity][topic] = Claim({verifier: verifier, expiry: expiry, data: data});
        emit ClaimAdded(identity, topic, verifier, expiry);
    }

    function revokeClaim(address identity, bytes32 topic) external {
        Claim storage c = _claims[identity][topic];
        if (c.verifier == address(0)) revert NoClaim();
        if (msg.sender != c.verifier && !hasRole(AccessRoles.OPERATOR, msg.sender)) revert NotAuthorized();
        delete _claims[identity][topic];
        emit ClaimRevoked(identity, topic);
    }

    function claimOf(address identity, bytes32 topic) external view returns (Claim memory) {
        return _claims[identity][topic];
    }

    // ===== Verification lookups =====

    function isVerified(address wallet) external view returns (bool) {
        return status(wallet) == Status.VERIFIED;
    }

    /// @notice Verification check run on every transfer party that is not a system address. A wallet passes only
    ///         if it has a linked identity with valid IDENTITY_VERIFIED and SCREENED claims. NOT_VERIFIED is returned
    ///         when the link or either claim is missing, and it takes precedence over expiry. CLAIM_EXPIRED means a
    ///         claim exists but has expired or its verifier is no longer trusted, which tells the holder that
    ///         re-verification will resolve it.
    function status(address wallet) public view returns (Status) {
        address identity = _identityOf[wallet];
        if (identity == address(0)) return Status.NOT_VERIFIED;
        Status a = _claimStatus(identity, ClaimTopics.IDENTITY_VERIFIED);
        if (a == Status.NOT_VERIFIED) return a;
        Status b = _claimStatus(identity, ClaimTopics.SCREENED);
        if (b == Status.NOT_VERIFIED) return b;
        if (a == Status.CLAIM_EXPIRED || b == Status.CLAIM_EXPIRED) return Status.CLAIM_EXPIRED;
        return Status.VERIFIED;
    }

    function hasValidClaim(address wallet, bytes32 topic) external view returns (bool) {
        address identity = _identityOf[wallet];
        return identity != address(0) && _claimStatus(identity, topic) == Status.VERIFIED;
    }

    function claimData(address wallet, bytes32 topic) external view returns (bytes memory) {
        return _claims[_identityOf[wallet]][topic].data;
    }

    function _claimStatus(address identity, bytes32 topic) private view returns (Status) {
        Claim storage c = _claims[identity][topic];
        if (c.verifier == address(0)) return Status.NOT_VERIFIED;
        if (c.expiry <= block.timestamp || !_verifiers.isTrusted(c.verifier, topic)) return Status.CLAIM_EXPIRED;
        return Status.VERIFIED;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Access control role identifiers
/// @notice The shared list of roles that Pincer contracts check against. At deployment `DEFAULT_ADMIN_ROLE` (0x00)
///         is handed to the company's CompanyTimelock, so every action it guards needs signer approval and must also
///         wait out a delay.
library AccessRoles {
    /// @dev Intended for the operational multi-sig of the company. That multi-sig manages offerings, windows,
    ///      distributions, votes and documents.
    bytes32 internal constant ISSUER_ADMIN = keccak256("pincer.role.ISSUER_ADMIN");
    /// @dev Maintains the authoritative cap table and may mint, burn, freeze and perform recoveries.
    bytes32 internal constant REGISTRAR = keccak256("pincer.role.REGISTRAR");
    /// @dev Per-company relayer operated by Pincer that registers identities and co-signs recoveries.
    bytes32 internal constant OPERATOR = keccak256("pincer.role.OPERATOR");
    /// @dev Pauses or unpauses a share token immediately, without any delay.
    bytes32 internal constant PAUSER = keccak256("pincer.role.PAUSER");
    /// @dev Allows minting by a contract such as the RaiseEscrow that does not hold REGISTRAR.
    bytes32 internal constant MINTER = keccak256("pincer.role.MINTER");
    /// @dev Gates publication of a Reference Valuation.
    bytes32 internal constant PUBLISHER = keccak256("pincer.role.PUBLISHER");
    /// @dev Gates anchoring of documents.
    bytes32 internal constant ANCHORER = keccak256("pincer.role.ANCHORER");
}

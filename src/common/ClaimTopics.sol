// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Constants for claim topics
/// @notice Topics that Pincer contracts query in the HolderRegistry, each stored as a bytes32 string aligned to the
///         left.
library ClaimTopics {
    /// @dev Set once the holder completes identity verification. No data is attached.
    bytes32 internal constant IDENTITY_VERIFIED = "IDENTITY_VERIFIED";
    /// @dev Eligibility tier of the investor, stored as `abi.encode(uint8 tier)`.
    bytes32 internal constant INVESTOR_ELIGIBLE = "INVESTOR_ELIGIBLE";
    /// @dev Country of residence of the holder, stored as `abi.encode(bytes2 iso3166Alpha2)`.
    bytes32 internal constant REGION = "REGION";
    /// @dev Company that employs the holder, stored as `abi.encode(bytes32 companyId)`.
    bytes32 internal constant EMPLOYEE_OF = "EMPLOYEE_OF";
    /// @dev Screening passed. The data records when, as `abi.encode(uint64 lastScreenedAt)`.
    bytes32 internal constant SCREENED = "SCREENED";
    /// @dev Flags a contract, such as a permissioned pool, as an approved venue. The claim data names the share
    ///      token the approval applies to, as `abi.encode(address shareToken)`.
    bytes32 internal constant VENUE = "VENUE";
}

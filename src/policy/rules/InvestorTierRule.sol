// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PolicyRuleBase} from "./PolicyRuleBase.sol";
import {CheckCodes} from "../../common/CheckCodes.sol";
import {ClaimTopics} from "../../common/ClaimTopics.sol";

/// @title Minimum investor tier for recipients
/// @notice Recipients must hold a valid INVESTOR_ELIGIBLE claim with a tier at or above the configured minimum.
/// @dev Configuration is `abi.encode(uint8 minimumTier, bool exemptEmployees)`. With `exemptEmployees` set, anyone
///      holding a valid EMPLOYEE_OF claim for this company skips the tier requirement.
contract InvestorTierRule is PolicyRuleBase {
    uint8 public minimumTier;
    bool public exemptEmployees;

    function moduleId() external pure returns (bytes32) {
        return "ELIGIBILITY";
    }

    function check(address, address to, uint256) external view returns (bytes32) {
        if (_isSystem(to)) return CheckCodes.OK;
        if (exemptEmployees && registry.hasValidClaim(to, ClaimTopics.EMPLOYEE_OF)) {
            bytes32 employer = abi.decode(registry.claimData(to, ClaimTopics.EMPLOYEE_OF), (bytes32));
            if (employer == token.companyId()) return CheckCodes.OK;
        }
        if (!registry.hasValidClaim(to, ClaimTopics.INVESTOR_ELIGIBLE)) return CheckCodes.NOT_ELIGIBLE;
        uint8 tier = abi.decode(registry.claimData(to, ClaimTopics.INVESTOR_ELIGIBLE), (uint8));
        return tier >= minimumTier ? CheckCodes.OK : CheckCodes.NOT_ELIGIBLE;
    }

    function _configure(bytes calldata config) internal override {
        (minimumTier, exemptEmployees) = abi.decode(config, (uint8, bool));
    }
}

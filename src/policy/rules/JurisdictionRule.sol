// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PolicyRuleBase} from "./PolicyRuleBase.sol";
import {CheckCodes} from "../../common/CheckCodes.sol";
import {ClaimTopics} from "../../common/ClaimTopics.sol";

/// @title Recipient country allow list or block list
/// @notice Decides whether a recipient can receive shares from the ISO 3166 alpha-2 country code in its REGION
///         claim.
/// @dev Configuration is `abi.encode(uint8 mode, bytes2[] regions)`, where mode 0 means ALLOW_LIST and mode 1 means
///      BLOCK_LIST. Under either mode, a recipient without a valid REGION claim is rejected.
contract JurisdictionRule is PolicyRuleBase {
    uint8 public constant ALLOW_LIST = 0;
    uint8 public constant BLOCK_LIST = 1;
    uint256 public constant MAX_REGIONS = 250;

    uint8 public mode;
    bytes2[] private _regions;
    mapping(bytes2 => bool) public listed;

    function moduleId() external pure returns (bytes32) {
        return "REGION";
    }

    function regions() external view returns (bytes2[] memory) {
        return _regions;
    }

    function check(address, address to, uint256) external view returns (bytes32) {
        if (_isSystem(to)) return CheckCodes.OK;
        if (!registry.hasValidClaim(to, ClaimTopics.REGION)) return CheckCodes.REGION_BLOCKED;
        bytes2 region = abi.decode(registry.claimData(to, ClaimTopics.REGION), (bytes2));
        bool isListed = listed[region];
        if (mode == ALLOW_LIST) return isListed ? CheckCodes.OK : CheckCodes.REGION_BLOCKED;
        return isListed ? CheckCodes.REGION_BLOCKED : CheckCodes.OK;
    }

    function _configure(bytes calldata config) internal override {
        (uint8 mode_, bytes2[] memory regions_) = abi.decode(config, (uint8, bytes2[]));
        if (mode_ > BLOCK_LIST || regions_.length > MAX_REGIONS) revert InvalidConfig();
        for (uint256 i; i < _regions.length; ++i) {
            listed[_regions[i]] = false;
        }
        delete _regions;
        mode = mode_;
        for (uint256 i; i < regions_.length; ++i) {
            if (!listed[regions_[i]]) {
                listed[regions_[i]] = true;
                _regions.push(regions_[i]);
            }
        }
    }
}

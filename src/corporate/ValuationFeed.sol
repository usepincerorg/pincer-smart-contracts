// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IValuationFeed} from "../interfaces/IValuationFeed.sol";
import {IPincerEquityToken} from "../interfaces/IPincerEquityToken.sol";
import {AccessRoles} from "../common/AccessRoles.sol";

/// @title Per-class feed for the Reference Valuation
/// @notice One instance is deployed per share class. It publishes the Reference Valuation: a per-share USD price
///         carrying 8 decimals, together with the date it applies to and where it came from. Since the contract
///         speaks Chainlink's AggregatorV3 interface, lending markets and dashboards can read it as is. For the
///         source, date and backing document, call the additional `latestValuation()` getter.
/// @dev A Reference Valuation is not a live market quote. `updatedAt` reports `asOf` (the date the valuation is
///      for) instead of the time it was published, so staleness checks measure how old the figure really is.
///      Publishing is blocked while the share token is paused, which freezes the feed at its previous value for the
///      length of the pause. A corporate action is only protected this way when the token gets paused for it;
///      scheduling a multiplier on its own leaves the token unpaused.
contract ValuationFeed is IValuationFeed, AccessControl, Initializable {
    struct Round {
        int256 price;
        uint8 source;
        uint64 asOf;
        uint64 publishedAt;
        bytes32 documentHash;
    }

    error InvalidPrice();
    error InvalidSource();
    error InvalidDate();
    error TokenPaused();
    error NoData();

    address private _token;
    Round[] private _rounds;

    constructor() {
        _disableInitializers();
    }

    function initialize(address token_, address admin, address[] calldata publishers) external initializer {
        _token = token_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        for (uint256 i; i < publishers.length; ++i) {
            _grantRole(AccessRoles.PUBLISHER, publishers[i]);
        }
    }

    function token() external view returns (address) {
        return _token;
    }

    function publish(int256 price, uint8 source, uint64 asOf, bytes32 documentHash) external onlyRole(AccessRoles.PUBLISHER) {
        if (price <= 0) revert InvalidPrice();
        if (source > uint8(Source.WINDOW_CLEARING)) revert InvalidSource();
        if (asOf == 0 || asOf > block.timestamp) revert InvalidDate();
        // Dates may not go backwards relative to the previous round, so the last round is always the most recent
        // valuation. A matching date is allowed, in which case the newer publication takes precedence.
        if (_rounds.length != 0 && asOf < _rounds[_rounds.length - 1].asOf) revert InvalidDate();
        if (IPincerEquityToken(_token).paused()) revert TokenPaused();
        _rounds.push(
            Round({
                price: price,
                source: source,
                asOf: asOf,
                publishedAt: uint64(block.timestamp),
                documentHash: documentHash
            })
        );
        emit ValuationPublished(price, source, asOf, documentHash);
    }

    function latestValuation() external view returns (int256 price, uint8 source, uint64 asOf, bytes32 documentHash) {
        if (_rounds.length == 0) revert NoData();
        Round storage r = _rounds[_rounds.length - 1];
        return (r.price, r.source, r.asOf, r.documentHash);
    }

    /// @notice Full stored record for one round. Unlike getRoundData, it includes the source, the backing document
    ///         and when the round was published.
    function round(uint80 roundId) external view returns (Round memory) {
        if (roundId == 0 || roundId > _rounds.length) revert NoData();
        return _rounds[roundId - 1];
    }

    function roundCount() external view returns (uint256) {
        return _rounds.length;
    }

    /* ---------- AggregatorV3Interface view functions ---------- */

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external view returns (string memory) {
        return string.concat(IERC20Metadata(_token).symbol(), " / USD reference valuation");
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 roundId) public view returns (uint80, int256, uint256, uint256, uint80) {
        if (roundId == 0 || roundId > _rounds.length) revert NoData();
        Round storage r = _rounds[roundId - 1];
        return (roundId, r.price, r.asOf, r.asOf, roundId);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (_rounds.length == 0) revert NoData();
        return getRoundData(uint80(_rounds.length));
    }
}

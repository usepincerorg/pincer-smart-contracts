// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Read-only surface of a Chainlink price feed. Matching it lets current integrations consume Reference
///         Valuations without modification.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IValuationFeed is AggregatorV3Interface {
    /// @dev Passed as a uint8: 0 means PRICED_ROUND, 1 INDEPENDENT_VALUATION, 2 WINDOW_CLEARING.
    enum Source {
        PRICED_ROUND,
        INDEPENDENT_VALUATION,
        WINDOW_CLEARING
    }

    event ValuationPublished(int256 price, uint8 source, uint64 asOf, bytes32 documentHash);

    function token() external view returns (address);
    function publish(int256 price, uint8 source, uint64 asOf, bytes32 documentHash) external;

    /// @return price USD price per share, scaled to 8 decimals.
    function latestValuation() external view returns (int256 price, uint8 source, uint64 asOf, bytes32 documentHash);
}

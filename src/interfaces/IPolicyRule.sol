// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice One transfer condition. Each deployed rule belongs to exactly one TransferPolicy, which in turn serves a
///         single share class.
interface IPolicyRule {
    /// @notice Constant identifier for the kind of rule, such as "REGION" or "ROFR".
    function moduleId() external pure returns (bytes32);
    function engine() external view returns (address);

    /// @notice Returns `OK` if the transfer satisfies this rule, otherwise the rule's specific reason code.
    function check(address from, address to, uint256 amount) external view returns (bytes32 reasonCode);

    /// @notice Hook the engine calls after balances change, so the rule can record whatever state it tracks.
    function onTransfer(address from, address to, uint256 amount, address operator) external;

    /// @notice Callable by the engine only. Some rules replace their settings with `config`, others append to them.
    function configure(bytes calldata config) external;

    /// @notice Amount of `holder`'s balance that this rule currently keeps from being transferred.
    function lockedBalance(address holder) external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITransferPolicy {
    event ModuleAdded(address indexed module);
    event ModuleRemoved(address indexed module);
    event ModuleConfigured(address indexed module, bytes32 configHash);

    function token() external view returns (address);
    function modules() external view returns (address[] memory);
    function hasModule(bytes32 moduleId) external view returns (bool);

    /// @notice Runs every enabled module in sequence. The first one that fails ends the check and its reason code is
    ///         returned; `OK` means every module passed.
    function check(address from, address to, uint256 amount) external view returns (bytes32 reasonCode);

    /// @notice Post-transfer hook called by the token after balances change, so modules that keep state can update.
    /// @param operator Account that moved the tokens, which is the caller of the token, or the token itself during a
    ///        recovery. New lots record this value as their acquisition source.
    function transferred(address from, address to, uint256 amount, address operator) external;

    /// @notice Sum of the amounts every module locks, for example lockups and vesting. Overlapping locks are added
    ///         together rather than collapsed to the biggest one, so the figure is deliberately conservative.
    function lockedBalance(address holder) external view returns (uint256);

    function addModule(address module, bytes calldata config) external;
    function removeModule(address module) external;
    function configureModule(address module, bytes calldata config) external;
}

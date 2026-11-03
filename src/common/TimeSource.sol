// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

/// @title Snapshot clock that understands Arbitrum
/// @notice Returns the timepoint used for balance snapshots, which covers both record blocks and vote snapshots.
/// @dev On Arbitrum chains, including Robinhood Chain, `block.number` cannot be used: it only approximates the L1
///      block number, which advances much more slowly than L2 blocks do. The ArbSys precompile returns the true L2
///      block number. Nitro places a one-byte stub at each precompile address, so a nonzero code size is enough to
///      tell that the chain is Arbitrum. Everywhere else, for example local Anvil or Foundry tests, the library falls
///      back to `block.number`.
///
///      When a local EVM forks an Arbitrum chain it may see the stub but not implement the precompile, and the call
///      then fails. This happens in the Foundry simulation that runs before each `forge script` broadcast. That is
///      why the ArbSys read goes through a staticcall with a gas cap and falls back on failure.
library TimeSource {
    address internal constant ARB_SYS = address(100);
    uint256 private constant CALL_GAS = 20_000;

    function now48() internal view returns (uint48) {
        if (ARB_SYS.code.length > 0) {
            (bool ok, bytes memory ret) = ARB_SYS.staticcall{gas: CALL_GAS}(abi.encodeCall(IArbSys.arbBlockNumber, ()));
            if (ok && ret.length == 32) return uint48(abi.decode(ret, (uint256)));
        }
        return uint48(block.number);
    }
}

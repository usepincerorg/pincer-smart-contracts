// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Test stablecoin with open minting and 6 decimals
/// @notice Stands in for USDG in the test suite and on testnet. Anyone can call `mint`, so deploying this contract
///         to mainnet is never acceptable.
contract TestDollar is ERC20 {
    constructor() ERC20("Test USDG", "tUSDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

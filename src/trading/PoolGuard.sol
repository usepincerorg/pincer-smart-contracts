// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {IPincerEquityToken} from "../interfaces/IPincerEquityToken.sol";
import {CheckCodes} from "../common/CheckCodes.sol";

/// @title PoolGuard: share class eligibility checks for permissioned AMM pools
/// @notice Permissioned AMM pools consult this contract before each swap, each liquidity deposit and each LP position
///         transfer, which extends the share class rules to whoever finally receives shares and to every liquidity
///         provider.
/// @dev A pool can only be registered once the token treats it as an agent, which usually means the company's
///      HolderRegistry holds a VENUE claim for it tied to this token. The token looks through agents and applies its
///      rules to the parties behind them. Since the token itself already checks recipients when the pool pays out
///      shares, the value here lies in failing sooner with a readable reason code, and in gating LP positions, which
///      are not share tokens at all.
///      Instant swaps leave no room to exercise a right of first refusal, so `registerPool` rejects any share class
///      that has that rule installed. This check runs at registration time only.
contract PoolGuard is AccessControl, Initializable {
    event PoolRegistered(address indexed pool);
    event PoolRemoved(address indexed pool);

    error ROFRIncompatible();
    error NotVenue();
    error UnknownPool();
    error PoolAlreadyRegistered();

    IPincerEquityToken public token;
    mapping(address => bool) public isPool;

    constructor() {
        _disableInitializers();
    }

    function initialize(address token_, address admin) external initializer {
        token = IPincerEquityToken(token_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function registerPool(address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (isPool[pool]) revert PoolAlreadyRegistered();
        if (token.ruleEngine().hasModule("ROFR")) revert ROFRIncompatible();
        if (!token.isAgent(pool)) revert NotVenue();
        isPool[pool] = true;
        emit PoolRegistered(pool);
    }

    function removePool(address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isPool[pool]) revert UnknownPool();
        isPool[pool] = false;
        emit PoolRemoved(pool);
    }

    /// @notice Returns the reason code the share class rules give for a transfer of `amount` shares from `pool` to
    ///         `recipient`. A pool that is not registered always yields NOT_ELIGIBLE.
    function checkSwap(address pool, address recipient, uint256 amount) public view returns (bytes32) {
        if (!isPool[pool]) return CheckCodes.NOT_ELIGIBLE;
        (, bytes32 code) = token.canTransfer(pool, recipient, amount);
        return code;
    }

    /// @notice Returns the reason code for `provider` holding an LP position in `pool`; unregistered pools yield
    ///         NOT_ELIGIBLE. The check treats the provider as receiving a zero amount from the pool, so all
    ///         recipient-side rules apply while amount-based limits count no shares.
    function checkLiquidityProvider(address pool, address provider) public view returns (bytes32) {
        if (!isPool[pool]) return CheckCodes.NOT_ELIGIBLE;
        (, bytes32 code) = token.canTransfer(pool, provider, 0);
        return code;
    }

    function beforeSwap(address recipient, uint256 sharesOut) external view {
        _require(checkSwap(msg.sender, recipient, sharesOut));
    }

    function beforeAddLiquidity(address provider) external view {
        _require(checkLiquidityProvider(msg.sender, provider));
    }

    function beforeTransferPosition(address, address to) external view {
        _require(checkLiquidityProvider(msg.sender, to));
    }

    function _require(bytes32 code) private pure {
        if (code != CheckCodes.OK) revert IPincerEquityToken.TransferNotAllowed(code);
    }
}

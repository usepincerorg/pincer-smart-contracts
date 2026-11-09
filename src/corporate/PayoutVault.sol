// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPincerEquityToken} from "../interfaces/IPincerEquityToken.sol";
import {IPincerDeployer} from "../interfaces/IPincerDeployer.sol";
import {AccessRoles} from "../common/AccessRoles.sol";

/// @title Vault that pays dividends and other proceeds to one share class at a time
/// @notice Every distribution is funded by the company with reference to a record block in the past, and the money is
///         owed to that class's holders. Each holder's share of the funded amount equals their record-block balance
///         divided by the eligible supply. Payments are pull-based: the holder, or someone on their behalf, claims
///         whenever they like.
/// @dev Shares are computed on raw balances, so within a class the display multiplier changes nothing. Frozen tokens
///      still accrue. Addresses listed as excluded for a distribution (treasury holdings and escrow contracts, for
///      example) can neither claim nor count in the eligible supply. Setting a claim deadline is optional, but if set
///      it must fall at least 12 months past the funding time. From that deadline on, the company may move whatever
///      is unclaimed to its treasury. With no deadline, sweeping is impossible and rounding leftovers remain here.
contract PayoutVault is AccessControl, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_CLAIM_WINDOW = 365 days;
    uint256 public constant MAX_EXCLUDED = 20;

    struct Distribution {
        address shareToken;
        address asset;
        uint256 amount;
        uint48 recordBlock;
        uint64 claimDeadline; // 0 means the distribution never expires
        uint256 eligibleSupply;
        uint256 claimed;
        bool swept;
    }

    event DistributionFunded(uint256 indexed distributionId, address asset, uint256 amount, uint256 recordBlock);
    event DistributionClaimed(uint256 indexed distributionId, address indexed holder, uint256 amount);
    event DistributionSwept(uint256 indexed distributionId, uint256 amount);
    event TreasuryUpdated(address treasury);

    error NotCompanyToken();
    error InvalidParams();
    error NothingToClaim();
    error DeadlinePassed();
    error NotSweepable();
    error UnknownDistribution();

    bytes32 public companyId;
    IPincerDeployer public factory;
    address public treasury;

    Distribution[] private _distributions;
    mapping(uint256 => mapping(address => bool)) public excluded;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    constructor() {
        _disableInitializers();
    }

    function initialize(bytes32 companyId_, address factory_, address admin, address issuerAdmin, address treasury_)
        external
        initializer
    {
        companyId = companyId_;
        factory = IPincerDeployer(factory_);
        treasury = treasury_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(AccessRoles.ISSUER_ADMIN, issuerAdmin);
    }

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert InvalidParams();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function fund(
        address shareToken,
        address asset,
        uint256 amount,
        uint48 recordBlock,
        uint64 claimDeadline,
        address[] calldata excludedAccounts
    ) external onlyRole(AccessRoles.ISSUER_ADMIN) nonReentrant returns (uint256 distributionId) {
        if (factory.shareClassOf(shareToken).companyId != companyId) revert NotCompanyToken();
        if (amount == 0 || asset == address(0) || excludedAccounts.length > MAX_EXCLUDED) revert InvalidParams();
        if (claimDeadline != 0 && claimDeadline < block.timestamp + MIN_CLAIM_WINDOW) revert InvalidParams();

        IPincerEquityToken token = IPincerEquityToken(shareToken);
        if (recordBlock >= token.clock()) revert InvalidParams();
        uint256 eligible = token.totalSupplyAt(recordBlock);

        distributionId = _distributions.length;
        for (uint256 i; i < excludedAccounts.length; ++i) {
            address a = excludedAccounts[i];
            if (excluded[distributionId][a]) continue;
            excluded[distributionId][a] = true;
            eligible -= token.balanceOfAt(a, recordBlock);
        }
        if (eligible == 0) revert InvalidParams();

        _distributions.push(
            Distribution({
                shareToken: shareToken,
                asset: asset,
                amount: amount,
                recordBlock: recordBlock,
                claimDeadline: claimDeadline,
                eligibleSupply: eligible,
                claimed: 0,
                swept: false
            })
        );
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        emit DistributionFunded(distributionId, asset, amount, recordBlock);
    }

    /// @notice What `holder` could claim right now, rounded toward zero. The result is 0 once the deadline is reached,
    ///         for an excluded or already-paid holder, and for a distribution that has been swept.
    function claimable(uint256 distributionId, address holder) public view returns (uint256) {
        Distribution storage d = _get(distributionId);
        if (excluded[distributionId][holder] || hasClaimed[distributionId][holder] || d.swept) return 0;
        if (d.claimDeadline != 0 && block.timestamp >= d.claimDeadline) return 0;
        uint256 balance = IPincerEquityToken(d.shareToken).balanceOfAt(holder, d.recordBlock);
        return (balance * d.amount) / d.eligibleSupply;
    }

    function claim(uint256 distributionId) external {
        _claim(distributionId, msg.sender);
    }

    /// @notice Claims several distributions in one transaction, as `claim` would for each. If any single entry has
    ///         expired or has nothing for the caller, the entire call reverts.
    function claimMany(uint256[] calldata distributionIds) external {
        for (uint256 i; i < distributionIds.length; ++i) {
            _claim(distributionIds[i], msg.sender);
        }
    }

    /// @notice Lets a relayer claim on someone's behalf. Anyone may call it, but the funds are always sent to `holder`.
    function claimFor(uint256 distributionId, address holder) external {
        _claim(distributionId, holder);
    }

    function sweep(uint256 distributionId) external onlyRole(AccessRoles.ISSUER_ADMIN) nonReentrant {
        Distribution storage d = _get(distributionId);
        if (d.claimDeadline == 0 || block.timestamp < d.claimDeadline || d.swept) revert NotSweepable();
        d.swept = true;
        uint256 remaining = d.amount - d.claimed;
        if (remaining != 0) IERC20(d.asset).safeTransfer(treasury, remaining);
        emit DistributionSwept(distributionId, remaining);
    }

    function distribution(uint256 distributionId) external view returns (Distribution memory) {
        return _get(distributionId);
    }

    function distributionCount() external view returns (uint256) {
        return _distributions.length;
    }

    function _claim(uint256 distributionId, address holder) private nonReentrant {
        Distribution storage d = _get(distributionId);
        if (d.claimDeadline != 0 && block.timestamp >= d.claimDeadline) revert DeadlinePassed();
        uint256 amount = claimable(distributionId, holder);
        if (amount == 0) revert NothingToClaim();
        hasClaimed[distributionId][holder] = true;
        d.claimed += amount;
        IERC20(d.asset).safeTransfer(holder, amount);
        emit DistributionClaimed(distributionId, holder, amount);
    }

    function _get(uint256 distributionId) private view returns (Distribution storage) {
        if (distributionId >= _distributions.length) revert UnknownDistribution();
        return _distributions[distributionId];
    }
}

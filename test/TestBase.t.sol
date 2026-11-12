// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PincerDeployer} from "../src/platform/PincerDeployer.sol";
import {IPincerDeployer} from "../src/interfaces/IPincerDeployer.sol";
import {PincerEquityToken} from "../src/platform/PincerEquityToken.sol";
import {HolderRegistry} from "../src/registry/HolderRegistry.sol";
import {VerifierList} from "../src/registry/VerifierList.sol";
import {TransferPolicy} from "../src/policy/TransferPolicy.sol";
import {RaiseEscrow} from "../src/trading/RaiseEscrow.sol";
import {WindowMarket} from "../src/trading/WindowMarket.sol";
import {QuoteSettlement} from "../src/trading/QuoteSettlement.sol";
import {PayoutVault} from "../src/corporate/PayoutVault.sol";
import {ShareholderBallot} from "../src/corporate/ShareholderBallot.sol";
import {DocumentAnchor} from "../src/corporate/DocumentAnchor.sol";
import {CompanyTimelock} from "../src/platform/CompanyTimelock.sol";
import {ValuationFeed} from "../src/corporate/ValuationFeed.sol";
import {PoolGuard} from "../src/trading/PoolGuard.sol";
import {JurisdictionRule} from "../src/policy/rules/JurisdictionRule.sol";
import {InvestorTierRule} from "../src/policy/rules/InvestorTierRule.sol";
import {LockupRule} from "../src/policy/rules/LockupRule.sol";
import {HolderLimitRule} from "../src/policy/rules/HolderLimitRule.sol";
import {TradingWindowRule} from "../src/policy/rules/TradingWindowRule.sol";
import {FirstRefusalRule} from "../src/policy/rules/FirstRefusalRule.sol";
import {OwnershipCeilingRule} from "../src/policy/rules/OwnershipCeilingRule.sol";
import {VestingScheduleRule} from "../src/policy/rules/VestingScheduleRule.sol";
import {TestDollar} from "../src/mocks/TestDollar.sol";
import {ClaimTopics} from "../src/common/ClaimTopics.sol";

/// @dev Shared fixture for every suite. A PincerDeployer is created with all implementations registered, then a
///      single company named "LARKWAY" is deployed with a CompanyTimelock requiring 2 of 3 signers. Helper
///      functions verify holders, deploy share classes and push calls through the timelock.
abstract contract TestBase is Test {
    bytes32 internal constant COMPANY = "LARKWAY";
    bytes2 internal constant US = "US";
    bytes2 internal constant GB = "GB";
    bytes2 internal constant SG = "SG";
    bytes2 internal constant KP = "KP";

    PincerDeployer internal factory;
    TestDollar internal usdg;
    IPincerDeployer.CompanyContracts internal c;
    HolderRegistry internal registry;
    CompanyTimelock internal timelock;
    RaiseEscrow internal offerings;
    WindowMarket internal windows;
    QuoteSettlement internal rfq;
    PayoutVault internal distributions;
    ShareholderBallot internal governance;
    DocumentAnchor internal disclosures;

    address internal pincer = makeAddr("pincer");
    address internal issuerAdmin = makeAddr("issuerAdmin");
    address internal registrar = makeAddr("registrar");
    address internal operator = makeAddr("operator");
    address internal treasury = makeAddr("treasury");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal signer1 = makeAddr("signer1");
    address internal signer2 = makeAddr("signer2");
    address internal signer3 = makeAddr("signer3");

    address internal verifier;
    uint256 internal verifierKey;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    uint64 internal constant ONE_YEAR = 365 days;
    uint64 internal constant CLAIM_TTL = 5 * 365 days;
    uint256 internal constant T0 = 1_760_000_000;

    function setUp() public virtual {
        vm.warp(T0);
        vm.roll(1_000);
        (verifier, verifierKey) = makeAddrAndKey("verifier");
        usdg = new TestDollar();

        PincerDeployer.Implementations memory impls = PincerDeployer.Implementations({
            shareToken: address(new PincerEquityToken()),
            identityRegistry: address(new HolderRegistry()),
            trustedVerifiers: address(new VerifierList()),
            ruleEngine: address(new TransferPolicy()),
            offeringVault: address(new RaiseEscrow()),
            liquidityWindow: address(new WindowMarket()),
            rfqSettlement: address(new QuoteSettlement()),
            distributionVault: address(new PayoutVault()),
            governance: address(new ShareholderBallot()),
            disclosureRegistry: address(new DocumentAnchor()),
            issuerTimelock: address(new CompanyTimelock()),
            valuationOracle: address(new ValuationFeed()),
            poolGate: address(new PoolGuard())
        });
        factory = new PincerDeployer(
            pincer,
            impls,
            PincerDeployer.Fees({recipient: feeRecipient, offeringBps: 100, sellerBps: 25, buyerBps: 25})
        );

        vm.startPrank(pincer);
        factory.setModuleImplementation("REGION", address(new JurisdictionRule()));
        factory.setModuleImplementation("ELIGIBILITY", address(new InvestorTierRule()));
        factory.setModuleImplementation("HOLDING_PERIOD", address(new LockupRule()));
        factory.setModuleImplementation("HOLDER_CAP", address(new HolderLimitRule()));
        factory.setModuleImplementation("TRANSFER_WINDOW", address(new TradingWindowRule()));
        factory.setModuleImplementation("ROFR", address(new FirstRefusalRule()));
        factory.setModuleImplementation("MAX_OWNERSHIP", address(new OwnershipCeilingRule()));
        factory.setModuleImplementation("EMPLOYEE_VESTING", address(new VestingScheduleRule()));

        address[] memory verifiers = new address[](1);
        verifiers[0] = verifier;
        bytes32[][] memory topics = new bytes32[][](1);
        topics[0] = _allTopics();
        factory.setDefaultVerifiers(verifiers, topics);

        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;
        c = factory.deployCompany(
            PincerDeployer.CompanyParams({
                companyId: COMPANY,
                issuerAdmin: issuerAdmin,
                registrar: registrar,
                operator: operator,
                treasury: treasury,
                timelockSigners: signers,
                timelockThreshold: 2,
                verifiers: new address[](0),
                verifierTopics: new bytes32[][](0)
            })
        );
        vm.stopPrank();

        registry = HolderRegistry(c.identityRegistry);
        timelock = CompanyTimelock(payable(c.issuerTimelock));
        offerings = RaiseEscrow(c.offeringVault);
        windows = WindowMarket(c.liquidityWindow);
        rfq = QuoteSettlement(c.rfqSettlement);
        distributions = PayoutVault(c.distributionVault);
        governance = ShareholderBallot(c.governance);
        disclosures = DocumentAnchor(c.disclosureRegistry);
    }

    // ===============================================================================================================
    // Share class deployment and rule list builders
    // ===============================================================================================================

    function _deployClass(bytes32 shareClass, PincerDeployer.ModuleInit[] memory modules)
        internal
        returns (PincerEquityToken token)
    {
        vm.prank(pincer);
        token = PincerEquityToken(
            factory.deployShareClass(
                PincerDeployer.ShareClassParams({
                    companyId: COMPANY,
                    shareClass: shareClass,
                    name: string(abi.encodePacked("Larkway ", shareClass)),
                    symbol: "NWD",
                    documentsRoot: keccak256("terms"),
                    modules: modules,
                    enablePools: false
                })
            )
        );
    }

    function _plainClass(bytes32 shareClass) internal returns (PincerEquityToken) {
        return _deployClass(shareClass, new PincerDeployer.ModuleInit[](0));
    }

    function _modules1(bytes32 id, bytes memory config) internal pure returns (PincerDeployer.ModuleInit[] memory m) {
        m = new PincerDeployer.ModuleInit[](1);
        m[0] = PincerDeployer.ModuleInit({moduleId: id, config: config});
    }

    // ===============================================================================================================
    // Holder verification, claim issuance and minting
    // ===============================================================================================================

    function _verify(address wallet) internal {
        _verify(wallet, US, 1);
    }

    function _verify(address wallet, bytes2 region, uint8 tier) internal {
        vm.prank(operator);
        registry.registerIdentity(wallet, wallet);
        uint64 expiry = uint64(block.timestamp) + CLAIM_TTL;
        vm.startPrank(verifier);
        registry.addClaim(wallet, ClaimTopics.IDENTITY_VERIFIED, "", expiry, verifier, "");
        registry.addClaim(wallet, ClaimTopics.SCREENED, abi.encode(uint64(block.timestamp)), expiry, verifier, "");
        registry.addClaim(wallet, ClaimTopics.REGION, abi.encode(region), expiry, verifier, "");
        registry.addClaim(wallet, ClaimTopics.INVESTOR_ELIGIBLE, abi.encode(tier), expiry, verifier, "");
        vm.stopPrank();
    }

    function _addClaim(address identity, bytes32 topic, bytes memory data) internal {
        vm.prank(verifier);
        registry.addClaim(identity, topic, data, uint64(block.timestamp) + CLAIM_TTL, verifier, "");
    }

    function _mint(PincerEquityToken token, address to, uint256 shares) internal {
        vm.prank(registrar);
        token.mint(to, shares, "cap-table");
    }

    function _allTopics() internal pure returns (bytes32[] memory t) {
        t = new bytes32[](6);
        t[0] = ClaimTopics.IDENTITY_VERIFIED;
        t[1] = ClaimTopics.INVESTOR_ELIGIBLE;
        t[2] = ClaimTopics.REGION;
        t[3] = ClaimTopics.EMPLOYEE_OF;
        t[4] = ClaimTopics.SCREENED;
        t[5] = ClaimTopics.VENUE;
    }

    // ===============================================================================================================
    // Calls through the timelock, USDG funding and unit conversion
    // ===============================================================================================================

    function _timelocked(address target, bytes memory data) internal returns (bytes memory) {
        bytes32 salt = keccak256(abi.encode(target, data, block.timestamp, gasleft()));
        vm.prank(signer1);
        bytes32 id = timelock.propose(target, 0, data, salt);
        vm.prank(signer2);
        timelock.approve(id);
        vm.warp(timelock.action(id).eta);
        return timelock.execute(id);
    }

    function _fund(address who, uint256 amount, address spender) internal {
        usdg.mint(who, amount);
        vm.prank(who);
        usdg.approve(spender, type(uint256).max);
    }

    function _usdg(uint256 whole) internal pure returns (uint256) {
        return whole * 1e6;
    }

    function _shares(uint256 whole) internal pure returns (uint256) {
        return whole * 1e18;
    }
}

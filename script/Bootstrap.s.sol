// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

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

/// @title Bootstrap: deploys the Pincer protocol to a chain
/// @notice Works on any EVM chain; the normal target is the Robinhood Chain testnet (chain id 46630). When it finishes,
///         `deployments/<chainId>.json` holds the factory and stablecoin addresses, plus the core contracts and share
///         classes of the demo company if one was created.
///
///         Example:
///           forge script script/Bootstrap.s.sol:Bootstrap --rpc-url robinhood_testnet --broadcast --verify
///
///         Environment variables (see .env.example):
///         - PRIVATE_KEY        key of the deployer, who also owns the factory and, unless overridden, receives fees
///                              and acts as the default verifier
///         - USDG               stablecoin address. Mandatory on mainnet; on other chains, leaving it empty deploys
///                              a 6-decimal test stablecoin instead
///         - FEE_RECIPIENT      optional; falls back to the deployer
///         - DEFAULT_VERIFIER   optional; falls back to the deployer. This identity provider key is trusted for all
///                              claim topics
///         - DEPLOY_DEMO        optional; defaults to false on mainnet and true everywhere else. Creates a demo
///                              company with two share classes. If the deployer is the verifier as well, the
///                              deployer is also verified and the demo gets a cap table and an open offering
contract Bootstrap is Script {
    uint256 internal constant MAINNET = 4663;
    bytes32 internal constant DEMO_COMPANY = "LARKWAY_LABS";

    struct Deployed {
        PincerDeployer factory;
        address stablecoin;
        IPincerDeployer.CompanyContracts company;
        address common;
        address seriesB;
        uint256 offeringId;
    }

    function run() external returns (Deployed memory d) {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(key);
        bool isMainnet = block.chainid == MAINNET;
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);
        address verifier = vm.envOr("DEFAULT_VERIFIER", deployer);
        bool demo = vm.envOr("DEPLOY_DEMO", !isMainnet);

        vm.startBroadcast(key);

        d.stablecoin = vm.envOr("USDG", address(0));
        if (d.stablecoin == address(0)) {
            require(!isMainnet, "USDG must be set on mainnet");
            d.stablecoin = address(new TestDollar());
        }

        d.factory = new PincerDeployer(
            deployer,
            _implementations(),
            PincerDeployer.Fees({recipient: feeRecipient, offeringBps: 100, sellerBps: 25, buyerBps: 25})
        );
        _registerModules(d.factory);

        address[] memory verifiers = new address[](1);
        verifiers[0] = verifier;
        bytes32[][] memory topics = new bytes32[][](1);
        topics[0] = _allTopics();
        d.factory.setDefaultVerifiers(verifiers, topics);

        if (demo) _demo(d, deployer, verifier == deployer);

        vm.stopBroadcast();
        _write(d);
    }

    /* ---------- internal helpers ---------- */

    function _implementations() internal returns (PincerDeployer.Implementations memory) {
        return PincerDeployer.Implementations({
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
    }

    function _registerModules(PincerDeployer f) internal {
        f.setModuleImplementation("REGION", address(new JurisdictionRule()));
        f.setModuleImplementation("ELIGIBILITY", address(new InvestorTierRule()));
        f.setModuleImplementation("HOLDING_PERIOD", address(new LockupRule()));
        f.setModuleImplementation("HOLDER_CAP", address(new HolderLimitRule()));
        f.setModuleImplementation("TRANSFER_WINDOW", address(new TradingWindowRule()));
        f.setModuleImplementation("ROFR", address(new FirstRefusalRule()));
        f.setModuleImplementation("MAX_OWNERSHIP", address(new OwnershipCeilingRule()));
        f.setModuleImplementation("EMPLOYEE_VESTING", address(new VestingScheduleRule()));
    }

    /// @dev Sets up a demo company that a single key can fully exercise. The deployer therefore fills every role:
    ///      issuer admin, registrar, operator, treasury and sole timelock signer. A real company would spread these
    ///      across distinct keys and use a multi-signer timelock.
    function _demo(Deployed memory d, address deployer, bool deployerIsVerifier) internal {
        address[] memory signers = new address[](1);
        signers[0] = deployer;
        d.company = d.factory
            .deployCompany(
                PincerDeployer.CompanyParams({
                    companyId: DEMO_COMPANY,
                    issuerAdmin: deployer,
                    registrar: deployer,
                    operator: deployer,
                    treasury: deployer,
                    timelockSigners: signers,
                    timelockThreshold: 1,
                    verifiers: new address[](0),
                    verifierTopics: new bytes32[][](0)
                })
            );

        // Common class rules: eligible investors and company employees may hold, sanctioned regions are shut out,
        // and the holder count is capped. Offering purchases are locked up for 90 days.
        bytes2[] memory blocked = new bytes2[](4);
        blocked[0] = "KP";
        blocked[1] = "IR";
        blocked[2] = "CU";
        blocked[3] = "SY";
        bytes32[] memory sources = new bytes32[](1);
        sources[0] = "OFFERING";
        uint32[] memory periods = new uint32[](1);
        periods[0] = 90 days;
        address[] memory ops = new address[](2);
        ops[0] = d.company.offeringVault;
        ops[1] = d.company.liquidityWindow;
        bytes32[] memory opSources = new bytes32[](2);
        opSources[0] = "OFFERING";
        opSources[1] = "WINDOW";

        PincerDeployer.ModuleInit[] memory commonRules = new PincerDeployer.ModuleInit[](4);
        commonRules[0] = PincerDeployer.ModuleInit("REGION", abi.encode(uint8(1), blocked));
        commonRules[1] = PincerDeployer.ModuleInit("ELIGIBILITY", abi.encode(uint8(1), true));
        commonRules[2] = PincerDeployer.ModuleInit("HOLDER_CAP", abi.encode(uint32(2_000)));
        commonRules[3] =
            PincerDeployer.ModuleInit("HOLDING_PERIOD", abi.encode(uint32(0), sources, periods, ops, opSources));
        d.common = d.factory
            .deployShareClass(
                PincerDeployer.ShareClassParams({
                    companyId: DEMO_COMPANY,
                    shareClass: "COMMON",
                    name: "Larkway Labs Common",
                    symbol: "LKW-C",
                    documentsRoot: keccak256("larkway-common-terms-v1"),
                    modules: commonRules,
                    enablePools: false
                })
            );

        // Series B Preferred: stricter eligibility tier than Common, and no transfer may push a holder above 25%.
        PincerDeployer.ModuleInit[] memory prefRules = new PincerDeployer.ModuleInit[](3);
        prefRules[0] = PincerDeployer.ModuleInit("REGION", abi.encode(uint8(1), blocked));
        prefRules[1] = PincerDeployer.ModuleInit("ELIGIBILITY", abi.encode(uint8(2), false));
        prefRules[2] = PincerDeployer.ModuleInit("MAX_OWNERSHIP", abi.encode(uint16(2_500), false, new address[](0)));
        d.seriesB = d.factory
            .deployShareClass(
                PincerDeployer.ShareClassParams({
                    companyId: DEMO_COMPANY,
                    shareClass: "SERIES_B",
                    name: "Larkway Labs Series B Preferred",
                    symbol: "LKW-B",
                    documentsRoot: keccak256("larkway-series-b-terms-v1"),
                    modules: prefRules,
                    enablePools: false
                })
            );

        if (!deployerIsVerifier) return; // the claims that follow must come from the configured verifier

        // Remaining steps: verify the deployer, import a small cap table to it, and open a Series B offering.
        HolderRegistry registry = HolderRegistry(d.company.identityRegistry);
        registry.registerIdentity(deployer, deployer);
        uint64 expiry = uint64(block.timestamp + 365 days);
        registry.addClaim(deployer, ClaimTopics.IDENTITY_VERIFIED, "", expiry, deployer, "");
        registry.addClaim(deployer, ClaimTopics.SCREENED, abi.encode(uint64(block.timestamp)), expiry, deployer, "");
        registry.addClaim(deployer, ClaimTopics.REGION, abi.encode(bytes2("US")), expiry, deployer, "");
        registry.addClaim(deployer, ClaimTopics.INVESTOR_ELIGIBLE, abi.encode(uint8(2)), expiry, deployer, "");

        PincerEquityToken(d.common).mint(deployer, 1_000_000e18, "cap-table-import");
        PincerEquityToken(d.seriesB).mint(deployer, 250_000e18, "cap-table-import");

        DocumentAnchor(d.company.disclosureRegistry)
            .anchor("OFFERING_DOCUMENT", sha256("Larkway Labs Series B extension"), "https://usepincer.org/demo");
        ValuationFeed(d.factory.shareClassOf(d.seriesB).valuationOracle)
            .publish(24e8, 1, uint64(block.timestamp), bytes32(0));

        bytes32[] memory claims = new bytes32[](1);
        claims[0] = ClaimTopics.INVESTOR_ELIGIBLE;
        d.offeringId = RaiseEscrow(d.company.offeringVault)
            .createOffering(
                RaiseEscrow.OfferingParams({
                shareToken: d.seriesB,
                pricePerShare: 25e6,
                minRaise: 50_000e6,
                maxRaise: 2_000_000e6,
                minTicket: 1_000e6,
                opensAt: uint64(block.timestamp),
                closesAt: uint64(block.timestamp + 30 days),
                stablecoin: d.stablecoin,
                requiredClaims: claims,
                treasury: deployer,
                documentId: 1
            })
            );
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

    function _write(Deployed memory d) internal {
        string memory root = "deployment";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "factory", address(d.factory));
        string memory json = vm.serializeAddress(root, "stablecoin", d.stablecoin);

        if (d.company.issuerTimelock != address(0)) {
            string memory demo = "demo";
            vm.serializeString(demo, "companyId", "LARKWAY_LABS");
            vm.serializeAddress(demo, "identityRegistry", d.company.identityRegistry);
            vm.serializeAddress(demo, "trustedVerifiers", d.company.trustedVerifiers);
            vm.serializeAddress(demo, "offeringVault", d.company.offeringVault);
            vm.serializeAddress(demo, "liquidityWindow", d.company.liquidityWindow);
            vm.serializeAddress(demo, "rfqSettlement", d.company.rfqSettlement);
            vm.serializeAddress(demo, "distributionVault", d.company.distributionVault);
            vm.serializeAddress(demo, "governance", d.company.governance);
            vm.serializeAddress(demo, "disclosureRegistry", d.company.disclosureRegistry);
            vm.serializeAddress(demo, "issuerTimelock", d.company.issuerTimelock);
            vm.serializeAddress(demo, "common", d.common);
            string memory demoJson = vm.serializeAddress(demo, "seriesB", d.seriesB);
            json = vm.serializeString(root, "demo", demoJson);
        }

        string memory path = string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("Factory:", address(d.factory));
        console2.log("Written to", path);
    }
}

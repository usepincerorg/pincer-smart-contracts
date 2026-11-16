// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PincerDeployer} from "../src/platform/PincerDeployer.sol";
import {PincerEquityToken} from "../src/platform/PincerEquityToken.sol";
import {HolderRegistry} from "../src/registry/HolderRegistry.sol";
import {RaiseEscrow} from "../src/trading/RaiseEscrow.sol";
import {WindowMarket} from "../src/trading/WindowMarket.sol";
import {QuoteSettlement} from "../src/trading/QuoteSettlement.sol";
import {PayoutVault} from "../src/corporate/PayoutVault.sol";
import {ShareholderBallot} from "../src/corporate/ShareholderBallot.sol";
import {DocumentAnchor} from "../src/corporate/DocumentAnchor.sol";
import {ValuationFeed} from "../src/corporate/ValuationFeed.sol";
import {TestDollar} from "../src/mocks/TestDollar.sol";
import {ClaimTopics} from "../src/common/ClaimTopics.sol";

/// @title DemoData: populates the Larkway Labs demo company with realistic activity
/// @notice Run after Bootstrap to give the Larkway Labs demo company a plausible on-chain past: six verified
///         investors, secondary transfers, subscriptions in two offerings, a WindowMarket auction, RFQ fills via
///         QuoteSettlement, one dividend and two shareholder ballots. Since windows, offerings and ballots can only be
///         settled after their on-chain close time, the script is split into three runs:
///
///   forge script script/DemoData.s.sol:DemoData --rpc-url robinhood_testnet --broadcast --slow --sig "open()"
///   # wait SETTLE_DELAY (10 minutes), then
///   forge script script/DemoData.s.sol:DemoData --rpc-url robinhood_testnet --broadcast --slow --sig "settle()"
///   # wait VOTE_PERIOD (10 minutes), then
///   forge script script/DemoData.s.sol:DemoData --rpc-url robinhood_testnet --broadcast --slow --sig "finalize()"
///
/// @dev The investor keys are derived from PRIVATE_KEY, so each run (and whoever holds the deployer key) can sign as
///      any investor. The deployer pays their gas and mints their test USDG. The investor addresses are saved to
///      `deployments/<chainId>.seed.json`. Do not use on mainnet, since it depends on the test stablecoin.
contract DemoData is Script {
    uint256 internal constant INVESTORS = 6;
    uint256 internal constant GAS_PER_INVESTOR = 0.0002 ether;
    uint64 internal constant SETTLE_DELAY = 10 minutes;
    uint64 internal constant VOTE_PERIOD = 10 minutes;
    bytes32 internal constant COMPANY = "LARKWAY_LABS";

    // Investor array indexes: 0 Ava, 1 Ben, 2 Chen, 3 Dana, 4 Eli (employee), 5 Fay.
    uint256 internal constant AVA = 0;
    uint256 internal constant BEN = 1;
    uint256 internal constant CHEN = 2;
    uint256 internal constant DANA = 3;
    uint256 internal constant ELI = 4;
    uint256 internal constant FAY = 5;

    uint256 internal deployerKey;
    address internal deployer;
    uint256[INVESTORS] internal keys;
    address[INVESTORS] internal investors;

    TestDollar internal usdg;
    PincerEquityToken internal common;
    PincerEquityToken internal seriesB;
    HolderRegistry internal registry;
    RaiseEscrow internal offerings;
    WindowMarket internal windows;
    QuoteSettlement internal rfq;
    PayoutVault internal distributions;
    ShareholderBallot internal governance;
    DocumentAnchor internal disclosures;
    PincerDeployer internal factory;

    /* ==========  Run 1: onboarding, transfers, subscriptions, window orders, RFQ fills  ========== */

    function open() external {
        _load();
        require(block.chainid != 4663, "DemoData is testnet only");

        vm.startBroadcast(deployerKey);
        usdg.mint(deployer, 5_000_000e6);
        _onboard(AVA, "US", 2);
        _onboard(BEN, "GB", 2);
        _onboard(CHEN, "SG", 1);
        _onboard(DANA, "DE", 2);
        _onboardEmployee(ELI, "US");
        _onboard(FAY, "CA", 1);

        // Secondary transfers out of the founder's imported cap table. No Series B recipient reaches the 25%
        // ownership ceiling.
        common.transfer(investors[AVA], 120_000e18);
        common.transfer(investors[BEN], 80_000e18);
        common.transfer(investors[CHEN], 50_000e18);
        common.transfer(investors[DANA], 60_000e18);
        common.transfer(investors[ELI], 40_000e18);
        common.transfer(investors[FAY], 30_000e18);
        seriesB.transfer(investors[AVA], 40_000e18);
        seriesB.transfer(investors[BEN], 30_000e18);
        seriesB.transfer(investors[DANA], 25_000e18);

        // Record the disclosure document hashes, then post a 409A Reference Valuation of 8.50 USD for Common.
        disclosures.anchor(
            "FINANCIAL_STATEMENT", sha256("Larkway Labs FY2025 audited financials"), "https://usepincer.org/demo/fy2025"
        );
        disclosures.anchor(
            "BOARD_RESOLUTION",
            sha256("Larkway Labs board: approve Q4 liquidity window"),
            "https://usepincer.org/demo/board-q4"
        );
        disclosures.anchor(
            "VALUATION_REPORT", sha256("Larkway Labs 409A, October 2026"), "https://usepincer.org/demo/409a"
        );
        uint256 commonOfferingDoc = disclosures.anchor(
            "OFFERING_DOCUMENT",
            sha256("Larkway Labs Common employee and friends round"),
            "https://usepincer.org/demo/common-round"
        );
        ValuationFeed(factory.shareClassOf(address(common)).valuationOracle)
            .publish(8_50_000_000, 1, uint64(block.timestamp), sha256("Larkway Labs 409A, October 2026"));

        // A Common offering at 8 USDG a share, open just for SETTLE_DELAY.
        bytes32[] memory verified = new bytes32[](1);
        verified[0] = ClaimTopics.IDENTITY_VERIFIED;
        uint256 commonRound = offerings.createOffering(
            RaiseEscrow.OfferingParams({
                shareToken: address(common),
                pricePerShare: 8e6,
                minRaise: 20_000e6,
                maxRaise: 200_000e6,
                minTicket: 500e6,
                opensAt: uint64(block.timestamp),
                closesAt: uint64(block.timestamp) + SETTLE_DELAY,
                stablecoin: address(usdg),
                requiredClaims: verified,
                treasury: deployer,
                documentId: commonOfferingDoc
            })
        );

        // Uniform-price auction window for Common, which likewise closes after SETTLE_DELAY.
        uint256 windowId = windows.openWindow(
            WindowMarket.WindowParams({
                shareToken: address(common),
                mode: windows.AUCTION(),
                opensAt: uint64(block.timestamp),
                closesAt: uint64(block.timestamp) + SETTLE_DELAY,
                stablecoin: address(usdg),
                reservePrice: 7e6,
                tenderPrice: 0,
                maxVolume: 0,
                perSellerCap: 50_000e18,
                rofrHolder: address(0),
                rofrPeriod: 0,
                sellerClaims: verified,
                buyerClaims: verified
            })
        );

        rfq.setEnabled(address(common), true);
        rfq.setEnabled(address(seriesB), true);
        usdg.approve(address(windows), type(uint256).max);
        vm.stopBroadcast();

        // One-time token approvals from every investor.
        for (uint256 i; i < INVESTORS; ++i) {
            vm.startBroadcast(keys[i]);
            usdg.approve(address(offerings), type(uint256).max);
            usdg.approve(address(windows), type(uint256).max);
            usdg.approve(address(rfq), type(uint256).max);
            common.approve(address(windows), type(uint256).max);
            common.approve(address(rfq), type(uint256).max);
            seriesB.approve(address(rfq), type(uint256).max);
            vm.stopBroadcast();
        }

        // Series B subscriptions into offering 0, opened by Bootstrap at 25 USDG a share and limited to tier 2.
        _subscribe(AVA, 0, 25_000e6);
        _subscribe(BEN, 0, 40_000e6);
        _subscribe(DANA, 0, 30_000e6);

        // Common offering subscriptions.
        _subscribe(CHEN, commonRound, 12_000e6);
        _subscribe(FAY, commonRound, 6_000e6);
        _subscribe(ELI, commonRound, 3_000e6);
        _subscribe(BEN, commonRound, 9_000e6);

        // Sell orders go in first (8.00, 8.40, 9.25): the window only accepts a bid it could fill out of the shares
        // it already escrows, and those come from the asks. After that, the company bids 8.00 for a small buyback,
        // and investors bid 9.00, 8.60 and 8.20.
        _order(AVA, windowId, windows.SELL(), 20_000e18, 8e6);
        _order(ELI, windowId, windows.SELL(), 10_000e18, 8_40e4);
        _order(BEN, windowId, windows.SELL(), 15_000e18, 9_25e4);
        uint8 buy = windows.BUY();
        vm.broadcast(deployerKey);
        windows.placeOrder(windowId, buy, 5_000e18, 8e6);
        _order(CHEN, windowId, windows.BUY(), 12_000e18, 9e6);
        _order(FAY, windowId, windows.BUY(), 8_000e18, 8_60e4);
        _order(DANA, windowId, windows.BUY(), 10_000e18, 8_20e4);

        // RFQ activity. Ava quotes 5,000 Common at 8.75 and Dana fills 3,000 of it; Dana bids 26 for 2,000 Series B
        // and Ben fills all of it. Last, Fay cancels nonce 1 even though she never signed a quote using it.
        QuoteSettlement.Quote memory q = _quote(AVA, address(common), rfq.MAKER_SELLS(), 5_000e18, 8_75e4, 1);
        _fill(DANA, q, _signQuote(AVA, q), 3_000e18);
        q = _quote(DANA, address(seriesB), rfq.MAKER_BUYS(), 2_000e18, 26e6, 1);
        _fill(BEN, q, _signQuote(DANA, q), 2_000e18);
        vm.broadcast(keys[FAY]);
        rfq.cancelQuote(1);

        // Eli delegates to Ava now, ahead of the proposals created in run 2.
        vm.broadcast(keys[ELI]);
        governance.delegate(investors[AVA]);

        _writeInvestors();
        console2.log("Common round:", commonRound);
        console2.log("Window:", windowId);
        console2.log("Run settle() after", block.timestamp + SETTLE_DELAY);
    }

    /* ==========  Run 2: settlement, dividend, two ballots  ========== */

    function settle() external {
        _load();
        uint256 windowId = windows.windowCount() - 1;
        uint256 commonRound = offerings.offeringCount() - 1;

        vm.startBroadcast(deployerKey);
        windows.clear(windowId);
        offerings.close(commonRound);
        vm.stopBroadcast();

        // An RFQ trade where Chen bids for 1,500 Common and Ava fills it.
        QuoteSettlement.Quote memory q = _quote(CHEN, address(common), rfq.MAKER_BUYS(), 1_500e18, 8_90e4, 2);
        _fill(AVA, q, _signQuote(CHEN, q), 1_500e18);

        // 100,000 USDG dividend to Common, with the prior block as the record block. All holders except Dana claim;
        // Eli's claim is relayed by the deployer.
        uint48 recordBlock = common.clock() - 1;
        vm.startBroadcast(deployerKey);
        usdg.approve(address(distributions), type(uint256).max);
        uint256 dividend =
            distributions.fund(address(common), address(usdg), 100_000e6, recordBlock, 0, new address[](0));
        distributions.claimFor(dividend, investors[ELI]);
        distributions.claim(dividend);
        disclosures.anchor(
            "COMPANY_UPDATE", sha256("Larkway Labs Q3 2026 shareholder letter"), "https://usepincer.org/demo/q3-letter"
        );
        vm.stopBroadcast();
        _claim(AVA, dividend);
        _claim(BEN, dividend);
        _claim(CHEN, dividend);
        _claim(FAY, dividend);

        // Both proposals cover Common and Series B. The short ballot lasts VOTE_PERIOD and is finalized in run 3;
        // the long ballot stays open for 14 days.
        address[] memory classes = new address[](2);
        classes[0] = address(common);
        classes[1] = address(seriesB);
        vm.startBroadcast(deployerKey);
        uint256 shortVote = governance.propose(
            ShareholderBallot.ProposalParams({
                shareTokens: classes,
                snapshotBlock: recordBlock,
                endsAt: uint64(block.timestamp) + VOTE_PERIOD,
                quorumBps: 2_000,
                options: 3,
                binding: false,
                documentHash: sha256("Ratify the 2026 equity incentive plan")
            })
        );
        uint256 longVote = governance.propose(
            ShareholderBallot.ProposalParams({
                shareTokens: classes,
                snapshotBlock: recordBlock,
                endsAt: uint64(block.timestamp) + 14 days,
                quorumBps: 5_000,
                options: 2,
                binding: true,
                documentHash: sha256("Elect the 2027 board of directors")
            })
        );
        governance.castVote(shortVote, 0);
        vm.stopBroadcast();

        // Options: 0 for, 1 against, 2 abstain (the long ballot has no abstain). Ava votes her own weight first and
        // then votes Eli's delegated weight.
        address[] memory delegators = new address[](1);
        delegators[0] = investors[ELI];
        vm.startBroadcast(keys[AVA]);
        governance.castVote(shortVote, 0);
        governance.castVoteFor(shortVote, 0, delegators);
        governance.castVote(longVote, 0);
        vm.stopBroadcast();
        _vote(BEN, shortVote, 1);
        _vote(CHEN, shortVote, 0);
        _vote(DANA, shortVote, 2);
        _vote(BEN, longVote, 0);
        _vote(DANA, longVote, 1);

        console2.log("Dividend:", dividend);
        console2.log("Proposals:", shortVote, longVote);
        console2.log("Run finalize() after", block.timestamp + VOTE_PERIOD);
    }

    /* ==========  Run 3: finalize the short ballot  ========== */

    function finalize() external {
        _load();
        uint256 shortVote = governance.proposalCount() - 2;
        vm.broadcast(deployerKey);
        governance.finalize(shortVote);
    }

    /* ==========  Internal helpers  ========== */

    function _load() internal {
        deployerKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerKey);
        for (uint256 i; i < INVESTORS; ++i) {
            keys[i] = uint256(keccak256(abi.encode(deployerKey, "pincer-seed", i)))
                % 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
            investors[i] = vm.addr(keys[i]);
        }

        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        factory = PincerDeployer(vm.parseJsonAddress(json, ".factory"));
        usdg = TestDollar(vm.parseJsonAddress(json, ".stablecoin"));
        common = PincerEquityToken(vm.parseJsonAddress(json, ".demo.common"));
        seriesB = PincerEquityToken(vm.parseJsonAddress(json, ".demo.seriesB"));
        registry = HolderRegistry(vm.parseJsonAddress(json, ".demo.identityRegistry"));
        offerings = RaiseEscrow(vm.parseJsonAddress(json, ".demo.offeringVault"));
        windows = WindowMarket(vm.parseJsonAddress(json, ".demo.liquidityWindow"));
        rfq = QuoteSettlement(vm.parseJsonAddress(json, ".demo.rfqSettlement"));
        distributions = PayoutVault(vm.parseJsonAddress(json, ".demo.distributionVault"));
        governance = ShareholderBallot(vm.parseJsonAddress(json, ".demo.governance"));
        disclosures = DocumentAnchor(vm.parseJsonAddress(json, ".demo.disclosureRegistry"));
    }

    /// @dev Must be called while the deployer is broadcasting. Gives the investor gas, test USDG and a registered
    ///      identity, along with claims signed off by the deployer.
    function _onboard(uint256 i, bytes2 region, uint8 tier) internal {
        address a = _fund(i);
        uint64 expiry = uint64(block.timestamp + 365 days);
        registry.addClaim(a, ClaimTopics.REGION, abi.encode(region), expiry, deployer, "");
        registry.addClaim(a, ClaimTopics.INVESTOR_ELIGIBLE, abi.encode(tier), expiry, deployer, "");
    }

    function _onboardEmployee(uint256 i, bytes2 region) internal {
        address a = _fund(i);
        uint64 expiry = uint64(block.timestamp + 365 days);
        registry.addClaim(a, ClaimTopics.REGION, abi.encode(region), expiry, deployer, "");
        registry.addClaim(a, ClaimTopics.EMPLOYEE_OF, abi.encode(COMPANY), expiry, deployer, "");
    }

    function _fund(uint256 i) internal returns (address a) {
        a = investors[i];
        payable(a).transfer(GAS_PER_INVESTOR);
        usdg.mint(a, 250_000e6);
        registry.registerIdentity(a, a);
        uint64 expiry = uint64(block.timestamp + 365 days);
        registry.addClaim(a, ClaimTopics.IDENTITY_VERIFIED, "", expiry, deployer, "");
        registry.addClaim(a, ClaimTopics.SCREENED, abi.encode(uint64(block.timestamp)), expiry, deployer, "");
    }

    function _subscribe(uint256 i, uint256 offeringId, uint256 amount) internal {
        vm.broadcast(keys[i]);
        offerings.subscribe(offeringId, amount);
    }

    function _order(uint256 i, uint256 windowId, uint8 side, uint256 quantity, uint256 price) internal {
        vm.broadcast(keys[i]);
        windows.placeOrder(windowId, side, quantity, price);
    }

    function _quote(uint256 maker, address token, uint8 side, uint256 quantity, uint256 price, uint256 nonce)
        internal
        view
        returns (QuoteSettlement.Quote memory)
    {
        return QuoteSettlement.Quote({
            maker: investors[maker],
            shareToken: token,
            side: side,
            quantity: quantity,
            price: price,
            stablecoin: address(usdg),
            taker: address(0),
            nonce: nonce,
            expiry: uint64(block.timestamp + 7 days)
        });
    }

    function _signQuote(uint256 maker, QuoteSettlement.Quote memory q) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[maker], rfq.hashQuote(q));
        return abi.encodePacked(r, s, v);
    }

    function _fill(uint256 taker, QuoteSettlement.Quote memory q, bytes memory signature, uint256 quantity) internal {
        vm.broadcast(keys[taker]);
        rfq.fill(q, signature, quantity);
    }

    function _claim(uint256 i, uint256 distributionId) internal {
        vm.broadcast(keys[i]);
        distributions.claim(distributionId);
    }

    function _vote(uint256 i, uint256 proposalId, uint8 option) internal {
        vm.broadcast(keys[i]);
        governance.castVote(proposalId, option);
    }

    function _writeInvestors() internal {
        string[INVESTORS] memory names = ["ava", "ben", "chen", "dana", "eli", "fay"];
        string memory root = "seed";
        string memory json;
        for (uint256 i; i < INVESTORS; ++i) {
            json = vm.serializeAddress(root, names[i], investors[i]);
        }
        vm.writeJson(json, string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".seed.json"));
    }
}

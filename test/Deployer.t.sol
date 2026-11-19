// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.t.sol";
import {PincerDeployer} from "../src/platform/PincerDeployer.sol";
import {IPincerDeployer} from "../src/interfaces/IPincerDeployer.sol";
import {PincerEquityToken} from "../src/platform/PincerEquityToken.sol";
import {CompanyTimelock} from "../src/platform/CompanyTimelock.sol";
import {DocumentAnchor} from "../src/corporate/DocumentAnchor.sol";
import {ValuationFeed} from "../src/corporate/ValuationFeed.sol";
import {PoolGuard} from "../src/trading/PoolGuard.sol";
import {TransferPolicy} from "../src/policy/TransferPolicy.sol";
import {VerifierList} from "../src/registry/VerifierList.sol";
import {CheckCodes} from "../src/common/CheckCodes.sol";
import {ClaimTopics} from "../src/common/ClaimTopics.sol";

contract DeployerTest is TestBase {
    // PincerDeployer: stored records, access guards and emitted events

    function test_FactoryRecordsEverything() public {
        PincerEquityToken token = _plainClass("COMMON");
        IPincerDeployer.ShareClassInfo memory info = factory.shareClassOf(address(token));
        assertEq(info.companyId, COMPANY);
        assertEq(info.ruleEngine, address(token.ruleEngine()));
        assertEq(factory.shareTokens(COMPANY).length, 1);
        assertEq(factory.shareTokenOf(COMPANY, "COMMON"), address(token));
        assertEq(factory.companyContracts(COMPANY).issuerTimelock, address(timelock));
    }

    function test_FactoryGuards() public {
        vm.expectRevert();
        factory.deployShareClass(_params("X", new PincerDeployer.ModuleInit[](0), false));

        _plainClass("COMMON");
        vm.prank(pincer);
        vm.expectRevert(PincerDeployer.ShareClassExists.selector);
        factory.deployShareClass(_params("COMMON", new PincerDeployer.ModuleInit[](0), false));

        vm.prank(pincer);
        vm.expectRevert(abi.encodeWithSelector(PincerDeployer.UnknownModule.selector, bytes32("NOPE")));
        factory.deployShareClass(_params("Y", _modules1("NOPE", ""), false));
    }

    function test_FactoryEmitsShareClassDeployed() public {
        vm.recordLogs();
        PincerEquityToken token = _plainClass("COMMON");
        bool seen;
        bytes32 sig = keccak256("ShareClassDeployed(bytes32,bytes32,address,address,address)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == sig) {
                (address t,,) = abi.decode(logs[i].data, (address, address, address));
                seen = t == address(token);
            }
        }
        assertTrue(seen);
    }

    // CompanyTimelock: delay floors, approval thresholds and changes to the signer set

    function test_TimelockDelaysBySelector() public view {
        assertEq(timelock.delayFor(bytes4(keccak256("upgradeToAndCall(address,bytes)"))), 7 days);
        assertEq(timelock.delayFor(TransferPolicy.addModule.selector), 24 hours);
        assertEq(timelock.delayFor(bytes4(keccak256("grantRole(bytes32,address)"))), 48 hours);
    }

    function test_TimelockThresholdAndExecution() public {
        bytes memory data = abi.encodeCall(CompanyTimelock.setThreshold, (3));
        vm.prank(signer1);
        bytes32 id = timelock.propose(address(timelock), 0, data, "t");
        assertEq(timelock.approvalCount(id), 1);
        vm.expectRevert(CompanyTimelock.NotQueued.selector);
        timelock.execute(id);

        vm.prank(signer2);
        timelock.approve(id);
        assertEq(timelock.approvalCount(id), 2);
        assertFalse(timelock.isReady(id));
        vm.expectRevert(CompanyTimelock.TooEarly.selector);
        timelock.execute(id);
        vm.warp(T0 + 48 hours);
        assertTrue(timelock.isReady(id));
        timelock.execute(id);
        assertFalse(timelock.isReady(id));
        assertEq(timelock.threshold(), 3);
    }

    function test_RemovedSignerApprovalStopsCounting() public {
        bytes memory data = abi.encodeCall(CompanyTimelock.setDelay, (bytes4(0x12345678), 72 hours));
        vm.prank(signer1);
        bytes32 id = timelock.propose(address(timelock), 0, data, "d");

        _timelocked(address(timelock), abi.encodeCall(CompanyTimelock.removeSigner, (signer1)));
        vm.prank(signer2);
        timelock.approve(id); // stays unqueued: signer1 approved earlier, but that vote no longer counts, so 1 of 2
        assertEq(timelock.approvalCount(id), 1);
        vm.warp(block.timestamp + 72 hours);
        assertFalse(timelock.isReady(id));
        vm.expectRevert(CompanyTimelock.NotQueued.selector);
        timelock.execute(id);
    }

    function test_TimelockCannotGoBelowFloor() public {
        bytes memory data = abi.encodeCall(CompanyTimelock.setDelay, (TransferPolicy.addModule.selector, 1 hours));
        vm.prank(signer1);
        bytes32 id = timelock.propose(address(timelock), 0, data, "floor");
        vm.prank(signer2);
        timelock.approve(id);
        vm.warp(T0 + 48 hours);
        vm.expectRevert();
        timelock.execute(id);

        vm.expectRevert(CompanyTimelock.OnlySelf.selector);
        timelock.addSigner(alice);
    }

    // VerifierList topic management

    function test_VerifierListRejectsEmptyTopics() public {
        VerifierList list = VerifierList(c.trustedVerifiers);
        vm.prank(address(timelock));
        vm.expectRevert(VerifierList.NoTopics.selector);
        list.addVerifier(verifier, new bytes32[](0));
        // The failed call must leave the existing trust untouched.
        assertTrue(list.isTrusted(verifier, ClaimTopics.IDENTITY_VERIFIED));

        bytes32[] memory one = new bytes32[](1);
        one[0] = ClaimTopics.SCREENED;
        vm.prank(address(timelock));
        list.addVerifier(verifier, one);
        assertTrue(list.isTrusted(verifier, ClaimTopics.SCREENED));
        assertFalse(list.isTrusted(verifier, ClaimTopics.IDENTITY_VERIFIED));
    }

    // DocumentAnchor hashes and ValuationFeed publications

    function test_DisclosureRegistry() public {
        bytes32 hash = sha256("board resolution v1");
        vm.prank(issuerAdmin);
        uint256 id = disclosures.anchor("BOARD_RESOLUTION", hash, "ipfs://doc");
        assertEq(id, 1);
        assertEq(disclosures.document(id).hash, hash);
        assertEq(disclosures.documentIdByHash(hash), 1);
        assertEq(disclosures.latestDocumentIdOfKind("BOARD_RESOLUTION"), 1);
        assertEq(disclosures.latestDocumentIdOfKind("COMPANY_UPDATE"), 0);

        bytes32 hash2 = sha256("board resolution v2");
        vm.prank(issuerAdmin);
        uint256 second = disclosures.anchor("BOARD_RESOLUTION", hash2, "ipfs://doc2");
        assertEq(disclosures.latestDocumentIdOfKind("BOARD_RESOLUTION"), second);
        assertEq(disclosures.latestDocumentOfKind("BOARD_RESOLUTION").hash, hash2);
        assertTrue(disclosures.isAnchored(hash));
        assertFalse(disclosures.isAnchored(sha256("never anchored")));
        vm.expectRevert(DocumentAnchor.UnknownDocument.selector);
        disclosures.latestDocumentOfKind("COMPANY_UPDATE");

        vm.prank(issuerAdmin);
        vm.expectRevert(abi.encodeWithSelector(DocumentAnchor.AlreadyAnchored.selector, 1));
        disclosures.anchor("COMPANY_UPDATE", hash, "ipfs://copy");

        vm.prank(issuerAdmin);
        vm.expectRevert(DocumentAnchor.InvalidKind.selector);
        disclosures.anchor("MEME", hash, "");
        vm.prank(alice);
        vm.expectRevert();
        disclosures.anchor("COMPANY_UPDATE", hash, "");
    }

    function test_ValuationOracleAggregatorView() public {
        PincerEquityToken token = _plainClass("COMMON");
        ValuationFeed oracle = ValuationFeed(factory.shareClassOf(address(token)).valuationOracle);
        vm.expectRevert(ValuationFeed.NoData.selector);
        oracle.latestRoundData();

        vm.prank(issuerAdmin);
        oracle.publish(12.5e8, 1, uint64(T0 - 1 days), keccak256("409a"));
        (uint80 round, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(round, 1);
        assertEq(answer, 12.5e8);
        assertEq(updatedAt, T0 - 1 days);
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.description(), "NWD / USD reference valuation");
        ValuationFeed.Round memory r = oracle.round(1);
        assertEq(r.source, 1);
        assertEq(r.documentHash, keccak256("409a"));
        assertEq(r.publishedAt, block.timestamp);
        vm.expectRevert(ValuationFeed.NoData.selector);
        oracle.round(2);

        vm.prank(issuerAdmin);
        vm.expectRevert(ValuationFeed.InvalidDate.selector);
        oracle.publish(11e8, 1, uint64(T0 - 2 days), 0);

        vm.prank(issuerAdmin);
        token.pause("split");
        vm.prank(issuerAdmin);
        vm.expectRevert(ValuationFeed.TokenPaused.selector);
        oracle.publish(1e8, 1, uint64(T0), 0);
    }

    // PoolGuard and permissioned AMM pools

    function test_PoolGateRequiresVenueClaimAndBlocksRofrClasses() public {
        vm.prank(pincer);
        PincerEquityToken token =
            PincerEquityToken(factory.deployShareClass(_params("POOLED", new PincerDeployer.ModuleInit[](0), true)));
        PoolGuard gate = PoolGuard(factory.shareClassOf(address(token)).poolGate);
        address pool = address(new MockPool());

        vm.prank(address(timelock));
        vm.expectRevert(PoolGuard.NotVenue.selector);
        gate.registerPool(pool);

        vm.prank(operator);
        registry.registerIdentity(pool, pool);
        _addClaim(pool, ClaimTopics.VENUE, abi.encode(address(token)));
        assertTrue(token.isAgent(pool));
        vm.prank(address(timelock));
        gate.registerPool(pool);
        vm.prank(address(timelock));
        vm.expectRevert(PoolGuard.PoolAlreadyRegistered.selector);
        gate.registerPool(pool);

        _verify(alice);
        _mint(token, pool, _shares(10)); // the pool may hold shares only because its VENUE claim makes it an agent
        assertEq(gate.checkSwap(pool, alice, 1), CheckCodes.OK);
        assertEq(gate.checkSwap(pool, bob, 1), CheckCodes.RECIPIENT_NOT_VERIFIED);
        vm.prank(pool);
        vm.expectRevert();
        gate.beforeAddLiquidity(bob);

        vm.prank(address(timelock));
        gate.removePool(pool);
        assertEq(gate.checkSwap(pool, alice, 1), CheckCodes.NOT_ELIGIBLE);
        vm.prank(address(timelock));
        vm.expectRevert(PoolGuard.UnknownPool.selector);
        gate.removePool(pool);

        address[] memory venues = new address[](0);
        vm.prank(pincer);
        PincerEquityToken rofrToken = PincerEquityToken(
            factory.deployShareClass(_params("ROFR", _modules1("ROFR", abi.encode(treasury, uint32(1), venues)), true))
        );
        PoolGuard rofrGate = PoolGuard(factory.shareClassOf(address(rofrToken)).poolGate);
        vm.prank(address(timelock));
        vm.expectRevert(PoolGuard.ROFRIncompatible.selector);
        rofrGate.registerPool(pool);
    }

    function _params(bytes32 cls, PincerDeployer.ModuleInit[] memory modules, bool pools)
        internal
        pure
        returns (PincerDeployer.ShareClassParams memory)
    {
        return PincerDeployer.ShareClassParams({
            companyId: COMPANY,
            shareClass: cls,
            name: "Larkway",
            symbol: "NWD",
            documentsRoot: bytes32(0),
            modules: modules,
            enablePools: pools
        });
    }
}

contract MockPool {}

import {Vm} from "forge-std/Vm.sol";

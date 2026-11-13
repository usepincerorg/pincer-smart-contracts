// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.t.sol";
import {PincerEquityToken} from "../src/platform/PincerEquityToken.sol";
import {RaiseEscrow} from "../src/trading/RaiseEscrow.sol";
import {ValuationFeed} from "../src/corporate/ValuationFeed.sol";
import {IPincerEquityToken} from "../src/interfaces/IPincerEquityToken.sol";
import {CheckCodes} from "../src/common/CheckCodes.sol";
import {ClaimTopics} from "../src/common/ClaimTopics.sol";

contract RaiseEscrowTest is TestBase {
    PincerEquityToken internal token;
    uint256 internal constant PRICE = 25e6; // 25 USDG per share, expressed with 6 decimals

    function setUp() public override {
        super.setUp();
        token = _plainClass("SERIES_B");
        _verify(alice);
        _verify(bob);
        _verify(carol);
        _fund(alice, _usdg(1_000_000), address(offerings));
        _fund(bob, _usdg(1_000_000), address(offerings));
        _fund(carol, _usdg(1_000_000), address(offerings));
        _fund(dave, _usdg(1_000_000), address(offerings));
    }

    function _create(uint256 minRaise, uint256 maxRaise) internal returns (uint256 id) {
        bytes32[] memory claims = new bytes32[](1);
        claims[0] = ClaimTopics.INVESTOR_ELIGIBLE;
        vm.prank(issuerAdmin);
        id = offerings.createOffering(
            RaiseEscrow.OfferingParams({
                shareToken: address(token),
                pricePerShare: PRICE,
                minRaise: minRaise,
                maxRaise: maxRaise,
                minTicket: _usdg(1_000),
                opensAt: uint64(T0),
                closesAt: uint64(T0 + 14 days),
                stablecoin: address(usdg),
                requiredClaims: claims,
                treasury: treasury,
                documentId: 1
            })
        );
    }

    function _sub(address who, uint256 id, uint256 amount) internal {
        vm.prank(who);
        offerings.subscribe(id, amount);
    }

    function test_SuccessfulOffering() public {
        uint256 id = _create(_usdg(100_000), _usdg(500_000));
        _sub(alice, id, _usdg(100_000));
        _sub(bob, id, _usdg(50_000));

        vm.warp(T0 + 14 days);
        offerings.close(id);

        assertEq(token.balanceOf(alice), _shares(4_000));
        assertEq(token.balanceOf(bob), _shares(2_000));
        assertEq(usdg.balanceOf(feeRecipient), _usdg(1_500)); // 1% fee taken on the 150,000 raise
        assertEq(usdg.balanceOf(treasury), _usdg(148_500));
        assertEq(uint8(offerings.state(id)), uint8(RaiseEscrow.State.CLOSED));

        ValuationFeed oracle = ValuationFeed(factory.shareClassOf(address(token)).valuationOracle);
        (int256 price, uint8 source,,) = oracle.latestValuation();
        assertEq(price, 25e8);
        assertEq(source, 0); // value 0 means Source.PRICED_ROUND
    }

    function test_OversubscribedIsProRata() public {
        uint256 id = _create(_usdg(10_000), _usdg(100_000));
        _sub(alice, id, _usdg(150_000));
        _sub(bob, id, _usdg(50_000));
        vm.warp(T0 + 14 days);
        offerings.close(id);

        // Subscriptions total 200,000 while the cap is 100,000, so every allocation is cut to 50%.
        assertEq(token.balanceOf(alice), _shares(3_000));
        assertEq(token.balanceOf(bob), _shares(1_000));
        assertEq(offerings.refundableOf(id, alice), _usdg(75_000));

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        offerings.refund(id);
        assertEq(usdg.balanceOf(alice) - before, _usdg(75_000));
    }

    function test_FailedOfferingRefundsInFull() public {
        uint256 id = _create(_usdg(500_000), _usdg(1_000_000));
        _sub(alice, id, _usdg(20_000));
        vm.warp(T0 + 14 days);
        offerings.close(id);
        assertEq(uint8(offerings.state(id)), uint8(RaiseEscrow.State.FAILED));
        assertEq(token.totalSupply(), 0);

        vm.prank(alice);
        offerings.refund(id);
        assertEq(usdg.balanceOf(alice), _usdg(1_000_000));
        vm.prank(alice);
        vm.expectRevert(RaiseEscrow.NothingToRefund.selector);
        offerings.refund(id);
    }

    function test_SubscriberWhoStopsPassingIsRefunded() public {
        uint256 id = _create(_usdg(10_000), _usdg(500_000));
        _sub(alice, id, _usdg(20_000));
        _sub(bob, id, _usdg(20_000));
        vm.prank(operator);
        registry.removeIdentity(bob);
        vm.warp(T0 + 14 days);
        offerings.close(id);
        assertEq(token.balanceOf(bob), 0);
        assertEq(offerings.refundableOf(id, bob), _usdg(20_000));
        assertEq(usdg.balanceOf(treasury), _usdg(19_800));
    }

    function test_Guards() public {
        uint256 id = _create(_usdg(10_000), _usdg(500_000));
        vm.prank(dave); // dave lacks an eligibility claim because he was never verified
        vm.expectRevert(abi.encodeWithSelector(RaiseEscrow.MissingClaim.selector, ClaimTopics.INVESTOR_ELIGIBLE));
        offerings.subscribe(id, _usdg(5_000));

        vm.prank(alice);
        vm.expectRevert(RaiseEscrow.BelowMinimumTicket.selector);
        offerings.subscribe(id, _usdg(500));

        vm.expectRevert(RaiseEscrow.CannotClose.selector);
        offerings.close(id);

        vm.warp(T0 + 14 days);
        vm.prank(alice);
        vm.expectRevert(RaiseEscrow.NotOpen.selector);
        offerings.subscribe(id, _usdg(5_000));
    }

    function test_EarlyCloseOnceMaxReached() public {
        uint256 id = _create(_usdg(10_000), _usdg(50_000));
        _sub(alice, id, _usdg(50_000));
        vm.prank(issuerAdmin);
        offerings.close(id);
        assertEq(token.balanceOf(alice), _shares(2_000));
    }

    function test_CancelledOfferingRefunds() public {
        uint256 id = _create(_usdg(10_000), _usdg(50_000));
        _sub(alice, id, _usdg(10_000));
        vm.prank(issuerAdmin);
        offerings.cancelOffering(id);
        vm.prank(alice);
        offerings.refund(id);
        assertEq(usdg.balanceOf(alice), _usdg(1_000_000));
    }

    function test_RejectsOtherCompanyTokens() public {
        vm.prank(issuerAdmin);
        vm.expectRevert(RaiseEscrow.NotCompanyToken.selector);
        offerings.createOffering(
            RaiseEscrow.OfferingParams({
                shareToken: address(usdg),
                pricePerShare: PRICE,
                minRaise: 0,
                maxRaise: 1,
                minTicket: 0,
                opensAt: uint64(T0),
                closesAt: uint64(T0 + 1 days),
                stablecoin: address(usdg),
                requiredClaims: new bytes32[](0),
                treasury: treasury,
                documentId: 0
            })
        );
    }

    function test_RejectsBadParams() public {
        RaiseEscrow.OfferingParams memory p = RaiseEscrow.OfferingParams({
            shareToken: address(token),
            pricePerShare: PRICE,
            minRaise: 0,
            maxRaise: _usdg(10_000),
            minTicket: _usdg(20_000),
            opensAt: uint64(T0),
            closesAt: uint64(T0 + 1 days),
            stablecoin: address(usdg),
            requiredClaims: new bytes32[](0),
            treasury: treasury,
            documentId: 0
        });
        vm.prank(issuerAdmin);
        vm.expectRevert(RaiseEscrow.InvalidParams.selector);
        offerings.createOffering(p);

        p.minTicket = 0;
        p.requiredClaims = new bytes32[](offerings.MAX_REQUIRED_CLAIMS() + 1);
        vm.prank(issuerAdmin);
        vm.expectRevert(RaiseEscrow.InvalidParams.selector);
        offerings.createOffering(p);
    }

    function test_UnknownOffering() public {
        vm.expectRevert(RaiseEscrow.UnknownOffering.selector);
        offerings.state(0);
        vm.prank(alice);
        vm.expectRevert(RaiseEscrow.UnknownOffering.selector);
        offerings.subscribe(0, _usdg(1_000));
        vm.expectRevert(RaiseEscrow.UnknownOffering.selector);
        offerings.close(0);
    }
}

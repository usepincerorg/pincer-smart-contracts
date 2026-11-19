// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.t.sol";
import {PincerEquityToken} from "../src/platform/PincerEquityToken.sol";
import {QuoteSettlement} from "../src/trading/QuoteSettlement.sol";
import {IPincerEquityToken} from "../src/interfaces/IPincerEquityToken.sol";
import {CheckCodes} from "../src/common/CheckCodes.sol";

contract QuoteSettlementTest is TestBase {
    PincerEquityToken internal token;
    address internal maker;
    uint256 internal makerKey;

    function setUp() public override {
        super.setUp();
        (maker, makerKey) = makeAddrAndKey("maker");
        token = _plainClass("COMMON");
        _verify(maker);
        _verify(bob);
        _mint(token, maker, _shares(1_000));
        _mint(token, bob, _shares(1_000));
        _fund(maker, _usdg(100_000), address(rfq));
        _fund(bob, _usdg(100_000), address(rfq));
        vm.prank(maker);
        token.approve(address(rfq), type(uint256).max);
        vm.prank(bob);
        token.approve(address(rfq), type(uint256).max);
        vm.prank(issuerAdmin);
        rfq.setEnabled(address(token), true);
    }

    function _quote(uint8 side, uint256 qty, uint256 price, uint256 nonce)
        internal
        view
        returns (QuoteSettlement.Quote memory q, bytes memory sig)
    {
        q = QuoteSettlement.Quote({
            maker: maker,
            shareToken: address(token),
            side: side,
            quantity: _shares(qty),
            price: price,
            stablecoin: address(usdg),
            taker: address(0),
            nonce: nonce,
            expiry: uint64(T0 + 1 days)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, rfq.hashQuote(q));
        sig = abi.encodePacked(r, s, v);
    }

    function test_MakerSellsWithFees() public {
        (QuoteSettlement.Quote memory q, bytes memory sig) = _quote(0, 100, 30e6, 1);
        vm.prank(bob);
        rfq.fill(q, sig, _shares(100));
        assertEq(token.balanceOf(bob), _shares(1_100));
        // Buyer and seller are each charged 0.25% of the 3,000 USDG notional.
        assertEq(usdg.balanceOf(maker), _usdg(100_000) + _usdg(3_000) - 7.5e6);
        assertEq(usdg.balanceOf(bob), _usdg(100_000) - _usdg(3_000) - 7.5e6);
        assertEq(usdg.balanceOf(feeRecipient), 15e6);
    }

    function test_MakerBuysPartialFills() public {
        (QuoteSettlement.Quote memory q, bytes memory sig) = _quote(1, 100, 30e6, 1);
        vm.startPrank(bob);
        rfq.fill(q, sig, _shares(40));
        assertEq(rfq.remaining(q), _shares(60));
        rfq.fill(q, sig, _shares(60));
        assertEq(rfq.remaining(q), 0);
        vm.expectRevert(QuoteSettlement.Overfill.selector);
        rfq.fill(q, sig, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(maker), _shares(1_100));
    }

    function test_CancelAndInvalidate() public {
        (QuoteSettlement.Quote memory q, bytes memory sig) = _quote(0, 10, 30e6, 5);
        vm.prank(maker);
        rfq.cancelQuote(5);
        vm.prank(bob);
        vm.expectRevert(QuoteSettlement.QuoteCancelledError.selector);
        rfq.fill(q, sig, 1);

        assertEq(rfq.remaining(q), 0);

        (q, sig) = _quote(0, 10, 30e6, 6);
        assertEq(rfq.remaining(q), _shares(10));
        vm.expectEmit(address(rfq));
        emit QuoteSettlement.NoncesInvalidated(maker, 7);
        vm.prank(maker);
        rfq.invalidateNoncesBelow(7);
        assertEq(rfq.remaining(q), 0);
        vm.prank(bob);
        vm.expectRevert(QuoteSettlement.QuoteCancelledError.selector);
        rfq.fill(q, sig, 1);
    }

    function test_CancelQuotesInBatch() public {
        (QuoteSettlement.Quote memory a, bytes memory sigA) = _quote(0, 10, 30e6, 3);
        (QuoteSettlement.Quote memory b,) = _quote(0, 10, 30e6, 4);
        (QuoteSettlement.Quote memory keep,) = _quote(0, 10, 30e6, 9);
        uint256[] memory nonces = new uint256[](2);
        nonces[0] = 3;
        nonces[1] = 4;
        vm.prank(maker);
        rfq.cancelQuotes(nonces);
        assertEq(rfq.remaining(a), 0);
        assertEq(rfq.remaining(b), 0);
        assertEq(rfq.remaining(keep), _shares(10));
        vm.prank(bob);
        vm.expectRevert(QuoteSettlement.QuoteCancelledError.selector);
        rfq.fill(a, sigA, 1);
    }

    function test_ExpiryAndSignature() public {
        (QuoteSettlement.Quote memory q, bytes memory sig) = _quote(0, 10, 30e6, 1);
        q.price = 1e6; // tampered: differs from the signed maker price
        vm.prank(bob);
        vm.expectRevert(QuoteSettlement.InvalidSignature.selector);
        rfq.fill(q, sig, 1);

        (q, sig) = _quote(0, 10, 30e6, 2);
        vm.warp(T0 + 1 days);
        vm.prank(bob);
        vm.expectRevert(QuoteSettlement.Expired.selector);
        rfq.fill(q, sig, 1);
    }

    function test_MakerCannotFillOwnQuote() public {
        (QuoteSettlement.Quote memory q, bytes memory sig) = _quote(0, 10, 30e6, 1);
        vm.prank(maker);
        vm.expectRevert(QuoteSettlement.SelfFill.selector);
        rfq.fill(q, sig, _shares(1));
        assertEq(rfq.remaining(q), _shares(10));
    }

    function test_RulesRunOnEveryFill() public {
        (QuoteSettlement.Quote memory q, bytes memory sig) = _quote(0, 10, 30e6, 1);
        _fund(carol, _usdg(1_000), address(rfq)); // carol holds USDG but was never verified
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IPincerEquityToken.TransferNotAllowed.selector, CheckCodes.RECIPIENT_NOT_VERIFIED)
        );
        rfq.fill(q, sig, _shares(1));
    }

    function test_DisabledClass() public {
        vm.prank(issuerAdmin);
        rfq.setEnabled(address(token), false);
        (QuoteSettlement.Quote memory q, bytes memory sig) = _quote(0, 10, 30e6, 1);
        vm.prank(bob);
        vm.expectRevert(QuoteSettlement.NotEnabled.selector);
        rfq.fill(q, sig, 1);
    }
}

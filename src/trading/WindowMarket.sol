// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPincerEquityToken} from "../interfaces/IPincerEquityToken.sol";
import {IPincerDeployer} from "../interfaces/IPincerDeployer.sol";
import {IValuationFeed} from "../interfaces/IValuationFeed.sol";
import {AccessRoles} from "../common/AccessRoles.sol";

/// @title WindowMarket: scheduled batch trading windows for one share class
/// @notice Companies open these windows on a schedule so holders can buy and sell, using one of two formats:
///         - AUCTION: buyers and sellers each submit a limit price. After the window closes, one clearing price is
///           chosen that matches as much volume as possible, and every fill executes at that price.
///         - TENDER: the company sets the price up front, and participants only enter quantities. The side with
///           more interest than the other is cut back proportionally.
///         For the life of a window, sellers' shares and buyers' stablecoin sit in escrow in this contract. One call
///         to `clear` settles everything in a single transaction: shares go to buyers, stablecoin goes to sellers,
///         and whatever was not used returns to the party that deposited it.
/// @dev AUCTION price selection: every submitted limit price is evaluated, and only those achieving the maximum
///      matched volume remain candidates. Among them, the one nearest the most recent Reference Valuation wins; with
///      no valuation available, the target is the midpoint between the lowest ask and the highest bid. When the
///      reference sits inside the candidate range and achieves the same volume, the reference price is used directly.
///      If the winning price is below `reservePrice`, it is raised to the reserve and volume is recalculated at that
///      level, which may reduce volume or eliminate the match entirely. Fills are allocated by price priority, and
///      the marginal price level is split proportionally. Gross value rounds against the trader: buyer cost rounds
///      up, seller proceeds round down, and the leftover dust goes to the fee recipient. The buyer fee rounds up as
///      well; only the seller fee rounds down, which favours the seller.
///
///      When `rofrHolder` is set, that address holds a right of first refusal: during the `rofrPeriod` after close it
///      may commit to buying at the clearing price. Its quantity is filled before any other buyer and displaces them,
///      so the overall matched volume never increases.
///
///      The book is limited to MAX_ORDERS entries so that `clear` stays within a single transaction. If a buyer no
///      longer satisfies the share class rules after bidding, `clear` refunds that bid rather than reverting. The
///      company may also remove a problematic order in the interval between close and clearing.
contract WindowMarket is AccessControl, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 public constant SELL = 0;
    uint8 public constant BUY = 1;
    uint8 public constant AUCTION = 0;
    uint8 public constant TENDER = 1;
    uint256 public constant MAX_ORDERS = 200;
    uint16 public constant MAX_FEE_BPS = 250;

    struct WindowParams {
        address shareToken;
        uint8 mode;
        uint64 opensAt;
        uint64 closesAt;
        address stablecoin;
        uint256 reservePrice; // AUCTION only: minimum price, in stablecoin units per whole share
        uint256 tenderPrice; // TENDER only: the preset price; ignored for AUCTION
        uint256 maxVolume; // upper bound on matched volume (raw token units); 0 disables it
        uint256 perSellerCap; // per-seller offer limit (raw token units); 0 disables it
        address rofrHolder; // right of first refusal holder; address(0) when there is none
        uint32 rofrPeriod;
        bytes32[] sellerClaims;
        bytes32[] buyerClaims;
    }

    struct Order {
        address owner;
        uint8 side;
        bool active;
        uint256 quantity;
        uint256 limitPrice;
        uint256 locked; // stablecoin escrowed for a bid: cost at the limit price plus buyer fee
        uint256 filled;
    }

    struct Window {
        WindowParams params;
        bool cleared;
        bool cancelled;
        uint256 clearingPrice;
        uint256 volume;
        uint256 rofrQuantity;
        uint256 rofrLocked;
        uint256 rofrFilled;
    }

    event WindowOpened(uint256 indexed windowId, uint64 opensAt, uint64 closesAt);
    event OrderPlaced(
        uint256 indexed windowId, uint256 indexed orderId, uint8 side, uint256 quantity, uint256 limitPrice
    );
    event OrderCancelled(uint256 indexed windowId, uint256 indexed orderId);
    event RofrExercised(uint256 indexed windowId, address indexed holder, uint256 quantity, uint256 price);
    event WindowCleared(uint256 indexed windowId, uint256 clearingPrice, uint256 volume);
    event WindowCancelled(uint256 indexed windowId);
    event FeesUpdated(address recipient, uint16 sellerFeeBps, uint16 buyerFeeBps);
    event DeliveryDeferred(address indexed shareToken, address indexed owner, uint256 amount);
    event DeferredClaimed(address indexed shareToken, address indexed owner, uint256 amount);

    error InvalidParams();
    error NotCompanyToken();
    error NotOpen();
    error NotOwner();
    error TooManyOrders();
    error OverSellerCap();
    error MissingClaim(bytes32 topic);
    error NotInRofrPeriod();
    error AlreadyFinal();
    error TooEarly();
    error NoMarket();

    bytes32 public companyId;
    IPincerDeployer public factory;
    address public feeRecipient;
    uint16 public sellerFeeBps;
    uint16 public buyerFeeBps;

    Window[] private _windows;
    mapping(uint256 => Order[]) private _orders;
    mapping(uint256 => mapping(address => uint256)) public sellerQuantity;
    /// @notice Shares this contract is holding for an owner, keyed by share token, because a delivery to them was
    ///         blocked by the share class rules (for example due to an expired claim).
    mapping(address => mapping(address => uint256)) public deferredTokens;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        bytes32 companyId_,
        address factory_,
        address admin,
        address issuerAdmin,
        address feeRecipient_,
        uint16 sellerFeeBps_,
        uint16 buyerFeeBps_
    ) external initializer {
        companyId = companyId_;
        factory = IPincerDeployer(factory_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(AccessRoles.ISSUER_ADMIN, issuerAdmin);
        _setFees(feeRecipient_, sellerFeeBps_, buyerFeeBps_);
    }

    // ======== Window administration (company) ========

    function openWindow(WindowParams calldata p) external onlyRole(AccessRoles.ISSUER_ADMIN) returns (uint256 windowId) {
        if (factory.shareClassOf(p.shareToken).companyId != companyId) revert NotCompanyToken();
        if (p.mode > TENDER || p.closesAt <= p.opensAt || p.closesAt <= block.timestamp || p.stablecoin == address(0)) {
            revert InvalidParams();
        }
        if (p.mode == TENDER && p.tenderPrice == 0) revert InvalidParams();
        if (p.rofrHolder == address(0) && p.rofrPeriod != 0) revert InvalidParams();

        _windows.push();
        windowId = _windows.length - 1;
        _windows[windowId].params = p;
        emit WindowOpened(windowId, p.opensAt, p.closesAt);
    }

    /// @notice Cancels a window that has not been cleared yet and returns every escrowed share and stablecoin
    ///         balance to the party that deposited it.
    function cancelWindow(uint256 windowId) external onlyRole(AccessRoles.ISSUER_ADMIN) nonReentrant {
        Window storage w = _windows[windowId];
        if (w.cleared || w.cancelled) revert AlreadyFinal();
        w.cancelled = true;
        Order[] storage list = _orders[windowId];
        for (uint256 i; i < list.length; ++i) {
            if (list[i].active) _refund(w, list[i]);
        }
        if (w.rofrLocked != 0) {
            uint256 amount = w.rofrLocked;
            w.rofrLocked = 0;
            IERC20(w.params.stablecoin).safeTransfer(w.params.rofrHolder, amount);
        }
        emit WindowCancelled(windowId);
    }

    /// @notice Removes one order and refunds its escrow in the gap between close and clearing, for instance an
    ///         order that would otherwise block settlement.
    function removeOrder(uint256 windowId, uint256 orderId) external onlyRole(AccessRoles.ISSUER_ADMIN) nonReentrant {
        Window storage w = _windows[windowId];
        if (w.cleared || w.cancelled) revert AlreadyFinal();
        if (block.timestamp < w.params.closesAt) revert TooEarly();
        Order storage o = _orders[windowId][orderId];
        if (!o.active) revert AlreadyFinal();
        _refund(w, o);
        emit OrderCancelled(windowId, orderId);
    }

    function setFees(address recipient, uint16 sellerBps, uint16 buyerBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setFees(recipient, sellerBps, buyerBps);
    }

    // ======== Placing orders and withdrawing held tokens ========

    function placeOrder(uint256 windowId, uint8 side, uint256 quantity, uint256 limitPrice)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        Window storage w = _windows[windowId];
        WindowParams storage p = w.params;
        if (w.cleared || w.cancelled || block.timestamp < p.opensAt || block.timestamp >= p.closesAt) revert NotOpen();
        if (quantity == 0 || side > BUY) revert InvalidParams();
        if (_orders[windowId].length >= MAX_ORDERS) revert TooManyOrders();
        if (p.mode == TENDER) limitPrice = p.tenderPrice;
        else if (limitPrice == 0) revert InvalidParams();

        IPincerEquityToken token = IPincerEquityToken(p.shareToken);
        _requireClaims(token, side == SELL ? p.sellerClaims : p.buyerClaims);

        uint256 locked;
        if (side == SELL) {
            uint256 total = sellerQuantity[windowId][msg.sender] + quantity;
            if (p.perSellerCap != 0 && total > p.perSellerCap) revert OverSellerCap();
            sellerQuantity[windowId][msg.sender] = total;
            // Moving shares into escrow is a real transfer, so lockups, vesting, freezes and other sender rules apply.
            IERC20(address(token)).safeTransferFrom(msg.sender, address(this), quantity);
        } else {
            (bool ok, bytes32 code) = token.canTransfer(address(this), msg.sender, quantity);
            if (!ok) revert IPincerEquityToken.TransferNotAllowed(code);
            locked = _buyerTotal(quantity, limitPrice);
            IERC20(p.stablecoin).safeTransferFrom(msg.sender, address(this), locked);
        }

        _orders[windowId].push(
            Order({
                owner: msg.sender,
                side: side,
                active: true,
                quantity: quantity,
                limitPrice: limitPrice,
                locked: locked,
                filled: 0
            })
        );
        orderId = _orders[windowId].length - 1;
        emit OrderPlaced(windowId, orderId, side, quantity, limitPrice);
    }

    function cancelOrder(uint256 windowId, uint256 orderId) external nonReentrant {
        Window storage w = _windows[windowId];
        if (w.cleared || w.cancelled || block.timestamp >= w.params.closesAt) revert NotOpen();
        Order storage o = _orders[windowId][orderId];
        if (o.owner != msg.sender) revert NotOwner();
        if (!o.active) revert AlreadyFinal();
        if (o.side == SELL) sellerQuantity[windowId][msg.sender] -= o.quantity;
        _refund(w, o);
        emit OrderCancelled(windowId, orderId);
    }

    /// @notice Used by the right of first refusal holder to commit to buying up to `quantity` at the clearing price,
    ///         ahead of all other buyers. Allowed once per window and only during the ROFR period; the escrow deposit
    ///         is computed from the preview price at the time of the call.
    function exerciseRofr(uint256 windowId, uint256 quantity) external nonReentrant {
        Window storage w = _windows[windowId];
        WindowParams storage p = w.params;
        if (msg.sender != p.rofrHolder || w.cleared || w.cancelled || w.rofrQuantity != 0 || quantity == 0) {
            revert NotInRofrPeriod();
        }
        if (block.timestamp < p.closesAt || block.timestamp >= uint256(p.closesAt) + p.rofrPeriod) {
            revert NotInRofrPeriod();
        }
        (uint256 price,) = previewClearing(windowId);
        if (price == 0) revert NoMarket();
        (bool ok, bytes32 code) = IPincerEquityToken(p.shareToken).canTransfer(address(this), msg.sender, quantity);
        if (!ok) revert IPincerEquityToken.TransferNotAllowed(code);

        uint256 locked = _buyerTotal(quantity, price);
        w.rofrQuantity = quantity;
        w.rofrLocked = locked;
        IERC20(p.stablecoin).safeTransferFrom(msg.sender, address(this), locked);
        emit RofrExercised(windowId, msg.sender, quantity, price);
    }

    /// @notice Sends the caller shares that were held back when an earlier delivery failed a rule. The share class
    ///         rules also apply to this transfer, so the caller must satisfy them at the time of claiming.
    function claimDeferred(address shareToken) external nonReentrant {
        uint256 amount = deferredTokens[shareToken][msg.sender];
        if (amount == 0) revert AlreadyFinal();
        deferredTokens[shareToken][msg.sender] = 0;
        IERC20(shareToken).safeTransfer(msg.sender, amount);
        emit DeferredClaimed(shareToken, msg.sender, amount);
    }

    // ======== Price discovery and settlement ========

    /// @notice Returns the price and volume the current book would produce. Any ROFR commitment is ignored, and the
    ///         `maxVolume` cap that `clear` enforces is not applied, so the volume here may exceed the settled one.
    function previewClearing(uint256 windowId) public view returns (uint256 price, uint256 volume) {
        Book memory book = _loadBook(windowId);
        (price, volume) = _clearingPrice(_windows[windowId].params, book);
    }

    /// @notice Settles the window. Any account may call it once the window has closed and the ROFR period, if there
    ///         is one, has ended.
    function clear(uint256 windowId) external nonReentrant {
        Window storage w = _windows[windowId];
        WindowParams storage p = w.params;
        if (w.cleared || w.cancelled) revert AlreadyFinal();
        if (block.timestamp < uint256(p.closesAt) + p.rofrPeriod) revert TooEarly();
        w.cleared = true;

        Book memory book = _loadBook(windowId);
        (uint256 price, uint256 volume) = _clearingPrice(p, book);
        if (p.maxVolume != 0 && volume > p.maxVolume) volume = p.maxVolume;
        uint256 rofrFill = Math.min(w.rofrQuantity, volume);
        // The deposit was sized from an earlier preview price; reduce the fill until the deposit pays for it.
        while (rofrFill != 0 && _buyerTotal(rofrFill, price) > w.rofrLocked) {
            rofrFill = Math.mulDiv(rofrFill, w.rofrLocked, _buyerTotal(rofrFill, price));
        }

        uint256[] memory askFills = _allocate(book, SELL, price, volume, p.mode == TENDER);
        uint256[] memory bidFills = _allocate(book, BUY, price, volume - rofrFill, p.mode == TENDER);

        Settlement memory s;
        Order[] storage list = _orders[windowId];
        for (uint256 i; i < list.length; ++i) {
            Order storage o = list[i];
            if (!o.active) continue;
            o.active = false;
            if (o.side == SELL) _settleAsk(p, o, askFills[i], price, s);
            else _settleBid(p, o, bidFills[i], price, s);
        }
        if (w.rofrQuantity != 0) {
            w.rofrFilled = rofrFill;
            _settleRofr(w, rofrFill, price, s);
        }

        // What buyers paid minus what sellers received equals the fees plus rounding dust (buyers round up, sellers
        // down). With both fee rates at zero `_setFees` allows a zero recipient, yet dust may still be nonzero, so a
        // stablecoin that rejects transfers to address(0) would make this line revert.
        uint256 toFeeRecipient = s.buyerPaid - s.sellerReceived;
        if (toFeeRecipient != 0) IERC20(p.stablecoin).safeTransfer(feeRecipient, toFeeRecipient);

        w.clearingPrice = price;
        w.volume = volume;
        if (volume != 0) _publishValuation(p, price);
        emit WindowCleared(windowId, price, volume);
    }

    // ======== Views ========

    function window(uint256 windowId) external view returns (Window memory) {
        return _windows[windowId];
    }

    function windowCount() external view returns (uint256) {
        return _windows.length;
    }

    function orders(uint256 windowId) external view returns (Order[] memory) {
        return _orders[windowId];
    }

    // ======== Internal: building the book and choosing a price ========

    struct Book {
        uint256 n;
        uint8[] side;
        uint256[] qty;
        uint256[] limit;
        bool[] live;
    }

    struct Settlement {
        uint256 buyerPaid; // sum charged to buyers for fills, buyer fees included
        uint256 sellerReceived; // sum paid out to sellers, net of seller fees
        uint256 fees;
    }

    function _loadBook(uint256 windowId) private view returns (Book memory b) {
        Order[] storage orders_ = _orders[windowId];
        address token = _windows[windowId].params.shareToken;
        uint256 n = orders_.length;
        b.n = n;
        b.side = new uint8[](n);
        b.qty = new uint256[](n);
        b.limit = new uint256[](n);
        b.live = new bool[](n);
        for (uint256 i; i < n; ++i) {
            Order storage o = orders_[i];
            b.side[i] = o.side;
            b.qty[i] = o.quantity;
            b.limit[i] = o.limitPrice;
            if (!o.active) continue;
            if (o.side == BUY) {
                (bool ok,) = IPincerEquityToken(token).canTransfer(address(this), o.owner, o.quantity);
                b.live[i] = ok;
            } else {
                b.live[i] = true;
            }
        }
    }

    function _clearingPrice(WindowParams storage p, Book memory b)
        private
        view
        returns (uint256 price, uint256 volume)
    {
        if (p.mode == TENDER) {
            uint256 supply;
            uint256 demand;
            for (uint256 i; i < b.n; ++i) {
                if (!b.live[i]) continue;
                if (b.side[i] == SELL) supply += b.qty[i];
                else demand += b.qty[i];
            }
            volume = Math.min(supply, demand);
            return (volume == 0 ? 0 : p.tenderPrice, volume);
        }

        uint256 bestVolume;
        uint256 lo = type(uint256).max;
        uint256 hi;
        uint256 minAsk = type(uint256).max;
        uint256 maxBid;
        for (uint256 i; i < b.n; ++i) {
            if (!b.live[i]) continue;
            if (b.side[i] == SELL && b.limit[i] < minAsk) minAsk = b.limit[i];
            if (b.side[i] == BUY && b.limit[i] > maxBid) maxBid = b.limit[i];
            uint256 v = _volumeAt(b, b.limit[i]);
            if (v > bestVolume) {
                bestVolume = v;
                lo = b.limit[i];
                hi = b.limit[i];
            } else if (v == bestVolume && v != 0) {
                if (b.limit[i] < lo) lo = b.limit[i];
                if (b.limit[i] > hi) hi = b.limit[i];
            }
        }
        if (bestVolume == 0) return (0, 0);

        uint256 ref = _referencePrice(p);
        if (ref == 0) ref = (minAsk + maxBid) / 2;
        // Of all prices achieving the maximum volume, choose the one nearest the reference. On a tie the earlier
        // candidate wins, starting from `lo`.
        if (ref >= lo && ref <= hi && _volumeAt(b, ref) == bestVolume) {
            price = ref;
        } else {
            price = lo;
            uint256 bestDistance = _distance(lo, ref);
            for (uint256 i; i < b.n; ++i) {
                if (!b.live[i] || _volumeAt(b, b.limit[i]) != bestVolume) continue;
                uint256 d = _distance(b.limit[i], ref);
                if (d < bestDistance) {
                    bestDistance = d;
                    price = b.limit[i];
                }
            }
        }
        if (price < p.reservePrice) price = p.reservePrice;
        volume = _volumeAt(b, price);
        if (volume == 0) price = 0;
    }

    function _volumeAt(Book memory b, uint256 price) private pure returns (uint256) {
        uint256 supply;
        uint256 demand;
        for (uint256 i; i < b.n; ++i) {
            if (!b.live[i]) continue;
            if (b.side[i] == SELL && b.limit[i] <= price) supply += b.qty[i];
            else if (b.side[i] == BUY && b.limit[i] >= price) demand += b.qty[i];
        }
        return Math.min(supply, demand);
    }

    /// @dev Fills one side of the book starting at its best price. Entire levels are filled until `volume` runs
    ///      short, and the remainder is shared proportionally among orders at the marginal level.
    function _allocate(Book memory b, uint8 side, uint256 price, uint256 volume, bool tender)
        private
        pure
        returns (uint256[] memory fills)
    {
        fills = new uint256[](b.n);
        if (price == 0 || volume == 0) return fills;
        bool[] memory done = new bool[](b.n);
        uint256 remaining = volume;

        while (remaining != 0) {
            // Find the next level: cheapest remaining ask or highest remaining bid. A tender has just one level.
            bool found;
            uint256 level;
            for (uint256 i; i < b.n; ++i) {
                if (done[i] || !_eligible(b, i, side, price, tender)) continue;
                if (!found || (side == SELL ? b.limit[i] < level : b.limit[i] > level)) {
                    level = b.limit[i];
                    found = true;
                }
            }
            if (!found) break;

            uint256 levelQty;
            for (uint256 i; i < b.n; ++i) {
                if (!done[i] && _eligible(b, i, side, price, tender) && (tender || b.limit[i] == level)) {
                    levelQty += b.qty[i];
                }
            }

            if (levelQty <= remaining) {
                for (uint256 i; i < b.n; ++i) {
                    if (!done[i] && _eligible(b, i, side, price, tender) && (tender || b.limit[i] == level)) {
                        fills[i] = b.qty[i];
                        done[i] = true;
                    }
                }
                remaining -= levelQty;
            } else {
                uint256 allocated;
                for (uint256 i; i < b.n; ++i) {
                    if (!done[i] && _eligible(b, i, side, price, tender) && (tender || b.limit[i] == level)) {
                        fills[i] = (b.qty[i] * remaining) / levelQty;
                        allocated += fills[i];
                        done[i] = true;
                    }
                }
                // Hand out the division remainder in book order, each order taking as much as its unfilled size allows.
                uint256 leftover = remaining - allocated;
                for (uint256 i; i < b.n && leftover != 0; ++i) {
                    if (
                        done[i] && fills[i] < b.qty[i] && _eligible(b, i, side, price, tender)
                            && (tender || b.limit[i] == level)
                    ) {
                        uint256 room = b.qty[i] - fills[i];
                        uint256 add = room < leftover ? room : leftover;
                        fills[i] += add;
                        leftover -= add;
                    }
                }
                remaining = 0;
            }
        }
    }

    function _eligible(Book memory b, uint256 i, uint8 side, uint256 price, bool tender) private pure returns (bool) {
        if (!b.live[i] || b.side[i] != side) return false;
        if (tender) return true;
        return side == SELL ? b.limit[i] <= price : b.limit[i] >= price;
    }

    // ======== Internal: settling fills and transfers ========

    function _settleAsk(WindowParams storage p, Order storage o, uint256 fill, uint256 price, Settlement memory s)
        private
    {
        o.filled = fill;
        if (fill != 0) {
            uint256 gross = (fill * price) / 1e18;
            uint256 fee = (gross * sellerFeeBps) / 10_000;
            s.fees += fee;
            s.sellerReceived += gross - fee;
            IERC20(p.stablecoin).safeTransfer(o.owner, gross - fee);
        }
        if (o.quantity > fill) _deliver(p.shareToken, o.owner, o.quantity - fill);
    }

    function _settleBid(WindowParams storage p, Order storage o, uint256 fill, uint256 price, Settlement memory s)
        private
    {
        o.filled = fill;
        uint256 charged;
        if (fill != 0) {
            charged = _buyerTotal(fill, price);
            s.fees += charged - Math.mulDiv(fill, price, 1e18, Math.Rounding.Ceil);
            s.buyerPaid += charged;
            _deliver(p.shareToken, o.owner, fill);
        }
        if (o.locked > charged) IERC20(p.stablecoin).safeTransfer(o.owner, o.locked - charged);
    }

    function _settleRofr(Window storage w, uint256 fill, uint256 price, Settlement memory s) private {
        WindowParams storage p = w.params;
        uint256 charged;
        if (fill != 0) {
            charged = _buyerTotal(fill, price);
            s.fees += charged - Math.mulDiv(fill, price, 1e18, Math.Rounding.Ceil);
            s.buyerPaid += charged;
            _deliver(p.shareToken, p.rofrHolder, fill);
        }
        uint256 locked = w.rofrLocked;
        w.rofrLocked = 0;
        if (locked > charged) IERC20(p.stablecoin).safeTransfer(p.rofrHolder, locked - charged);
    }

    function _refund(Window storage w, Order storage o) private {
        o.active = false;
        if (o.side == SELL) _deliver(w.params.shareToken, o.owner, o.quantity);
        else IERC20(w.params.stablecoin).safeTransfer(o.owner, o.locked);
    }

    /// @dev Settlement must not revert because one share transfer fails. If the recipient is rejected by the share
    ///      class rules, the shares stay here and are credited to `deferredTokens`; the recipient can retrieve them
    ///      through `claimDeferred` after becoming eligible again.
    function _deliver(address shareToken, address to, uint256 amount) private {
        try IERC20(shareToken).transfer(to, amount) returns (bool ok) {
            if (ok) return;
        } catch {}
        deferredTokens[shareToken][to] += amount;
        emit DeliveryDeferred(shareToken, to, amount);
    }

    /// @dev Total stablecoin a buyer owes for `quantity` at `price`, computed as gross value (rounded up) plus the
    ///      buyer fee charged on that gross (also rounded up).
    function _buyerTotal(uint256 quantity, uint256 price) private view returns (uint256) {
        uint256 gross = Math.mulDiv(quantity, price, 1e18, Math.Rounding.Ceil);
        return gross + Math.mulDiv(gross, buyerFeeBps, 10_000, Math.Rounding.Ceil);
    }

    function _requireClaims(IPincerEquityToken token, bytes32[] storage topics) private view {
        for (uint256 i; i < topics.length; ++i) {
            if (!token.identityRegistry().hasValidClaim(msg.sender, topics[i])) revert MissingClaim(topics[i]);
        }
    }

    function _referencePrice(WindowParams storage p) private view returns (uint256) {
        address oracle = factory.shareClassOf(p.shareToken).valuationOracle;
        try IValuationFeed(oracle).latestValuation() returns (int256 price, uint8, uint64, bytes32) {
            if (price <= 0) return 0;
            return _fromOracleUnits(uint256(price), IERC20Metadata(p.stablecoin).decimals());
        } catch {
            return 0;
        }
    }

    function _publishValuation(WindowParams storage p, uint256 price) private {
        address oracle = factory.shareClassOf(p.shareToken).valuationOracle;
        uint256 oraclePrice = _toOracleUnits(price, IERC20Metadata(p.stablecoin).decimals());
        if (oraclePrice == 0) return;
        try IValuationFeed(oracle)
            .publish(
                int256(oraclePrice), uint8(IValuationFeed.Source.WINDOW_CLEARING), uint64(block.timestamp), bytes32(0)
            ) {}
            catch {}
    }

    function _toOracleUnits(uint256 amount, uint8 d) private pure returns (uint256) {
        if (d == 8) return amount;
        return d < 8 ? amount * 10 ** (8 - d) : amount / 10 ** (d - 8);
    }

    function _fromOracleUnits(uint256 amount, uint8 d) private pure returns (uint256) {
        if (d == 8) return amount;
        return d < 8 ? amount / 10 ** (8 - d) : amount * 10 ** (d - 8);
    }

    function _distance(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _setFees(address recipient, uint16 sellerBps, uint16 buyerBps) private {
        if (sellerBps > MAX_FEE_BPS || buyerBps > MAX_FEE_BPS) revert InvalidParams();
        if ((sellerBps != 0 || buyerBps != 0) && recipient == address(0)) revert InvalidParams();
        feeRecipient = recipient;
        sellerFeeBps = sellerBps;
        buyerFeeBps = buyerBps;
        emit FeesUpdated(recipient, sellerBps, buyerBps);
    }
}

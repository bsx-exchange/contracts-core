// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";

import {IOrderBook, OrderBook} from "src/OrderBook.sol";
import {IPerp, Perp} from "src/Perp.sol";
import {Spot} from "src/Spot.sol";
import {Access} from "src/access/Access.sol";
import {LibOrder} from "src/lib/LibOrder.sol";
import {MathHelper} from "src/lib/MathHelper.sol";
import {MAX_MATCH_FEES, MAX_TAKER_SEQUENCER_FEE} from "src/share/Constants.sol";
import {OrderSide} from "src/share/Enums.sol";
import {
    DUPLICATE_ADDRESS,
    INVALID_ADDRESS,
    INVALID_FEES,
    INVALID_MATCH_SIDE,
    INVALID_SEQUENCER_FEES,
    NONCE_USED,
    NOT_SEQUENCER,
    REQUIRE_ONE_LIQUIDATION_ORDER
} from "src/share/RevertReason.sol";

contract OrderbookTest is Test {
    using MathHelper for uint128;
    using MathHelper for int128;
    using stdStorage for StdStorage;

    address private exchange = makeAddr("exchange");
    address private clearinghouse = makeAddr("clearinghouse");
    address private token = makeAddr("token");

    uint8 private productId = 0;
    address private maker = makeAddr("maker");
    uint64 private makerNonce = 1;
    address private taker = makeAddr("taker");
    uint64 private takerNonce = 2;

    Access private access;
    Perp private perpEngine;
    Spot private spotEngine;
    OrderBook private orderbook;

    function setUp() public {
        access = new Access();
        access.initialize(address(this));
        access.setExchange(exchange);

        spotEngine = new Spot();
        spotEngine.initialize(address(access));

        perpEngine = new Perp();
        perpEngine.initialize(address(access));

        orderbook = new OrderBook();
        orderbook.initialize(address(clearinghouse), address(spotEngine), address(perpEngine), address(access), token);
        access.setOrderBook(address(orderbook));
    }

    function test_initialize() public view {
        assertEq(address(orderbook.clearingService()), clearinghouse);
        assertEq(address(orderbook.spotEngine()), address(spotEngine));
        assertEq(address(orderbook.perpEngine()), address(perpEngine));
        assertEq(address(orderbook.access()), address(access));
        assertEq(orderbook.getCollateralToken(), token);
    }

    function test_initialize_revertsIfSetZeroAddr() public {
        OrderBook _orderbook = new OrderBook();
        address mockAddr = makeAddr("mockAddr");
        address[5] memory addresses = [mockAddr, mockAddr, mockAddr, mockAddr, mockAddr];
        for (uint256 i = 0; i < 5; i++) {
            addresses[i] = address(0);
            vm.expectRevert(bytes(INVALID_ADDRESS));
            _orderbook.initialize(addresses[0], addresses[1], addresses[2], addresses[3], addresses[4]);
            addresses[i] = mockAddr;
        }
    }

    function test_claimSequencerFees() public {
        vm.startPrank(exchange);

        int256 collectedSequencerFee = 75_000;
        stdstore.target(address(orderbook)).sig("getSequencerFees()").checked_write_int(collectedSequencerFee);
        assertEq(orderbook.getSequencerFees(), collectedSequencerFee);

        assertEq(orderbook.claimSequencerFees(), collectedSequencerFee);
        assertEq(orderbook.getSequencerFees(), 0);
    }

    function test_claimSequencerFees_revertsWhenUnauthorized() public {
        vm.expectRevert(bytes(NOT_SEQUENCER));
        orderbook.claimSequencerFees();
    }

    function test_claimCollectedTradingFees() public {
        vm.startPrank(exchange);

        int256 collectedTradingFee = 125_000;
        stdstore.target(address(orderbook)).sig("getTradingFees()").checked_write_int(collectedTradingFee);
        assertEq(orderbook.getTradingFees(), collectedTradingFee);

        assertEq(orderbook.claimTradingFees(), collectedTradingFee);
        assertEq(orderbook.getTradingFees(), 0);
    }

    function test_claimCollectedTradingFee_revertsWhenUnauthorized() public {
        vm.expectRevert(bytes(NOT_SEQUENCER));
        orderbook.claimTradingFees();
    }

    function test_matchOrders_makerGoLong() public {
        vm.startPrank(exchange);

        LibOrder.SignedOrder memory makerOrder;
        LibOrder.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;
        (makerOrder, digest.maker) = _createLongOrder(maker, size, price, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createShortOrder(taker, size, price, takerNonce, isLiquidation);

        IOrderBook.Fee memory fee;
        uint128 takerSequencerFee;

        vm.expectEmit(address(orderbook));
        emit IOrderBook.OrderMatched(
            productId,
            maker,
            taker,
            makerOrder.order.orderSide,
            makerOrder.order.nonce,
            takerOrder.order.nonce,
            size,
            price,
            fee,
            isLiquidation
        );
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, takerSequencerFee, fee);

        int128 expectedBaseAmount = int128(size);
        int128 expectedQuoteAmount = expectedBaseAmount.mul18D(int128(price));
        assertEq(
            abi.encode(perpEngine.getBalance(maker, productId)),
            abi.encode(IPerp.Balance(expectedBaseAmount, -expectedQuoteAmount, 0))
        );
        assertEq(
            abi.encode(perpEngine.getBalance(taker, productId)),
            abi.encode(IPerp.Balance(-expectedBaseAmount, expectedQuoteAmount, 0))
        );
        assertEq(spotEngine.getBalance(token, maker), 0);
        assertEq(spotEngine.getBalance(token, taker), 0);

        assertEq(orderbook.getSequencerFees(), 0);
        assertEq(orderbook.getTradingFees(), 0);

        assertEq(orderbook.isMatched(maker, makerNonce, taker, takerNonce), true);
    }

    function test_matchOrders_makerGoShort() public {
        vm.startPrank(exchange);

        LibOrder.SignedOrder memory makerOrder;
        LibOrder.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;
        (makerOrder, digest.maker) = _createShortOrder(maker, size, price, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createLongOrder(taker, size, price, takerNonce, isLiquidation);

        IOrderBook.Fee memory fee;
        uint128 takerSequencerFee;

        vm.expectEmit(address(orderbook));
        emit IOrderBook.OrderMatched(
            productId,
            maker,
            taker,
            makerOrder.order.orderSide,
            makerOrder.order.nonce,
            takerOrder.order.nonce,
            size,
            price,
            fee,
            isLiquidation
        );
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, takerSequencerFee, fee);

        int128 expectedBaseAmount = int128(size);
        int128 expectedQuoteAmount = expectedBaseAmount.mul18D(int128(price));
        assertEq(
            abi.encode(perpEngine.getBalance(maker, productId)),
            abi.encode(IPerp.Balance(-expectedBaseAmount, expectedQuoteAmount, 0))
        );
        assertEq(
            abi.encode(perpEngine.getBalance(taker, productId)),
            abi.encode(IPerp.Balance(expectedBaseAmount, -expectedQuoteAmount, 0))
        );
        assertEq(spotEngine.getBalance(token, maker), 0);
        assertEq(spotEngine.getBalance(token, taker), 0);

        assertEq(orderbook.getSequencerFees(), 0);
        assertEq(orderbook.getTradingFees(), 0);

        assertEq(orderbook.isMatched(maker, makerNonce, taker, takerNonce), true);
    }

    function test_matchOrders_closePosition_settlePnl() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        LibOrder.SignedOrder memory makerOrder;
        LibOrder.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;
        IOrderBook.Fee memory fee;
        uint128 takerSequencerFee;

        uint128 openPositionPrice = 75_000 * 1e18;
        (makerOrder, digest.maker) = _createLongOrder(maker, size, openPositionPrice, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createShortOrder(taker, size, openPositionPrice, takerNonce, isLiquidation);
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, takerSequencerFee, fee);

        uint128 closePositionPrice = 80_000 * 1e18;
        (makerOrder, digest.maker) = _createShortOrder(maker, size, closePositionPrice, makerNonce + 1, isLiquidation);
        (takerOrder, digest.taker) = _createLongOrder(taker, size, closePositionPrice, takerNonce + 1, isLiquidation);
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, takerSequencerFee, fee);

        assertEq(abi.encode(perpEngine.getBalance(maker, productId)), abi.encode(IPerp.Balance(0, 0, 0)));
        assertEq(abi.encode(perpEngine.getBalance(taker, productId)), abi.encode(IPerp.Balance(0, 0, 0)));

        int128 pnl = int128(size).mul18D(int128(closePositionPrice - openPositionPrice));
        assertEq(spotEngine.getBalance(token, maker), pnl);
        assertEq(spotEngine.getBalance(token, taker), -pnl);
    }

    // function test_matchOrders_closeHalfPosition_settlePnl() public {
    //     vm.startPrank(exchange);

    //     bool isLiquidation = false;
    //     IOrderbook.Fee memory fee;

    //     uint128 price = 75_000 * 1e18;

    //     uint128 openSize = 5 * 1e18;
    //     IOrderbook.Order memory makerOpenPosition = _createLongOrder(maker, openSize, price, makerNonce);
    //     IOrderbook.Order memory takerOpenPosition = _createShortOrder(taker, openSize, price, takerNonce);
    //     orderbook.matchOrders(productId, makerOpenPosition, takerOpenPosition, fee, isLiquidation);

    //     uint128 closeSize = 2 * 1e18;
    //     IOrderbook.Order memory makerOrder = _createShortOrder(maker, closeSize, price, makerNonce + 1);
    //     IOrderbook.Order memory takerOrder = _createLongOrder(taker, closeSize, price, takerNonce + 1);
    //     orderbook.matchOrders(productId, makerOrder, takerOrder, fee, isLiquidation);

    //     int128 expectedBaseAmount = int128(openSize - closeSize);
    //     int128 expectedQuoteAmount = expectedBaseAmount.mul18D(int128(price));
    //     assertEq(
    //         abi.encode(perpEngine.getOpenPosition(productId, maker)),
    //         abi.encode(IPerpEngine.OpenPosition(expectedBaseAmount, -expectedQuoteAmount, 0))
    //     );
    //     assertEq(
    //         abi.encode(perpEngine.getOpenPosition(productId, taker)),
    //         abi.encode(IPerpEngine.OpenPosition(-expectedBaseAmount, expectedQuoteAmount, 0))
    //     );

    //     assertEq(spotEngine.getBalance(maker, token), 0);
    //     assertEq(spotEngine.getBalance(taker, token), 0);
    // }

    function test_matchOrders_changePosition_settlePnl() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        LibOrder.SignedOrder memory makerOrder;
        LibOrder.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;
        IOrderBook.Fee memory fee;
        uint128 takerSequencerFee;

        uint128 size0 = 2 * 1e18;
        uint128 price0 = 40_000 * 1e18;
        (makerOrder, digest.maker) = _createLongOrder(maker, size0, price0, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createShortOrder(taker, size0, price0, takerNonce, isLiquidation);
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, takerSequencerFee, fee);

        uint128 size1 = 4 * 1e18;
        uint128 price1 = 80_000 * 1e18;
        (makerOrder, digest.maker) = _createShortOrder(maker, size1, price1, makerNonce + 1, isLiquidation);
        (takerOrder, digest.taker) = _createLongOrder(taker, size1, price1, takerNonce + 1, isLiquidation);
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, takerSequencerFee, fee);

        int128 expectedBaseAmount = int128(size1 - size0);
        int128 expectedQuoteAmount = expectedBaseAmount.mul18D(int128(price1));
        assertEq(
            abi.encode(perpEngine.getBalance(maker, productId)),
            abi.encode(IPerp.Balance(-expectedBaseAmount, expectedQuoteAmount, 0))
        );
        assertEq(
            abi.encode(perpEngine.getBalance(taker, productId)),
            abi.encode(IPerp.Balance(expectedBaseAmount, -expectedQuoteAmount, 0))
        );

        int128 pnl = int128(size1 - size0).mul18D(int128(price1 - price0));
        assertEq(spotEngine.getBalance(token, maker), pnl);
        assertEq(spotEngine.getBalance(token, taker), -pnl);
    }

    // TODO: test order fees
    // function test_matchOrders_withOrderFees() public {
    //     vm.startPrank(exchange);

    //     bool isLiquidation = false;
    //     uint128 size = 2 * 1e18;
    //     uint128 price = 75_000 * 1e18;

    //     IOrderbook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
    //     IOrderbook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);

    //     IOrderbook.Fee memory fee =
    //         IOrderbook.Fee({maker: 2e14, taker: 4e14, sequencer: orderbook.MAX_SEQUENCER_FEE(), referralRebate:
    // 1e14});

    //     vm.expectEmit(address(orderbook));
    //     emit IOrderbook.OrderMatched(
    //         productId, maker, taker, OrderSide.LONG, makerOrder.nonce, takerOrder.nonce, size, price, fee,
    // isLiquidation
    //     );
    //     orderbook.matchOrders(productId, makerOrder, takerOrder, fee, isLiquidation);

    //     int128 expectedBaseAmount = int128(size);
    //     int128 expectedQuoteAmount = int128(size.mul18D(price));
    //     assertEq(
    //         abi.encode(perpEngine.getOpenPosition(productId, maker)),
    //         abi.encode(
    //             IPerpEngine.OpenPosition({
    //                 baseAmount: expectedBaseAmount,
    //                 quoteAmount: -expectedQuoteAmount - int128(fee.maker),
    //                 lastFunding: 0
    //             })
    //         )
    //     );
    //     assertEq(
    //         abi.encode(perpEngine.getOpenPosition(productId, taker)),
    //         abi.encode(
    //             IPerpEngine.OpenPosition({
    //                 baseAmount: -expectedBaseAmount,
    //                 quoteAmount: expectedQuoteAmount - int128(fee.taker + fee.sequencer),
    //                 lastFunding: 0
    //             })
    //         )
    //     );
    //     assertEq(spotEngine.getBalance(maker, token), 0);
    //     assertEq(spotEngine.getBalance(taker, token), 0);

    //     assertEq(orderbook.getCollectedSequencerFees(), fee.sequencer);
    //     assertEq(orderbook.getCollectedTradingFees(), fee.maker + fee.taker - fee.referralRebate);
    // }

    // TODO: test liquidation
    // function test_matchOrders_liquidation() public {
    //     vm.startPrank(exchange);

    //     bool isLiquidation = true;
    //     uint128 size = 4 * 1e18;
    //     uint128 price = 60_000 * 1e18;

    //     IOrderbook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
    //     IOrderbook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);

    //     IOrderbook.Fee memory fee =
    //         IOrderbook.Fee({maker: 2e14, taker: 4e14, sequencer: orderbook.MAX_SEQUENCER_FEE(), referralRebate:
    // 5e12});

    //     vm.expectEmit(address(orderbook));
    //     emit IOrderbook.OrderMatched(
    //         productId, maker, taker, OrderSide.LONG, makerOrder.nonce, takerOrder.nonce, size, price, fee,
    // isLiquidation
    //     );
    //     orderbook.matchOrders(productId, makerOrder, takerOrder, fee, isLiquidation);

    //     int128 expectedBaseAmount = int128(size);
    //     int128 expectedQuoteAmount = int128(size.mul18D(price));
    //     uint128 liquidationFee = uint128(expectedQuoteAmount).mul18D(orderbook.LIQUIDATION_FEE_RATE());
    //     assertEq(
    //         abi.encode(perpEngine.getOpenPosition(productId, maker)),
    //         abi.encode(
    //             IPerpEngine.OpenPosition({
    //                 baseAmount: expectedBaseAmount,
    //                 quoteAmount: -expectedQuoteAmount - int128(fee.maker),
    //                 lastFunding: 0
    //             })
    //         )
    //     );
    //     assertEq(
    //         abi.encode(perpEngine.getOpenPosition(productId, taker)),
    //         abi.encode(
    //             IPerpEngine.OpenPosition({
    //                 baseAmount: -expectedBaseAmount,
    //                 quoteAmount: expectedQuoteAmount - int128(fee.taker + fee.sequencer + liquidationFee),
    //                 lastFunding: 0
    //             })
    //         )
    //     );
    //     assertEq(spotEngine.getBalance(maker, token), 0);
    //     assertEq(spotEngine.getBalance(taker, token), 0);

    //     assertEq(orderbook.getCollectedSequencerFees(), fee.sequencer);
    //     assertEq(orderbook.getCollectedTradingFees(), fee.maker + fee.taker + liquidationFee - fee.referralRebate);
    // }

    function test_matchOrders_revertsWhenUnauthorized() public {
        LibOrder.SignedOrder memory makerOrder;
        LibOrder.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;
        (makerOrder, digest.maker) = _createLongOrder(maker, size, price, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createShortOrder(taker, size, price, takerNonce, isLiquidation);

        vm.expectRevert(bytes(NOT_SEQUENCER));
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, 0, IOrderBook.Fee(0, 0, 0));
    }

    function test_matchOrders_revertsIfBothOrdersAreLiquidated() public {
        vm.startPrank(exchange);

        LibOrder.SignedOrder memory makerOrder;
        LibOrder.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;

        bool isLiquidation = true;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;

        (makerOrder, digest.maker) = _createLongOrder(maker, size, price, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createLongOrder(taker, size, price, takerNonce, isLiquidation);
        vm.expectRevert(bytes(REQUIRE_ONE_LIQUIDATION_ORDER));
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, 0, IOrderBook.Fee(0, 0, 0));
    }

    function test_matchOrders_revertsWhenSameAccount() public {
        vm.startPrank(exchange);

        LibOrder.SignedOrder memory makerOrder;
        LibOrder.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;

        address account = makeAddr("account");
        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;
        (makerOrder, digest.maker) = _createLongOrder(account, size, price, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createShortOrder(account, size, price, takerNonce, isLiquidation);

        vm.expectRevert(bytes(DUPLICATE_ADDRESS));
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, 0, IOrderBook.Fee(0, 0, 0));
    }

    function test_matchOrders_revertsWhenSameSide() public {
        vm.startPrank(exchange);

        LibOrder.SignedOrder memory makerOrder;
        LibOrder.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;

        (makerOrder, digest.maker) = _createLongOrder(maker, size, price, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createLongOrder(taker, size, price, takerNonce, isLiquidation);
        vm.expectRevert(bytes(INVALID_MATCH_SIDE));
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, 0, IOrderBook.Fee(0, 0, 0));

        (makerOrder, digest.maker) = _createShortOrder(maker, size, price, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createShortOrder(taker, size, price, takerNonce, isLiquidation);
        vm.expectRevert(bytes(INVALID_MATCH_SIDE));
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, 0, IOrderBook.Fee(0, 0, 0));
    }

    function test_matchOrders_revertsWhenNonceUsed() public {
        vm.startPrank(exchange);

        LibOrder.SignedOrder memory fulfilledMakerOrder;
        LibOrder.SignedOrder memory fulfilledTakerOrder;
        IOrderBook.OrderHash memory digest;

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;
        (fulfilledMakerOrder, digest.maker) = _createLongOrder(maker, size, price, makerNonce, isLiquidation);
        (fulfilledTakerOrder, digest.taker) = _createShortOrder(taker, size, price, takerNonce, isLiquidation);
        orderbook.matchOrders(fulfilledMakerOrder, fulfilledTakerOrder, digest, productId, 0, IOrderBook.Fee(0, 0, 0));

        LibOrder.SignedOrder memory newTakerOrder;
        (newTakerOrder, digest.taker) = _createShortOrder(taker, size, price, makerNonce + 1, isLiquidation);
        vm.expectRevert(bytes(NONCE_USED));
        orderbook.matchOrders(fulfilledMakerOrder, newTakerOrder, digest, productId, 0, IOrderBook.Fee(0, 0, 0));

        LibOrder.SignedOrder memory newMakerOrder;
        (newMakerOrder, digest.maker) = _createLongOrder(maker, size, price, takerNonce + 1, isLiquidation);
        vm.expectRevert(bytes(NONCE_USED));
        orderbook.matchOrders(newMakerOrder, fulfilledTakerOrder, digest, productId, 0, IOrderBook.Fee(0, 0, 0));
    }

    function test_matchOrders_revertsIfExceededMaxTradingFees() public {
        vm.startPrank(exchange);

        LibOrder.SignedOrder memory makerOrder;
        LibOrder.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;

        bool isLiquidation = false;
        uint128 size = 5 * 1e18;
        uint128 price = 75_000 * 1e18;
        (makerOrder, digest.maker) = _createLongOrder(maker, size, price, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createShortOrder(taker, size, price, takerNonce, isLiquidation);

        int128 matchedQuoteAmount = int128(size).mul18D(int128(price));
        IOrderBook.Fee memory fee;

        fee.maker = matchedQuoteAmount.mul18D(MAX_MATCH_FEES) + 1;
        vm.expectRevert(bytes(INVALID_FEES));
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, 0, fee);

        fee.maker = 0;
        fee.taker = matchedQuoteAmount.mul18D(MAX_MATCH_FEES) + 1;
        vm.expectRevert(bytes(INVALID_FEES));
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, 0, fee);
    }

    function test_matchOrders_revertsIfExceededMaxSequencerFees() public {
        vm.startPrank(exchange);

        LibOrder.SignedOrder memory makerOrder;
        LibOrder.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;
        (makerOrder, digest.maker) = _createLongOrder(maker, size, price, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createShortOrder(taker, size, price, takerNonce, isLiquidation);

        uint128 takerSequencerFee = MAX_TAKER_SEQUENCER_FEE + 1;
        vm.expectRevert(bytes(INVALID_SEQUENCER_FEES));
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, takerSequencerFee, IOrderBook.Fee(0, 0, 0));
    }

    function _createLongOrder(
        address account,
        uint128 size,
        uint128 price,
        uint64 nonce,
        bool isLiquidation
    ) internal view returns (LibOrder.SignedOrder memory signedOrder, bytes32 orderHash) {
        LibOrder.Order memory order = LibOrder.Order({
            sender: account,
            size: size,
            price: price,
            nonce: nonce,
            productIndex: productId,
            orderSide: OrderSide.BUY
        });
        signedOrder = LibOrder.SignedOrder({order: order, signature: "", signer: account, isLiquidation: isLiquidation});
        orderHash = keccak256(abi.encode(account, size, price, nonce, OrderSide.BUY));
    }

    function _createShortOrder(
        address account,
        uint128 size,
        uint128 price,
        uint64 nonce,
        bool isLiquidation
    ) internal view returns (LibOrder.SignedOrder memory signedOrder, bytes32 orderHash) {
        LibOrder.Order memory order = LibOrder.Order({
            sender: account,
            size: size,
            price: price,
            nonce: nonce,
            productIndex: productId,
            orderSide: OrderSide.SELL
        });
        signedOrder = LibOrder.SignedOrder({order: order, signature: "", signer: account, isLiquidation: isLiquidation});
        orderHash = keccak256(abi.encode(account, size, price, nonce, OrderSide.SELL));
    }
}

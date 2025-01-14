// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {ClearingService} from "contracts/exchange/ClearingService.sol";
import {IOrderBook, OrderBook} from "contracts/exchange/OrderBook.sol";
import {IPerp, Perp} from "contracts/exchange/Perp.sol";
import {Spot} from "contracts/exchange/Spot.sol";
import {Access} from "contracts/exchange/access/Access.sol";
import {Errors} from "contracts/exchange/lib/Errors.sol";
import {MathHelper} from "contracts/exchange/lib/MathHelper.sol";
import {Percentage} from "contracts/exchange/lib/Percentage.sol";
import {OrderLogic} from "contracts/exchange/lib/logic/OrderLogic.sol";
import {
    MAX_LIQUIDATION_FEE_RATE,
    MAX_MATCH_FEE_RATE,
    MAX_TAKER_SEQUENCER_FEE
} from "contracts/exchange/share/Constants.sol";

contract OrderbookTest is Test {
    using MathHelper for uint128;
    using MathHelper for int128;
    using Percentage for uint128;
    using stdStorage for StdStorage;

    address private exchange = makeAddr("exchange");
    address private token = makeAddr("token");

    uint8 private productId = 0;
    address private maker = makeAddr("maker");
    uint64 private makerNonce = 1;
    address private taker = makeAddr("taker");
    uint64 private takerNonce = 2;

    Access private access;
    Perp private perpEngine;
    Spot private spotEngine;
    ClearingService private clearingService;
    OrderBook private orderbook;

    function setUp() public {
        access = new Access();
        stdstore.target(address(access)).sig("hasRole(bytes32,address)").with_key(access.ADMIN_ROLE()).with_key(
            address(this)
        ).checked_write(true);

        access.setExchange(exchange);

        spotEngine = new Spot();
        stdstore.target(address(spotEngine)).sig("access()").checked_write(address(access));

        perpEngine = new Perp();
        stdstore.target(address(perpEngine)).sig("access()").checked_write(address(access));

        clearingService = new ClearingService();
        stdstore.target(address(clearingService)).sig("access()").checked_write(address(access));

        orderbook = new OrderBook();
        stdstore.target(address(orderbook)).sig("clearingService()").checked_write(address(clearingService));
        stdstore.target(address(orderbook)).sig("perpEngine()").checked_write(address(perpEngine));
        stdstore.target(address(orderbook)).sig("spotEngine()").checked_write(address(spotEngine));
        stdstore.target(address(orderbook)).sig("access()").checked_write(address(access));
        stdstore.target(address(orderbook)).sig("getCollateralToken()").checked_write(token);

        access.setOrderBook(address(orderbook));
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
        vm.expectRevert(Errors.Unauthorized.selector);
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
        vm.expectRevert(Errors.Unauthorized.selector);
        orderbook.claimTradingFees();
    }

    function test_matchOrders_makerGoLong() public {
        vm.startPrank(exchange);

        OrderLogic.SignedOrder memory makerOrder;
        OrderLogic.SignedOrder memory takerOrder;
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
            abi.encode(perpEngine.getOpenPosition(maker, productId)),
            abi.encode(IPerp.Balance(expectedBaseAmount, -expectedQuoteAmount, 0))
        );
        assertEq(
            abi.encode(perpEngine.getOpenPosition(taker, productId)),
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

        OrderLogic.SignedOrder memory makerOrder;
        OrderLogic.SignedOrder memory takerOrder;
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
            abi.encode(perpEngine.getOpenPosition(maker, productId)),
            abi.encode(IPerp.Balance(-expectedBaseAmount, expectedQuoteAmount, 0))
        );
        assertEq(
            abi.encode(perpEngine.getOpenPosition(taker, productId)),
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
        OrderLogic.SignedOrder memory makerOrder;
        OrderLogic.SignedOrder memory takerOrder;
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

        assertEq(abi.encode(perpEngine.getOpenPosition(maker, productId)), abi.encode(IPerp.Balance(0, 0, 0)));
        assertEq(abi.encode(perpEngine.getOpenPosition(taker, productId)), abi.encode(IPerp.Balance(0, 0, 0)));

        int128 pnl = int128(size).mul18D(int128(closePositionPrice - openPositionPrice));
        assertEq(spotEngine.getBalance(token, maker), pnl);
        assertEq(spotEngine.getBalance(token, taker), -pnl);
    }

    function test_matchOrders_closeHalfPosition_settlePnl() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        OrderLogic.SignedOrder memory makerOrder;
        OrderLogic.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;
        IOrderBook.Fee memory fee;
        uint128 takerSequencerFee;

        uint128 price = 75_000 * 1e18;

        uint128 openSize = 5 * 1e18;
        (makerOrder, digest.maker) = _createLongOrder(maker, openSize, price, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createShortOrder(taker, openSize, price, takerNonce, isLiquidation);
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, takerSequencerFee, fee);

        uint128 closeSize = 2 * 1e18;
        (makerOrder, digest.maker) = _createShortOrder(maker, closeSize, price, makerNonce + 1, isLiquidation);
        (takerOrder, digest.taker) = _createLongOrder(taker, closeSize, price, takerNonce + 1, isLiquidation);
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, takerSequencerFee, fee);

        int128 expectedBaseAmount = int128(openSize - closeSize);
        int128 expectedQuoteAmount = expectedBaseAmount.mul18D(int128(price));
        assertEq(
            abi.encode(perpEngine.getOpenPosition(maker, productId)),
            abi.encode(IPerp.Balance(expectedBaseAmount, -expectedQuoteAmount, 0))
        );
        assertEq(
            abi.encode(perpEngine.getOpenPosition(taker, productId)),
            abi.encode(IPerp.Balance(-expectedBaseAmount, expectedQuoteAmount, 0))
        );

        assertEq(spotEngine.getBalance(maker, token), 0);
        assertEq(spotEngine.getBalance(taker, token), 0);
    }

    function test_matchOrders_changePosition_settlePnl() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        OrderLogic.SignedOrder memory makerOrder;
        OrderLogic.SignedOrder memory takerOrder;
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
            abi.encode(perpEngine.getOpenPosition(maker, productId)),
            abi.encode(IPerp.Balance(-expectedBaseAmount, expectedQuoteAmount, 0))
        );
        assertEq(
            abi.encode(perpEngine.getOpenPosition(taker, productId)),
            abi.encode(IPerp.Balance(expectedBaseAmount, -expectedQuoteAmount, 0))
        );

        int128 pnl = int128(size1 - size0).mul18D(int128(price1 - price0));
        assertEq(spotEngine.getBalance(token, maker), pnl);
        assertEq(spotEngine.getBalance(token, taker), -pnl);
    }

    function test_matchOrders_withOrderFees() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;

        OrderLogic.SignedOrder memory makerOrder;
        OrderLogic.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;
        IOrderBook.Fee memory fee =
            IOrderBook.Fee({maker: 2e14, taker: 4e14, referralRebate: 5e12, liquidationPenalty: 5e14});
        uint128 takerSequencerFee = 1e14;

        (makerOrder, digest.maker) = _createLongOrder(maker, size, price, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createShortOrder(taker, size, price, takerNonce, isLiquidation);
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, takerSequencerFee, fee);

        int128 expectedBaseAmount = int128(size);
        int128 expectedQuoteAmount = expectedBaseAmount.mul18D(int128(price));
        assertEq(
            abi.encode(perpEngine.getOpenPosition(maker, productId)),
            abi.encode(IPerp.Balance(expectedBaseAmount, -expectedQuoteAmount - fee.maker, 0))
        );
        assertEq(
            abi.encode(perpEngine.getOpenPosition(taker, productId)),
            abi.encode(
                IPerp.Balance(-expectedBaseAmount, expectedQuoteAmount - fee.taker - int128(takerSequencerFee), 0)
            )
        );
        assertEq(spotEngine.getBalance(token, maker), 0);
        assertEq(spotEngine.getBalance(token, taker), 0);

        assertEq(orderbook.getSequencerFees(), int128(takerSequencerFee));
        assertEq(orderbook.getTradingFees(), fee.maker + fee.taker - int128(fee.referralRebate));

        assertEq(orderbook.isMatched(maker, makerNonce, taker, takerNonce), true);
    }

    function test_matchOrders_liquidation() public {
        vm.startPrank(exchange);

        bool isLiquidation = true;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;

        OrderLogic.SignedOrder memory makerOrder;
        OrderLogic.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;
        IOrderBook.Fee memory fee =
            IOrderBook.Fee({maker: 2e14, taker: 4e14, referralRebate: 5e12, liquidationPenalty: 5e14});
        uint128 takerSequencerFee = 1e14;

        (makerOrder, digest.maker) = _createLongOrder(maker, size, price, makerNonce, !isLiquidation);
        (takerOrder, digest.taker) = _createShortOrder(taker, size, price, takerNonce, isLiquidation);
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, takerSequencerFee, fee);

        int128 expectedBaseAmount = int128(size);
        int128 expectedQuoteAmount = expectedBaseAmount.mul18D(int128(price));
        uint128 liquidationFee = fee.liquidationPenalty;
        assertEq(
            abi.encode(perpEngine.getOpenPosition(maker, productId)),
            abi.encode(IPerp.Balance(expectedBaseAmount, -expectedQuoteAmount - fee.maker, 0))
        );
        assertEq(
            abi.encode(perpEngine.getOpenPosition(taker, productId)),
            abi.encode(
                IPerp.Balance(
                    -expectedBaseAmount,
                    expectedQuoteAmount - fee.taker - int128(takerSequencerFee) - int128(liquidationFee),
                    0
                )
            )
        );
        assertEq(spotEngine.getBalance(token, maker), 0);
        assertEq(spotEngine.getBalance(token, taker), 0);

        assertEq(orderbook.getSequencerFees(), int128(takerSequencerFee));
        assertEq(orderbook.getTradingFees(), fee.maker + fee.taker - int128(fee.referralRebate));
        assertEq(clearingService.getInsuranceFundBalance(), liquidationFee);

        assertEq(orderbook.isMatched(maker, makerNonce, taker, takerNonce), true);
    }

    function test_matchOrders_liquidation_revertsIfExceedMaxLiquidationFee() public {
        vm.startPrank(exchange);

        bool isLiquidation = true;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;

        assertEq(MAX_LIQUIDATION_FEE_RATE, (10 * uint256(Percentage.ONE_HUNDRED_PERCENT)) / 100);

        OrderLogic.SignedOrder memory makerOrder;
        OrderLogic.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;
        IOrderBook.Fee memory fee = IOrderBook.Fee({
            maker: 2e14,
            taker: 4e14,
            referralRebate: 5e12,
            liquidationPenalty: size.mul18D(price).calculatePercentage(MAX_LIQUIDATION_FEE_RATE) + 1
        });
        uint128 takerSequencerFee = 1e14;

        (makerOrder, digest.maker) = _createLongOrder(maker, size, price, makerNonce, !isLiquidation);
        (takerOrder, digest.taker) = _createShortOrder(taker, size, price, takerNonce, isLiquidation);

        vm.expectRevert(Errors.Orderbook_ExceededMaxLiquidationFee.selector);
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, takerSequencerFee, fee);
    }

    function test_matchOrders_revertsWhenUnauthorized() public {
        OrderLogic.SignedOrder memory makerOrder;
        OrderLogic.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;
        IOrderBook.Fee memory fee;

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;
        (makerOrder, digest.maker) = _createLongOrder(maker, size, price, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createShortOrder(taker, size, price, takerNonce, isLiquidation);

        vm.expectRevert(Errors.Unauthorized.selector);
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, 0, fee);
    }

    function test_matchOrders_revertsWhenSameAccount() public {
        vm.startPrank(exchange);

        OrderLogic.SignedOrder memory makerOrder;
        OrderLogic.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;
        IOrderBook.Fee memory fee;

        address account = makeAddr("account");
        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;
        (makerOrder, digest.maker) = _createLongOrder(account, size, price, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createShortOrder(account, size, price, takerNonce, isLiquidation);

        vm.expectRevert(Errors.Orderbook_OrdersWithSameAccounts.selector);
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, 0, fee);
    }

    function test_matchOrders_revertsWhenSameSide() public {
        vm.startPrank(exchange);

        OrderLogic.SignedOrder memory makerOrder;
        OrderLogic.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;
        IOrderBook.Fee memory fee;

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;

        (makerOrder, digest.maker) = _createLongOrder(maker, size, price, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createLongOrder(taker, size, price, takerNonce, isLiquidation);
        vm.expectRevert(Errors.Orderbook_OrdersWithSameSides.selector);
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, 0, fee);

        (makerOrder, digest.maker) = _createShortOrder(maker, size, price, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createShortOrder(taker, size, price, takerNonce, isLiquidation);
        vm.expectRevert(Errors.Orderbook_OrdersWithSameSides.selector);
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, 0, fee);
    }

    function test_matchOrders_revertsWhenNonceUsed() public {
        vm.startPrank(exchange);

        OrderLogic.SignedOrder memory fulfilledMakerOrder;
        OrderLogic.SignedOrder memory fulfilledTakerOrder;
        IOrderBook.OrderHash memory digest;
        IOrderBook.Fee memory fee;

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;
        (fulfilledMakerOrder, digest.maker) = _createLongOrder(maker, size, price, makerNonce, isLiquidation);
        (fulfilledTakerOrder, digest.taker) = _createShortOrder(taker, size, price, takerNonce, isLiquidation);
        orderbook.matchOrders(fulfilledMakerOrder, fulfilledTakerOrder, digest, productId, 0, fee);

        OrderLogic.SignedOrder memory newTakerOrder;
        (newTakerOrder, digest.taker) = _createShortOrder(taker, size, price, makerNonce + 1, isLiquidation);
        vm.expectRevert(abi.encodeWithSelector(Errors.Orderbook_NonceUsed.selector, maker, makerNonce));
        orderbook.matchOrders(fulfilledMakerOrder, newTakerOrder, digest, productId, 0, fee);

        OrderLogic.SignedOrder memory newMakerOrder;
        (newMakerOrder, digest.maker) = _createLongOrder(maker, size, price, takerNonce + 1, isLiquidation);
        vm.expectRevert(abi.encodeWithSelector(Errors.Orderbook_NonceUsed.selector, taker, takerNonce));
        orderbook.matchOrders(newMakerOrder, fulfilledTakerOrder, digest, productId, 0, fee);
    }

    function test_matchOrders_revertsIfInvalidPrice() public {
        vm.startPrank(exchange);

        OrderLogic.SignedOrder memory makerOrder;
        OrderLogic.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;
        IOrderBook.Fee memory fee;

        bool isLiquidation = false;
        uint128 size = 5 * 1e18;
        uint128 price = 75_000 * 1e18;

        uint128 makerPrice = price;
        uint128 takerPrice = price + 1;
        (makerOrder, digest.maker) = _createLongOrder(maker, size, makerPrice, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createShortOrder(taker, size, takerPrice, takerNonce, isLiquidation);
        vm.expectRevert(Errors.Orderbook_InvalidOrderPrice.selector);
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, 0, fee);

        makerPrice = price;
        takerPrice = price - 1;
        (makerOrder, digest.maker) = _createShortOrder(maker, size, makerPrice, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createLongOrder(taker, size, takerPrice, takerNonce, isLiquidation);
        vm.expectRevert(Errors.Orderbook_InvalidOrderPrice.selector);
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, 0, fee);
    }

    function test_matchOrders_revertsIfExceededMaxTradingFees() public {
        vm.startPrank(exchange);

        OrderLogic.SignedOrder memory makerOrder;
        OrderLogic.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;

        bool isLiquidation = false;
        uint128 size = 5 * 1e18;
        uint128 price = 75_000 * 1e18;
        (makerOrder, digest.maker) = _createLongOrder(maker, size, price, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createShortOrder(taker, size, price, takerNonce, isLiquidation);

        uint128 matchedQuoteAmount = size.mul18D(price);
        IOrderBook.Fee memory fee;

        assertEq(MAX_MATCH_FEE_RATE, (2 * uint256(Percentage.ONE_HUNDRED_PERCENT)) / 100);

        fee.maker = int128(matchedQuoteAmount.calculatePercentage(MAX_MATCH_FEE_RATE) + 1);
        vm.expectRevert(Errors.Orderbook_ExceededMaxTradingFee.selector);
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, 0, fee);

        fee.maker = 0;
        fee.taker = int128(matchedQuoteAmount.calculatePercentage(MAX_MATCH_FEE_RATE)) + 1;
        vm.expectRevert(Errors.Orderbook_ExceededMaxTradingFee.selector);
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, 0, fee);
    }

    function test_matchOrders_revertsIfExceededMaxSequencerFees() public {
        vm.startPrank(exchange);

        OrderLogic.SignedOrder memory makerOrder;
        OrderLogic.SignedOrder memory takerOrder;
        IOrderBook.OrderHash memory digest;
        IOrderBook.Fee memory fee;

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;
        (makerOrder, digest.maker) = _createLongOrder(maker, size, price, makerNonce, isLiquidation);
        (takerOrder, digest.taker) = _createShortOrder(taker, size, price, takerNonce, isLiquidation);

        uint128 takerSequencerFee = MAX_TAKER_SEQUENCER_FEE + 1;
        vm.expectRevert(Errors.Orderbook_ExceededMaxSequencerFee.selector);
        orderbook.matchOrders(makerOrder, takerOrder, digest, productId, takerSequencerFee, fee);
    }

    function _createLongOrder(address account, uint128 size, uint128 price, uint64 nonce, bool isLiquidation)
        internal
        view
        returns (OrderLogic.SignedOrder memory signedOrder, bytes32 orderHash)
    {
        OrderLogic.Order memory order = OrderLogic.Order({
            sender: account,
            size: size,
            price: price,
            nonce: nonce,
            productIndex: productId,
            orderSide: OrderLogic.OrderSide.BUY
        });
        signedOrder =
            OrderLogic.SignedOrder({order: order, signature: "", signer: account, isLiquidation: isLiquidation});
        orderHash = keccak256(abi.encode(account, size, price, nonce, OrderLogic.OrderSide.BUY));
    }

    function _createShortOrder(address account, uint128 size, uint128 price, uint64 nonce, bool isLiquidation)
        internal
        view
        returns (OrderLogic.SignedOrder memory signedOrder, bytes32 orderHash)
    {
        OrderLogic.Order memory order = OrderLogic.Order({
            sender: account,
            size: size,
            price: price,
            nonce: nonce,
            productIndex: productId,
            orderSide: OrderLogic.OrderSide.SELL
        });
        signedOrder =
            OrderLogic.SignedOrder({order: order, signature: "", signer: account, isLiquidation: isLiquidation});
        orderHash = keccak256(abi.encode(account, size, price, nonce, OrderLogic.OrderSide.SELL));
    }
}

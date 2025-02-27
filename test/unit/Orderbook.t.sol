// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {ClearingService, IClearingService} from "contracts/exchange/ClearingService.sol";
import {IOrderBook, OrderBook} from "contracts/exchange/OrderBook.sol";
import {IPerp, Perp} from "contracts/exchange/Perp.sol";
import {ISpot, Spot} from "contracts/exchange/Spot.sol";
import {Access} from "contracts/exchange/access/Access.sol";
import {Errors} from "contracts/exchange/lib/Errors.sol";
import {MathHelper} from "contracts/exchange/lib/MathHelper.sol";
import {Percentage} from "contracts/exchange/lib/Percentage.sol";
import {
    BSX_ORACLE,
    BSX_TOKEN,
    MAX_LIQUIDATION_FEE_RATE,
    MAX_TAKER_SEQUENCER_FEE_IN_USD,
    MAX_TRADING_FEE_RATE
} from "contracts/exchange/share/Constants.sol";
import {IBsxOracle} from "contracts/misc/interfaces/IBsxOracle.sol";

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

    uint256 private constant BSX_PRICE_IN_USD = 0.05 ether;

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

        vm.mockCall(
            address(BSX_ORACLE),
            abi.encodeWithSelector(IBsxOracle.getTokenPriceInUsd.selector, BSX_TOKEN),
            abi.encode(0.05 ether)
        );
    }

    function test_claimSequencerFees() public {
        vm.startPrank(exchange);

        IOrderBook.FeeCollection memory sequencerFees;
        sequencerFees.inUSDC = 100 * 1e18;
        sequencerFees.inBSX = 50 * 1e18;
        vm.store(
            address(orderbook),
            bytes32(uint256(9)),
            bytes32(abi.encodePacked(sequencerFees.inBSX, sequencerFees.inUSDC))
        );

        assertEq(abi.encode(orderbook.claimSequencerFees()), abi.encode(sequencerFees));
        assertEq(abi.encode(orderbook.getSequencerFees()), abi.encode(IOrderBook.FeeCollection(0, 0)));
    }

    function test_claimSequencerFees_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        orderbook.claimSequencerFees();
    }

    function test_claimCollectedTradingFees() public {
        vm.startPrank(exchange);

        IOrderBook.FeeCollection memory tradingFees;
        tradingFees.inUSDC = 100 * 1e18;
        tradingFees.inBSX = 50 * 1e18;
        vm.store(
            address(orderbook), bytes32(uint256(6)), bytes32(abi.encodePacked(tradingFees.inBSX, tradingFees.inUSDC))
        );

        assertEq(abi.encode(orderbook.claimTradingFees()), abi.encode(tradingFees));
        assertEq(abi.encode(orderbook.getTradingFees()), abi.encode(IOrderBook.FeeCollection(0, 0)));
    }

    function test_claimCollectedTradingFee_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        orderbook.claimTradingFees();
    }

    function test_matchOrders_makerGoLong() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;
        IOrderBook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderBook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);

        IOrderBook.Fees memory fees;

        vm.expectEmit(address(orderbook));
        emit IOrderBook.OrderMatched(
            productId,
            maker,
            taker,
            makerOrder.orderSide,
            makerOrder.nonce,
            takerOrder.nonce,
            size,
            price,
            fees,
            isLiquidation
        );
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);

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

        IOrderBook.FeeCollection memory tradingFees = orderbook.getTradingFees();
        IOrderBook.FeeCollection memory sequencerFees = orderbook.getSequencerFees();
        assertEq(tradingFees.inUSDC, 0);
        assertEq(sequencerFees.inUSDC, 0);

        assertEq(orderbook.isMatched(maker, makerNonce, taker, takerNonce), true);
    }

    function test_matchOrders_makerGoShort() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;
        IOrderBook.Order memory makerOrder = _createShortOrder(maker, size, price, makerNonce);
        IOrderBook.Order memory takerOrder = _createLongOrder(taker, size, price, takerNonce);

        IOrderBook.Fees memory fees;

        vm.expectEmit(address(orderbook));
        emit IOrderBook.OrderMatched(
            productId,
            maker,
            taker,
            makerOrder.orderSide,
            makerOrder.nonce,
            takerOrder.nonce,
            size,
            price,
            fees,
            isLiquidation
        );
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);

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

        IOrderBook.FeeCollection memory tradingFees = orderbook.getTradingFees();
        IOrderBook.FeeCollection memory sequencerFees = orderbook.getSequencerFees();
        assertEq(tradingFees.inUSDC, 0);
        assertEq(sequencerFees.inUSDC, 0);

        assertEq(orderbook.isMatched(maker, makerNonce, taker, takerNonce), true);
    }

    function test_matchOrders_closePosition_settlePnl() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        IOrderBook.Fees memory fees;

        uint128 openPositionPrice = 75_000 * 1e18;
        IOrderBook.Order memory makerOrder = _createLongOrder(maker, size, openPositionPrice, makerNonce);
        IOrderBook.Order memory takerOrder = _createShortOrder(taker, size, openPositionPrice, takerNonce);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);

        uint128 closePositionPrice = 80_000 * 1e18;
        makerOrder = _createShortOrder(maker, size, closePositionPrice, makerNonce + 1);
        takerOrder = _createLongOrder(taker, size, closePositionPrice, takerNonce + 1);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);

        assertEq(abi.encode(perpEngine.getOpenPosition(maker, productId)), abi.encode(IPerp.Balance(0, 0, 0)));
        assertEq(abi.encode(perpEngine.getOpenPosition(taker, productId)), abi.encode(IPerp.Balance(0, 0, 0)));

        int128 pnl = int128(size).mul18D(int128(closePositionPrice - openPositionPrice));
        assertEq(spotEngine.getBalance(token, maker), pnl);
        assertEq(spotEngine.getBalance(token, taker), -pnl);
    }

    function test_matchOrders_closeHalfPosition_settlePnl() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;

        IOrderBook.Fees memory fees;

        uint128 price = 75_000 * 1e18;

        uint128 openSize = 5 * 1e18;
        IOrderBook.Order memory makerOrder = _createLongOrder(maker, openSize, price, makerNonce);
        IOrderBook.Order memory takerOrder = _createShortOrder(taker, openSize, price, takerNonce);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);

        uint128 closeSize = 2 * 1e18;
        makerOrder = _createShortOrder(maker, closeSize, price, makerNonce + 1);
        takerOrder = _createLongOrder(taker, closeSize, price, takerNonce + 1);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);

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

        IOrderBook.Fees memory fees;

        uint128 size0 = 2 * 1e18;
        uint128 price0 = 40_000 * 1e18;
        IOrderBook.Order memory makerOrder = _createLongOrder(maker, size0, price0, makerNonce);
        IOrderBook.Order memory takerOrder = _createShortOrder(taker, size0, price0, takerNonce);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);

        uint128 size1 = 4 * 1e18;
        uint128 price1 = 80_000 * 1e18;
        makerOrder = _createShortOrder(maker, size1, price1, makerNonce + 1);
        takerOrder = _createLongOrder(taker, size1, price1, takerNonce + 1);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);

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

        IOrderBook.Fees memory fees;
        fees.maker = 2e14;
        fees.taker = 4e14;
        fees.makerReferralRebate = 2e12;
        fees.takerReferralRebate = 4e12;
        fees.liquidation = 5e14;
        fees.sequencer = 1e14;

        IOrderBook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderBook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);

        int128 expectedBaseAmount = int128(size);
        int128 expectedQuoteAmount = expectedBaseAmount.mul18D(int128(price));
        assertEq(
            abi.encode(perpEngine.getOpenPosition(maker, productId)),
            abi.encode(IPerp.Balance(expectedBaseAmount, -expectedQuoteAmount - fees.maker, 0))
        );
        assertEq(
            abi.encode(perpEngine.getOpenPosition(taker, productId)),
            abi.encode(IPerp.Balance(-expectedBaseAmount, expectedQuoteAmount - fees.taker - int128(fees.sequencer), 0))
        );
        assertEq(spotEngine.getBalance(token, maker), 0);
        assertEq(spotEngine.getBalance(token, taker), 0);

        IOrderBook.FeeCollection memory tradingFees = orderbook.getTradingFees();
        IOrderBook.FeeCollection memory sequencerFees = orderbook.getSequencerFees();
        assertEq(
            tradingFees.inUSDC,
            fees.maker + fees.taker - int128(fees.makerReferralRebate) - int128(fees.takerReferralRebate)
        );
        assertEq(sequencerFees.inUSDC, int128(fees.sequencer));

        assertEq(orderbook.isMatched(maker, makerNonce, taker, takerNonce), true);
    }

    function test_matchOrders_withBsxFees_succeeds() public {
        vm.startPrank(exchange);

        int256 initBsxBalance = 1000 ether;
        spotEngine.updateBalance(maker, BSX_TOKEN, initBsxBalance);
        spotEngine.updateBalance(taker, BSX_TOKEN, initBsxBalance);

        bool isLiquidation = true;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;

        IOrderBook.Fees memory fees;
        fees.makerReferralRebate = 2e12;
        fees.takerReferralRebate = 4e12;
        fees.liquidation = 5e14;
        fees.isMakerFeeInBSX = true;
        fees.isTakerFeeInBSX = true;

        uint128 matchedQuoteAmount = size.mul18D(price);
        uint256 bsxFeeMultiplier = 10;
        uint256 maxTradingFeeInBsx = bsxFeeMultiplier
            * uint256(matchedQuoteAmount.calculatePercentage(MAX_TRADING_FEE_RATE)) * 1e18 / BSX_PRICE_IN_USD;
        uint256 maxSequencerFeeInBsx = bsxFeeMultiplier * MAX_TAKER_SEQUENCER_FEE_IN_USD * 1e18 / BSX_PRICE_IN_USD;

        fees.maker = int128(uint128(maxTradingFeeInBsx));
        fees.taker = int128(uint128(maxTradingFeeInBsx));
        fees.sequencer = uint128(maxSequencerFeeInBsx);

        IOrderBook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderBook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);

        vm.expectEmit(address(orderbook));
        emit IOrderBook.OrderMatched(
            productId,
            maker,
            taker,
            makerOrder.orderSide,
            makerOrder.nonce,
            takerOrder.nonce,
            size,
            price,
            fees,
            isLiquidation
        );
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);

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

        IClearingService.InsuranceFund memory insuranceFund = clearingService.getInsuranceFundBalance();
        assertEq(insuranceFund.inUSDC, 0);
        assertEq(insuranceFund.inBSX, fees.liquidation);

        assertEq(
            abi.encode(spotEngine.balance(maker, BSX_TOKEN)), abi.encode(ISpot.Balance(initBsxBalance - fees.maker))
        );
        assertEq(
            abi.encode(spotEngine.balance(taker, BSX_TOKEN)),
            abi.encode(ISpot.Balance(initBsxBalance - fees.taker - int128(fees.sequencer) - int128(fees.liquidation)))
        );

        assertEq(spotEngine.getBalance(token, maker), 0);
        assertEq(spotEngine.getBalance(token, taker), 0);

        IOrderBook.FeeCollection memory sequencerFees = orderbook.getSequencerFees();
        assertEq(sequencerFees.inUSDC, 0);
        assertEq(sequencerFees.inBSX, int128(fees.sequencer));

        IOrderBook.FeeCollection memory tradingFees = orderbook.getTradingFees();
        assertEq(tradingFees.inUSDC, 0);
        assertEq(
            tradingFees.inBSX,
            fees.maker + fees.taker - int128(fees.makerReferralRebate) - int128(fees.takerReferralRebate)
        );

        assertEq(orderbook.isMatched(maker, makerNonce, taker, takerNonce), true);
    }

    function test_matchOrders_onlyMakerFeesInBsx() public {
        vm.startPrank(exchange);

        int256 initBsxBalance = 1000 ether;
        spotEngine.updateBalance(maker, BSX_TOKEN, initBsxBalance);

        bool isLiquidation = true;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;

        IOrderBook.Fees memory fees;
        fees.maker = 2e14;
        fees.taker = 4e14;
        fees.makerReferralRebate = 2e12;
        fees.takerReferralRebate = 4e12;
        fees.liquidation = 5e14;
        fees.sequencer = 1e14;
        fees.isMakerFeeInBSX = true;
        fees.isTakerFeeInBSX = false;

        IOrderBook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderBook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);

        vm.expectEmit(address(orderbook));
        emit IOrderBook.OrderMatched(
            productId,
            maker,
            taker,
            makerOrder.orderSide,
            makerOrder.nonce,
            takerOrder.nonce,
            size,
            price,
            fees,
            isLiquidation
        );
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);

        int128 expectedBaseAmount = int128(size);
        int128 expectedQuoteAmount = expectedBaseAmount.mul18D(int128(price));
        assertEq(
            abi.encode(perpEngine.getOpenPosition(maker, productId)),
            abi.encode(IPerp.Balance(expectedBaseAmount, -expectedQuoteAmount, 0))
        );
        assertEq(
            abi.encode(perpEngine.getOpenPosition(taker, productId)),
            abi.encode(
                IPerp.Balance(
                    -expectedBaseAmount,
                    expectedQuoteAmount - int128(fees.liquidation) - int128(fees.sequencer) - fees.taker,
                    0
                )
            )
        );

        assertEq(
            abi.encode(spotEngine.balance(maker, BSX_TOKEN)), abi.encode(ISpot.Balance(initBsxBalance - fees.maker))
        );
        assertEq(abi.encode(spotEngine.balance(taker, BSX_TOKEN)), abi.encode(ISpot.Balance(0)));

        IClearingService.InsuranceFund memory insuranceFund = clearingService.getInsuranceFundBalance();
        assertEq(insuranceFund.inUSDC, fees.liquidation);
        assertEq(insuranceFund.inBSX, 0);

        assertEq(spotEngine.getBalance(token, maker), 0);
        assertEq(spotEngine.getBalance(token, taker), 0);

        IOrderBook.FeeCollection memory sequencerFees = orderbook.getSequencerFees();
        assertEq(sequencerFees.inUSDC, int128(fees.sequencer));
        assertEq(sequencerFees.inBSX, 0);

        IOrderBook.FeeCollection memory tradingFees = orderbook.getTradingFees();
        assertEq(tradingFees.inUSDC, fees.taker - int128(fees.takerReferralRebate));
        assertEq(tradingFees.inBSX, fees.maker - int128(fees.makerReferralRebate));

        assertEq(orderbook.isMatched(maker, makerNonce, taker, takerNonce), true);
    }

    function test_matchOrders_onlyTakerFeesInBsx() public {
        vm.startPrank(exchange);

        int256 initBsxBalance = 1000 ether;
        spotEngine.updateBalance(taker, BSX_TOKEN, initBsxBalance);

        bool isLiquidation = true;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;

        IOrderBook.Fees memory fees;
        fees.maker = 2e14;
        fees.taker = 4e14;
        fees.makerReferralRebate = 2e12;
        fees.takerReferralRebate = 4e12;
        fees.liquidation = 5e14;
        fees.sequencer = 1e14;
        fees.isMakerFeeInBSX = false;
        fees.isTakerFeeInBSX = true;

        IOrderBook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderBook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);

        vm.expectEmit(address(orderbook));
        emit IOrderBook.OrderMatched(
            productId,
            maker,
            taker,
            makerOrder.orderSide,
            makerOrder.nonce,
            takerOrder.nonce,
            size,
            price,
            fees,
            isLiquidation
        );
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);

        int128 expectedBaseAmount = int128(size);
        int128 expectedQuoteAmount = expectedBaseAmount.mul18D(int128(price));
        assertEq(
            abi.encode(perpEngine.getOpenPosition(maker, productId)),
            abi.encode(IPerp.Balance(expectedBaseAmount, -expectedQuoteAmount - fees.maker, 0))
        );
        assertEq(
            abi.encode(perpEngine.getOpenPosition(taker, productId)),
            abi.encode(IPerp.Balance(-expectedBaseAmount, expectedQuoteAmount, 0))
        );

        assertEq(abi.encode(spotEngine.balance(maker, BSX_TOKEN)), abi.encode(ISpot.Balance(0)));
        assertEq(
            abi.encode(spotEngine.balance(taker, BSX_TOKEN)),
            abi.encode(ISpot.Balance(initBsxBalance - fees.taker - int128(fees.sequencer) - int128(fees.liquidation)))
        );

        IClearingService.InsuranceFund memory insuranceFund = clearingService.getInsuranceFundBalance();
        assertEq(insuranceFund.inUSDC, 0);
        assertEq(insuranceFund.inBSX, fees.liquidation);

        assertEq(spotEngine.getBalance(token, maker), 0);
        assertEq(spotEngine.getBalance(token, taker), 0);

        IOrderBook.FeeCollection memory sequencerFees = orderbook.getSequencerFees();
        assertEq(sequencerFees.inUSDC, 0);
        assertEq(sequencerFees.inBSX, int128(fees.sequencer));

        IOrderBook.FeeCollection memory tradingFees = orderbook.getTradingFees();
        assertEq(tradingFees.inUSDC, fees.maker - int128(fees.makerReferralRebate));
        assertEq(tradingFees.inBSX, fees.taker - int128(fees.takerReferralRebate));

        assertEq(orderbook.isMatched(maker, makerNonce, taker, takerNonce), true);
    }

    function test_matchOrders_withBsxFees_revertsIfExceededMaxSequencerFee() public {
        vm.startPrank(exchange);

        int256 initBsxBalance = 1000 ether;
        spotEngine.updateBalance(maker, BSX_TOKEN, initBsxBalance);
        spotEngine.updateBalance(taker, BSX_TOKEN, initBsxBalance);

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;

        IOrderBook.Fees memory fees;
        fees.maker = 2e14;
        fees.taker = 4e14;
        fees.liquidation = 5e14;
        fees.sequencer = 1e14;
        fees.isMakerFeeInBSX = true;
        fees.isTakerFeeInBSX = true;

        uint128 matchedQuoteAmount = size.mul18D(price);
        uint256 bsxFeeMultiplier = 10;
        uint256 maxTradingFeeInBsx = bsxFeeMultiplier
            * uint256(matchedQuoteAmount.calculatePercentage(MAX_TRADING_FEE_RATE)) * 1e18 / BSX_PRICE_IN_USD;

        fees.maker = int128(uint128(maxTradingFeeInBsx)) + 1;
        fees.taker = 0;
        IOrderBook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderBook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);

        vm.expectRevert(Errors.Orderbook_ExceededMaxTradingFee.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);

        fees.maker = 0;
        fees.taker = int128(uint128(maxTradingFeeInBsx)) + 1;
        makerOrder = _createLongOrder(maker, size, price, makerNonce);
        takerOrder = _createShortOrder(taker, size, price, takerNonce);

        vm.expectRevert(Errors.Orderbook_ExceededMaxTradingFee.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);
    }

    function test_matchOrders_withBsxFees_revertsIfExceededMaxTradingFee() public {
        vm.startPrank(exchange);

        int256 initBsxBalance = 1000 ether;
        spotEngine.updateBalance(maker, BSX_TOKEN, initBsxBalance);
        spotEngine.updateBalance(taker, BSX_TOKEN, initBsxBalance);

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;

        IOrderBook.Fees memory fees;
        fees.liquidation = 5e14;
        fees.sequencer = 1e14;
        fees.isMakerFeeInBSX = true;
        fees.isTakerFeeInBSX = true;

        uint256 bsxFeeMultiplier = 10;
        uint256 maxSequencerFeeInBsx = bsxFeeMultiplier * MAX_TAKER_SEQUENCER_FEE_IN_USD * 1e18 / BSX_PRICE_IN_USD;
        fees.sequencer = uint128(maxSequencerFeeInBsx) + 1;

        IOrderBook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderBook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);

        vm.expectRevert(Errors.Orderbook_ExceededMaxSequencerFee.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);
    }

    function test_matchOrders_liquidation_succeeds() public {
        vm.startPrank(exchange);

        bool isLiquidation = true;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;

        IOrderBook.Fees memory fees;
        fees.maker = 2e14;
        fees.taker = 4e14;
        fees.makerReferralRebate = 2e12;
        fees.takerReferralRebate = 4e12;
        fees.liquidation = 5e14;
        fees.sequencer = 1e14;

        IOrderBook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderBook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);

        int128 expectedBaseAmount = int128(size);
        int128 expectedQuoteAmount = expectedBaseAmount.mul18D(int128(price));
        assertEq(
            abi.encode(perpEngine.getOpenPosition(maker, productId)),
            abi.encode(IPerp.Balance(expectedBaseAmount, -expectedQuoteAmount - fees.maker, 0))
        );
        assertEq(
            abi.encode(perpEngine.getOpenPosition(taker, productId)),
            abi.encode(
                IPerp.Balance(
                    -expectedBaseAmount,
                    expectedQuoteAmount - fees.taker - int128(fees.sequencer) - int128(fees.liquidation),
                    0
                )
            )
        );
        assertEq(spotEngine.getBalance(token, maker), 0);
        assertEq(spotEngine.getBalance(token, taker), 0);

        IOrderBook.FeeCollection memory sequencerFees = orderbook.getSequencerFees();
        assertEq(sequencerFees.inUSDC, int128(fees.sequencer));

        IOrderBook.FeeCollection memory tradingFees = orderbook.getTradingFees();
        assertEq(
            tradingFees.inUSDC,
            fees.maker + fees.taker - int128(fees.makerReferralRebate) - int128(fees.takerReferralRebate)
        );

        IClearingService.InsuranceFund memory insuranceFund = clearingService.getInsuranceFundBalance();
        assertEq(insuranceFund.inUSDC, fees.liquidation);
        assertEq(insuranceFund.inBSX, 0);

        assertEq(orderbook.isMatched(maker, makerNonce, taker, takerNonce), true);
    }

    function test_matchOrders_liquidation_revertsIfExceedMaxLiquidationFee() public {
        vm.startPrank(exchange);

        bool isLiquidation = true;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;

        assertEq(MAX_LIQUIDATION_FEE_RATE, (10 * uint256(Percentage.ONE_HUNDRED_PERCENT)) / 100);

        IOrderBook.Fees memory fees;
        fees.maker = 2e14;
        fees.taker = 4e14;
        fees.makerReferralRebate = 2e12;
        fees.takerReferralRebate = 4e12;
        fees.sequencer = 1e14;
        fees.liquidation = size.mul18D(price).calculatePercentage(MAX_LIQUIDATION_FEE_RATE) + 1;

        IOrderBook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderBook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);

        vm.expectRevert(Errors.Orderbook_ExceededMaxLiquidationFee.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);
    }

    function test_matchOrders_revertsWhenUnauthorized() public {
        IOrderBook.Fees memory fees;

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;
        IOrderBook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderBook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);

        vm.expectRevert(Errors.Unauthorized.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);
    }

    function test_matchOrders_revertsWhenSameAccount() public {
        vm.startPrank(exchange);

        IOrderBook.Fees memory fees;

        address account = makeAddr("account");
        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;
        IOrderBook.Order memory makerOrder = _createLongOrder(account, size, price, makerNonce);
        IOrderBook.Order memory takerOrder = _createShortOrder(account, size, price, takerNonce);

        vm.expectRevert(Errors.Orderbook_OrdersWithSameAccounts.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);
    }

    function test_matchOrders_revertsWhenSameSide() public {
        vm.startPrank(exchange);

        IOrderBook.Fees memory fees;

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;

        IOrderBook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderBook.Order memory takerOrder = _createLongOrder(taker, size, price, takerNonce);
        vm.expectRevert(Errors.Orderbook_OrdersWithSameSides.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);

        makerOrder = _createShortOrder(maker, size, price, makerNonce);
        takerOrder = _createShortOrder(taker, size, price, takerNonce);
        vm.expectRevert(Errors.Orderbook_OrdersWithSameSides.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);
    }

    function test_matchOrders_revertsWhenNonceUsed() public {
        vm.startPrank(exchange);

        IOrderBook.Fees memory fees;

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;
        IOrderBook.Order memory fulfilledMakerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderBook.Order memory fulfilledTakerOrder = _createShortOrder(taker, size, price, takerNonce);
        orderbook.matchOrders(productId, fulfilledMakerOrder, fulfilledTakerOrder, fees, isLiquidation);

        IOrderBook.Order memory newTakerOrder = _createShortOrder(taker, size, price, takerNonce + 1);
        vm.expectRevert(abi.encodeWithSelector(Errors.Orderbook_NonceUsed.selector, maker, makerNonce));
        orderbook.matchOrders(productId, fulfilledMakerOrder, newTakerOrder, fees, isLiquidation);

        IOrderBook.Order memory newMakerOrder = _createLongOrder(maker, size, price, makerNonce + 1);
        vm.expectRevert(abi.encodeWithSelector(Errors.Orderbook_NonceUsed.selector, taker, takerNonce));
        orderbook.matchOrders(productId, newMakerOrder, fulfilledTakerOrder, fees, isLiquidation);
    }

    function test_matchOrders_revertsIfInvalidPrice() public {
        vm.startPrank(exchange);

        IOrderBook.Fees memory fees;

        bool isLiquidation = false;
        uint128 size = 5 * 1e18;
        uint128 price = 75_000 * 1e18;

        uint128 makerPrice = price;
        uint128 takerPrice = price + 1;
        IOrderBook.Order memory makerOrder = _createLongOrder(maker, size, makerPrice, makerNonce);
        IOrderBook.Order memory takerOrder = _createShortOrder(taker, size, takerPrice, takerNonce);
        vm.expectRevert(Errors.Orderbook_InvalidOrderPrice.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);

        makerPrice = price;
        takerPrice = price - 1;
        makerOrder = _createShortOrder(maker, size, makerPrice, makerNonce);
        takerOrder = _createLongOrder(taker, size, takerPrice, takerNonce);
        vm.expectRevert(Errors.Orderbook_InvalidOrderPrice.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);
    }

    function test_matchOrders_revertsIfExceededMaxTradingFees() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        uint128 size = 5 * 1e18;
        uint128 price = 75_000 * 1e18;
        IOrderBook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderBook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);

        uint128 matchedQuoteAmount = size.mul18D(price);
        IOrderBook.Fees memory fees;

        assertEq(MAX_TRADING_FEE_RATE, (2 * uint256(Percentage.ONE_HUNDRED_PERCENT)) / 100);

        fees.maker = int128(matchedQuoteAmount.calculatePercentage(MAX_TRADING_FEE_RATE) + 1);
        vm.expectRevert(Errors.Orderbook_ExceededMaxTradingFee.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);

        fees.maker = 0;
        fees.taker = int128(matchedQuoteAmount.calculatePercentage(MAX_TRADING_FEE_RATE)) + 1;
        vm.expectRevert(Errors.Orderbook_ExceededMaxTradingFee.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);
    }

    function test_matchOrders_revertsIfExceededMaxSequencerFees() public {
        vm.startPrank(exchange);

        IOrderBook.Fees memory fees;

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;
        IOrderBook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderBook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);

        fees.sequencer = MAX_TAKER_SEQUENCER_FEE_IN_USD + 1;

        vm.expectRevert(Errors.Orderbook_ExceededMaxSequencerFee.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fees, isLiquidation);
    }

    function _createLongOrder(address account, uint128 size, uint128 price, uint64 nonce)
        internal
        view
        returns (IOrderBook.Order memory)
    {
        bytes32 orderHash = keccak256(abi.encode(account, size, price, nonce, IOrderBook.OrderSide.SELL));
        return IOrderBook.Order({
            productIndex: productId,
            sender: account,
            size: size,
            price: price,
            nonce: nonce,
            orderSide: IOrderBook.OrderSide.BUY,
            orderHash: orderHash
        });
    }

    function _createShortOrder(address account, uint128 size, uint128 price, uint64 nonce)
        internal
        view
        returns (IOrderBook.Order memory)
    {
        bytes32 orderHash = keccak256(abi.encode(account, size, price, nonce, IOrderBook.OrderSide.SELL));
        return IOrderBook.Order({
            productIndex: productId,
            sender: account,
            size: size,
            price: price,
            nonce: nonce,
            orderSide: IOrderBook.OrderSide.SELL,
            orderHash: orderHash
        });
    }
}

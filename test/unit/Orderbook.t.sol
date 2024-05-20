// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";

import {Access} from "src/Access.sol";
import {Orderbook} from "src/Orderbook.sol";
import {PerpEngine} from "src/PerpEngine.sol";
import {SpotEngine} from "src/SpotEngine.sol";
import {IOrderbook} from "src/interfaces/IOrderbook.sol";
import {IPerpEngine} from "src/interfaces/IPerpEngine.sol";
import {Errors} from "src/libraries/Errors.sol";
import {Math} from "src/libraries/Math.sol";
import {OrderSide} from "src/types/DataTypes.sol";

contract OrderbookTest is Test {
    using Math for uint128;
    using Math for int128;
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
    PerpEngine private perpEngine;
    SpotEngine private spotEngine;
    Orderbook private orderbook;

    function setUp() public {
        access = new Access();
        access.initialize(address(this));
        access.setExchange(exchange);

        spotEngine = new SpotEngine();
        spotEngine.initialize(address(access));

        perpEngine = new PerpEngine();
        perpEngine.initialize(address(access));

        orderbook = new Orderbook();
        orderbook.initialize(address(clearinghouse), address(spotEngine), address(perpEngine), address(access), token);
        access.setOrderbook(address(orderbook));
    }

    function test_initialize() public view {
        assertEq(address(orderbook.clearinghouse()), clearinghouse);
        assertEq(address(orderbook.spotEngine()), address(spotEngine));
        assertEq(address(orderbook.perpEngine()), address(perpEngine));
        assertEq(address(orderbook.access()), address(access));
        assertEq(orderbook.getCollateralToken(), token);
    }

    function test_initialize_revertsIfSetZeroAddr() public {
        Orderbook _orderbook = new Orderbook();
        address mockAddr = makeAddr("mockAddr");
        address[5] memory addresses = [mockAddr, mockAddr, mockAddr, mockAddr, mockAddr];
        for (uint256 i = 0; i < 5; i++) {
            addresses[i] = address(0);
            vm.expectRevert(Errors.ZeroAddress.selector);
            _orderbook.initialize(addresses[0], addresses[1], addresses[2], addresses[3], addresses[4]);
            addresses[i] = mockAddr;
        }
    }

    function test_matchOrders_makerGoLong() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;

        IOrderbook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderbook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);

        IOrderbook.Fee memory fee = IOrderbook.Fee({maker: 0, taker: 0, sequencer: 0, referralRebate: 0});

        vm.expectEmit(address(orderbook));
        emit IOrderbook.OrderMatched(
            productId, maker, taker, OrderSide.LONG, makerOrder.nonce, takerOrder.nonce, size, price, fee, isLiquidation
        );
        orderbook.matchOrders(productId, makerOrder, takerOrder, fee, isLiquidation);

        int128 expectedBaseAmount = int128(size);
        int128 expectedQuoteAmount = int128(size.mul18D(price));
        assertEq(
            abi.encode(perpEngine.getOpenPosition(productId, maker)),
            abi.encode(IPerpEngine.OpenPosition(expectedBaseAmount, -expectedQuoteAmount, 0))
        );
        assertEq(
            abi.encode(perpEngine.getOpenPosition(productId, taker)),
            abi.encode(IPerpEngine.OpenPosition(-expectedBaseAmount, expectedQuoteAmount, 0))
        );
        assertEq(spotEngine.getBalance(maker, token), 0);
        assertEq(spotEngine.getBalance(taker, token), 0);

        assertEq(orderbook.getCollectedSequencerFees(), 0);
        assertEq(orderbook.getCollectedTradingFees(), 0);
    }

    function test_matchOrders_makerGoShort() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;

        IOrderbook.Order memory makerOrder = _createShortOrder(maker, size, price, makerNonce);
        IOrderbook.Order memory takerOrder = _createLongOrder(taker, size, price, takerNonce);

        IOrderbook.Fee memory fee = IOrderbook.Fee({maker: 0, taker: 0, sequencer: 0, referralRebate: 0});

        vm.expectEmit(address(orderbook));
        emit IOrderbook.OrderMatched(
            productId,
            maker,
            taker,
            OrderSide.SHORT,
            makerOrder.nonce,
            takerOrder.nonce,
            size,
            price,
            fee,
            isLiquidation
        );
        orderbook.matchOrders(productId, makerOrder, takerOrder, fee, isLiquidation);

        int128 expectedBaseAmount = int128(size);
        int128 expectedQuoteAmount = int128(size.mul18D(price));
        assertEq(
            abi.encode(perpEngine.getOpenPosition(productId, maker)),
            abi.encode(IPerpEngine.OpenPosition(-expectedBaseAmount, expectedQuoteAmount, 0))
        );
        assertEq(
            abi.encode(perpEngine.getOpenPosition(productId, taker)),
            abi.encode(IPerpEngine.OpenPosition(expectedBaseAmount, -expectedQuoteAmount, 0))
        );
        assertEq(spotEngine.getBalance(maker, token), 0);
        assertEq(spotEngine.getBalance(taker, token), 0);

        assertEq(orderbook.getCollectedSequencerFees(), 0);
        assertEq(orderbook.getCollectedTradingFees(), 0);
    }

    function test_matchOrders_closePosition_settlePnl() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        IOrderbook.Fee memory fee;

        uint128 size = 2 * 1e18;

        uint128 openPositionPrice = 75_000 * 1e18;
        IOrderbook.Order memory makerOpenPosition = _createLongOrder(maker, size, openPositionPrice, makerNonce);
        IOrderbook.Order memory takerOpenPosition = _createShortOrder(taker, size, openPositionPrice, takerNonce);
        orderbook.matchOrders(productId, makerOpenPosition, takerOpenPosition, fee, isLiquidation);

        uint128 closePositionPrice = 80_000 * 1e18;
        IOrderbook.Order memory makerOrder = _createShortOrder(maker, size, closePositionPrice, makerNonce + 1);
        IOrderbook.Order memory takerOrder = _createLongOrder(taker, size, closePositionPrice, takerNonce + 1);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fee, isLiquidation);

        assertEq(
            abi.encode(perpEngine.getOpenPosition(productId, maker)), abi.encode(IPerpEngine.OpenPosition(0, 0, 0))
        );
        assertEq(
            abi.encode(perpEngine.getOpenPosition(productId, taker)), abi.encode(IPerpEngine.OpenPosition(0, 0, 0))
        );

        uint128 pnl = size.mul18D(closePositionPrice - openPositionPrice);
        assertEq(spotEngine.getBalance(maker, token), int128(pnl));
        assertEq(spotEngine.getBalance(taker, token), -int128(pnl));
    }

    function test_matchOrders_closeHalfPosition_settlePnl() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        IOrderbook.Fee memory fee;

        uint128 price = 75_000 * 1e18;

        uint128 openSize = 5 * 1e18;
        IOrderbook.Order memory makerOpenPosition = _createLongOrder(maker, openSize, price, makerNonce);
        IOrderbook.Order memory takerOpenPosition = _createShortOrder(taker, openSize, price, takerNonce);
        orderbook.matchOrders(productId, makerOpenPosition, takerOpenPosition, fee, isLiquidation);

        uint128 closeSize = 2 * 1e18;
        IOrderbook.Order memory makerOrder = _createShortOrder(maker, closeSize, price, makerNonce + 1);
        IOrderbook.Order memory takerOrder = _createLongOrder(taker, closeSize, price, takerNonce + 1);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fee, isLiquidation);

        int128 expectedBaseAmount = int128(openSize - closeSize);
        int128 expectedQuoteAmount = expectedBaseAmount.mul18D(int128(price));
        assertEq(
            abi.encode(perpEngine.getOpenPosition(productId, maker)),
            abi.encode(IPerpEngine.OpenPosition(expectedBaseAmount, -expectedQuoteAmount, 0))
        );
        assertEq(
            abi.encode(perpEngine.getOpenPosition(productId, taker)),
            abi.encode(IPerpEngine.OpenPosition(-expectedBaseAmount, expectedQuoteAmount, 0))
        );

        assertEq(spotEngine.getBalance(maker, token), 0);
        assertEq(spotEngine.getBalance(taker, token), 0);
    }

    function test_matchOrders_changePosition_settlePnl() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        IOrderbook.Fee memory fee;

        uint128 size0 = 2 * 1e18;
        uint128 price0 = 40_000 * 1e18;
        IOrderbook.Order memory makerOpenPosition = _createLongOrder(maker, size0, price0, makerNonce);
        IOrderbook.Order memory takerOpenPosition = _createShortOrder(taker, size0, price0, takerNonce);
        orderbook.matchOrders(productId, makerOpenPosition, takerOpenPosition, fee, isLiquidation);

        uint128 size1 = 4 * 1e18;
        uint128 price1 = 80_000 * 1e18;
        IOrderbook.Order memory makerOrder = _createShortOrder(maker, size1, price1, makerNonce + 1);
        IOrderbook.Order memory takerOrder = _createLongOrder(taker, size1, price1, takerNonce + 1);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fee, isLiquidation);

        int128 expectedBaseAmount = int128(size1 - size0);
        int128 expectedQuoteAmount = expectedBaseAmount.mul18D(int128(price1));
        assertEq(
            abi.encode(perpEngine.getOpenPosition(productId, maker)),
            abi.encode(IPerpEngine.OpenPosition(-expectedBaseAmount, expectedQuoteAmount, 0))
        );
        assertEq(
            abi.encode(perpEngine.getOpenPosition(productId, taker)),
            abi.encode(IPerpEngine.OpenPosition(expectedBaseAmount, -expectedQuoteAmount, 0))
        );

        uint128 pnl = (size1 - size0).mul18D(price1 - price0);
        assertEq(spotEngine.getBalance(maker, token), int128(pnl));
        assertEq(spotEngine.getBalance(taker, token), -int128(pnl));
    }

    function test_matchOrders_withOrderFees() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        uint128 size = 2 * 1e18;
        uint128 price = 75_000 * 1e18;

        IOrderbook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderbook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);

        IOrderbook.Fee memory fee =
            IOrderbook.Fee({maker: 2e14, taker: 4e14, sequencer: orderbook.MAX_SEQUENCER_FEE(), referralRebate: 1e14});

        vm.expectEmit(address(orderbook));
        emit IOrderbook.OrderMatched(
            productId, maker, taker, OrderSide.LONG, makerOrder.nonce, takerOrder.nonce, size, price, fee, isLiquidation
        );
        orderbook.matchOrders(productId, makerOrder, takerOrder, fee, isLiquidation);

        int128 expectedBaseAmount = int128(size);
        int128 expectedQuoteAmount = int128(size.mul18D(price));
        assertEq(
            abi.encode(perpEngine.getOpenPosition(productId, maker)),
            abi.encode(
                IPerpEngine.OpenPosition({
                    baseAmount: expectedBaseAmount,
                    quoteAmount: -expectedQuoteAmount - int128(fee.maker),
                    lastFunding: 0
                })
            )
        );
        assertEq(
            abi.encode(perpEngine.getOpenPosition(productId, taker)),
            abi.encode(
                IPerpEngine.OpenPosition({
                    baseAmount: -expectedBaseAmount,
                    quoteAmount: expectedQuoteAmount - int128(fee.taker + fee.sequencer),
                    lastFunding: 0
                })
            )
        );
        assertEq(spotEngine.getBalance(maker, token), 0);
        assertEq(spotEngine.getBalance(taker, token), 0);

        assertEq(orderbook.getCollectedSequencerFees(), fee.sequencer);
        assertEq(orderbook.getCollectedTradingFees(), fee.maker + fee.taker - fee.referralRebate);
    }

    function test_matchOrders_liquidation() public {
        vm.startPrank(exchange);

        bool isLiquidation = true;
        uint128 size = 4 * 1e18;
        uint128 price = 60_000 * 1e18;

        IOrderbook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderbook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);

        IOrderbook.Fee memory fee =
            IOrderbook.Fee({maker: 2e14, taker: 4e14, sequencer: orderbook.MAX_SEQUENCER_FEE(), referralRebate: 5e12});

        vm.expectEmit(address(orderbook));
        emit IOrderbook.OrderMatched(
            productId, maker, taker, OrderSide.LONG, makerOrder.nonce, takerOrder.nonce, size, price, fee, isLiquidation
        );
        orderbook.matchOrders(productId, makerOrder, takerOrder, fee, isLiquidation);

        int128 expectedBaseAmount = int128(size);
        int128 expectedQuoteAmount = int128(size.mul18D(price));
        uint128 liquidationFee = uint128(expectedQuoteAmount).mul18D(orderbook.LIQUIDATION_FEE_RATE());
        assertEq(
            abi.encode(perpEngine.getOpenPosition(productId, maker)),
            abi.encode(
                IPerpEngine.OpenPosition({
                    baseAmount: expectedBaseAmount,
                    quoteAmount: -expectedQuoteAmount - int128(fee.maker),
                    lastFunding: 0
                })
            )
        );
        assertEq(
            abi.encode(perpEngine.getOpenPosition(productId, taker)),
            abi.encode(
                IPerpEngine.OpenPosition({
                    baseAmount: -expectedBaseAmount,
                    quoteAmount: expectedQuoteAmount - int128(fee.taker + fee.sequencer + liquidationFee),
                    lastFunding: 0
                })
            )
        );
        assertEq(spotEngine.getBalance(maker, token), 0);
        assertEq(spotEngine.getBalance(taker, token), 0);

        assertEq(orderbook.getCollectedSequencerFees(), fee.sequencer);
        assertEq(orderbook.getCollectedTradingFees(), fee.maker + fee.taker + liquidationFee - fee.referralRebate);
    }

    function test_matchOrders_revertsWhenUnauthorized() public {
        bool isLiquidation = false;
        IOrderbook.Fee memory fee;
        IOrderbook.Order memory makerOrder = _createLongOrder(maker, 1, 1, makerNonce);
        IOrderbook.Order memory takerOrder = _createShortOrder(taker, 1, 1, takerNonce);

        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fee, isLiquidation);
    }

    function test_matchOrders_revertsWhenSameAccount() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        IOrderbook.Fee memory fee;
        IOrderbook.Order memory makerOrder = _createLongOrder(maker, 1, 1, makerNonce);
        IOrderbook.Order memory takerOrder = _createShortOrder(maker, 1, 1, takerNonce);

        vm.expectRevert(Errors.Orderbook_InvalidOrder.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fee, isLiquidation);
    }

    function test_matchOrders_revertsWhenSameSide() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        IOrderbook.Fee memory fee;
        IOrderbook.Order memory makerOrder = _createLongOrder(maker, 1, 1, makerNonce);
        IOrderbook.Order memory takerOrder = _createLongOrder(taker, 1, 1, takerNonce);

        vm.expectRevert(Errors.Orderbook_InvalidOrder.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fee, isLiquidation);
    }

    function test_matchOrders_revertsWhenNonceUsed() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        IOrderbook.Fee memory fee;

        uint64 nonce = 1234;
        IOrderbook.Order memory fulfilledMakerOrder = _createLongOrder(maker, 1, 1, nonce);
        IOrderbook.Order memory fulfilledTakerOrder = _createShortOrder(taker, 1, 1, nonce);

        orderbook.matchOrders(productId, fulfilledMakerOrder, fulfilledTakerOrder, fee, isLiquidation);

        IOrderbook.Order memory takerOrder = _createShortOrder(taker, 1, 1, nonce + 1);
        vm.expectRevert(abi.encodeWithSelector(Errors.Orderbook_UsedNonce.selector, maker, nonce));
        orderbook.matchOrders(productId, fulfilledMakerOrder, takerOrder, fee, isLiquidation);

        IOrderbook.Order memory makerOrder = _createLongOrder(maker, 1, 1, nonce + 1);
        vm.expectRevert(abi.encodeWithSelector(Errors.Orderbook_UsedNonce.selector, taker, nonce));
        orderbook.matchOrders(productId, makerOrder, fulfilledTakerOrder, fee, isLiquidation);
    }

    function test_matchOrders_revertsIfInvalidOrderPrice() public {
        vm.startPrank(exchange);

        IOrderbook.Fee memory fee;
        bool isLiquidation = false;
        uint128 size = 1 * 1e18;

        {
            uint128 makerPrice = 50_000 * 1e18;
            IOrderbook.Order memory makerOrder = _createLongOrder(maker, size, makerPrice, makerNonce);

            uint128 takerPrice = 60_000 * 1e18;
            IOrderbook.Order memory takerOrder = _createShortOrder(taker, size, takerPrice, takerNonce);

            vm.expectRevert(Errors.Orderbook_InvalidPrice.selector);
            orderbook.matchOrders(productId, makerOrder, takerOrder, fee, isLiquidation);
        }

        {
            uint128 makerPrice = 50_000 * 1e18;
            IOrderbook.Order memory makerOrder = _createShortOrder(maker, size, makerPrice, makerNonce);

            uint128 takerPrice = 40_000 * 1e18;
            IOrderbook.Order memory takerOrder = _createLongOrder(taker, size, takerPrice, takerNonce);

            vm.expectRevert(Errors.Orderbook_InvalidPrice.selector);
            orderbook.matchOrders(productId, makerOrder, takerOrder, fee, isLiquidation);
        }
    }

    function test_matchOrders_revertsIfExceededMaxTradingFees() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        uint128 size = 5 * 1e18;
        uint128 price = 75_000 * 1e18;
        IOrderbook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderbook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);

        uint128 matchedQuoteAmount = size.mul18D(price);
        IOrderbook.Fee memory fee;

        fee.maker = matchedQuoteAmount.mul18D(orderbook.MAX_TRADING_FEE_RATE()) + 1;
        vm.expectRevert(Errors.Orderbook_ExceededMaxTradingFee.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fee, isLiquidation);

        fee.maker = 0;
        fee.taker = matchedQuoteAmount.mul18D(orderbook.MAX_TRADING_FEE_RATE()) + 1;
        vm.expectRevert(Errors.Orderbook_ExceededMaxTradingFee.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fee, isLiquidation);
    }

    function test_matchOrders_revertsIfExceededMaxSequencerFees() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        uint128 size = 5 * 1e18;
        uint128 price = 75_000 * 1e18;
        IOrderbook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderbook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);

        IOrderbook.Fee memory fee;
        fee.sequencer = orderbook.MAX_SEQUENCER_FEE() + 1;
        vm.expectRevert(Errors.Orderbook_ExceededMaxSequencerFee.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fee, isLiquidation);
    }

    function test_matchOrders_revertsIfExceededReferralFees() public {
        vm.startPrank(exchange);

        bool isLiquidation = false;
        uint128 size = 5 * 1e18;
        uint128 price = 75_000 * 1e18;
        IOrderbook.Order memory makerOrder = _createLongOrder(maker, size, price, makerNonce);
        IOrderbook.Order memory takerOrder = _createShortOrder(taker, size, price, takerNonce);

        IOrderbook.Fee memory fee;
        fee.maker = 2;
        fee.taker = 5;
        fee.referralRebate = fee.maker + fee.taker + 1;

        vm.expectRevert(Errors.Orderbook_InvalidReferralFee.selector);
        orderbook.matchOrders(productId, makerOrder, takerOrder, fee, isLiquidation);
    }

    function test_claimCollectedCollectedSequencerFees() public {
        vm.startPrank(exchange);

        uint256 collectedSequencerFee = 75_000;
        stdstore.target(address(orderbook)).sig("getCollectedSequencerFees()").checked_write(collectedSequencerFee);
        assertEq(orderbook.getCollectedSequencerFees(), collectedSequencerFee);

        assertEq(orderbook.claimCollectedSequencerFees(), collectedSequencerFee);
        assertEq(orderbook.getCollectedSequencerFees(), 0);
    }

    function test_claimCollectedSequencerFee_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        orderbook.claimCollectedSequencerFees();
    }

    function test_claimCollectedTradingFees() public {
        vm.startPrank(exchange);

        uint256 collectedTradingFee = 125_000;
        stdstore.target(address(orderbook)).sig("getCollectedTradingFees()").checked_write(collectedTradingFee);
        assertEq(orderbook.getCollectedTradingFees(), collectedTradingFee);

        assertEq(orderbook.claimCollectedTradingFees(), collectedTradingFee);
        assertEq(orderbook.getCollectedTradingFees(), 0);
    }

    function test_claimCollectedTradingFee_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        orderbook.claimCollectedTradingFees();
    }

    function _createLongOrder(
        address account,
        uint128 size,
        uint128 price,
        uint64 nonce
    ) internal pure returns (IOrderbook.Order memory) {
        IOrderbook.Order memory order = IOrderbook.Order({
            orderHash: keccak256(abi.encode(account, size, price, nonce, OrderSide.LONG)),
            account: account,
            orderSide: OrderSide.LONG,
            price: price,
            size: size,
            nonce: nonce
        });
        return order;
    }

    function _createShortOrder(
        address account,
        uint128 size,
        uint128 price,
        uint64 nonce
    ) internal pure returns (IOrderbook.Order memory) {
        IOrderbook.Order memory order = IOrderbook.Order({
            orderHash: keccak256(abi.encode(account, size, price, nonce, OrderSide.SHORT)),
            account: account,
            orderSide: OrderSide.SHORT,
            price: price,
            size: size,
            nonce: nonce
        });
        return order;
    }
}

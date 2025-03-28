// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {Helper} from "../Helper.sol";
import {ERC20Simple} from "../mock/ERC20Simple.sol";
import {UniversalSigValidator} from "../mock/UniversalSigValidator.sol";

import {ClearingService, IClearingService} from "contracts/exchange/ClearingService.sol";
import {Exchange, IExchange} from "contracts/exchange/Exchange.sol";
import {IOrderBook, OrderBook} from "contracts/exchange/OrderBook.sol";
import {IPerp, Perp} from "contracts/exchange/Perp.sol";
import {Spot} from "contracts/exchange/Spot.sol";
import {VaultManager} from "contracts/exchange/VaultManager.sol";
import {Access} from "contracts/exchange/access/Access.sol";

import {Errors} from "contracts/exchange/lib/Errors.sol";
import {MathHelper} from "contracts/exchange/lib/MathHelper.sol";
import {Percentage} from "contracts/exchange/lib/Percentage.sol";
import {BSX_ORACLE, BSX_TOKEN, MAX_REBATE_RATE, UNIVERSAL_SIG_VALIDATOR} from "contracts/exchange/share/Constants.sol";
import {IBsxOracle} from "contracts/misc/interfaces/IBsxOracle.sol";

// solhint-disable max-states-count
contract OrderExchangeTest is Test {
    using stdStorage for StdStorage;
    using Helper for bytes;
    using MathHelper for int128;
    using Percentage for uint128;

    address private sequencer = makeAddr("sequencer");
    address private feeRecipient = makeAddr("feeRecipient");

    address private maker;
    uint256 private makerKey;
    address private makerSigner;
    uint256 private makerSignerKey;
    address private taker;
    uint256 private takerKey;
    address private takerSigner;
    uint256 private takerSignerKey;

    ERC20Simple private collateralToken = new ERC20Simple(6);

    Access private access;
    Exchange private exchange;
    ClearingService private clearingService;
    OrderBook private orderbook;
    Perp private perpEngine;
    Spot private spotEngine;

    bytes32 private constant REGISTER_TYPEHASH = keccak256("Register(address key,string message,uint64 nonce)");
    bytes32 private constant SIGN_KEY_TYPEHASH = keccak256("SignKey(address account)");
    bytes32 private constant ORDER_TYPEHASH =
        keccak256("Order(address sender,uint128 size,uint128 price,uint64 nonce,uint8 productIndex,uint8 orderSide)");

    function setUp() public {
        vm.startPrank(sequencer);

        access = new Access();
        stdstore.target(address(access)).sig("hasRole(bytes32,address)").with_key(access.ADMIN_ROLE()).with_key(
            sequencer
        ).checked_write(true);
        access.grantRole(access.GENERAL_ROLE(), sequencer);
        access.grantRole(access.BATCH_OPERATOR_ROLE(), sequencer);
        access.grantRole(access.COLLATERAL_OPERATOR_ROLE(), sequencer);
        access.grantRole(access.SIGNER_OPERATOR_ROLE(), sequencer);

        clearingService = new ClearingService();
        stdstore.target(address(clearingService)).sig("access()").checked_write(address(access));

        perpEngine = new Perp();
        stdstore.target(address(perpEngine)).sig("access()").checked_write(address(access));

        spotEngine = new Spot();
        stdstore.target(address(spotEngine)).sig("access()").checked_write(address(access));

        orderbook = new OrderBook();
        stdstore.target(address(orderbook)).sig("clearingService()").checked_write(address(clearingService));
        stdstore.target(address(orderbook)).sig("spotEngine()").checked_write(address(spotEngine));
        stdstore.target(address(orderbook)).sig("perpEngine()").checked_write(address(perpEngine));
        stdstore.target(address(orderbook)).sig("access()").checked_write(address(access));
        stdstore.target(address(orderbook)).sig("getCollateralToken()").checked_write(address(collateralToken));

        exchange = new Exchange();
        bytes memory code = address(new UniversalSigValidator()).code;
        vm.etch(address(UNIVERSAL_SIG_VALIDATOR), code);

        access.setExchange(address(exchange));
        access.setClearingService(address(clearingService));
        access.setOrderBook(address(orderbook));
        access.setSpotEngine(address(spotEngine));

        VaultManager vaultManager = new VaultManager();
        stdstore.target(address(vaultManager)).sig("access()").checked_write(address(access));
        access.setVaultManager(address(vaultManager));

        stdstore.target(address(exchange)).sig("access()").checked_write(address(access));
        stdstore.target(address(exchange)).sig("book()").checked_write(address(orderbook));
        stdstore.target(address(exchange)).sig("clearingService()").checked_write(address(clearingService));
        stdstore.target(address(exchange)).sig("spotEngine()").checked_write(address(spotEngine));
        stdstore.target(address(exchange)).sig("perpEngine()").checked_write(address(perpEngine));
        exchange.updateFeeRecipientAddress(feeRecipient);
        exchange.setCanDeposit(true);
        exchange.setCanWithdraw(true);

        exchange.addSupportedToken(address(collateralToken));

        _accountSetup();

        vm.mockCall(
            address(BSX_ORACLE),
            abi.encodeWithSelector(IBsxOracle.getTokenPriceInUsd.selector, BSX_TOKEN),
            abi.encode(0.05 ether)
        );

        vm.stopPrank();
    }

    struct WrappedOrder {
        uint8 productId;
        uint128 size;
        uint128 price;
        bool isLiquidated;
        IOrderBook.Fees fees;
        uint64 makerNonce;
        IOrderBook.OrderSide makerSide;
        uint64 takerNonce;
        IOrderBook.OrderSide takerSide;
    }

    struct ReferralRebate {
        address makerReferrer;
        address takerReferrer;
        uint16 makerReferrerRebateRate;
        uint16 takerReferrerRebateRate;
    }

    function test_processBatch_matchOrders() public {
        vm.startPrank(sequencer);

        WrappedOrder memory generalOrder;
        generalOrder.isLiquidated = false;
        generalOrder.productId = 1;
        generalOrder.size = 5 * 1e18;
        generalOrder.price = 75_000 * 1e18;
        generalOrder.makerNonce = 2;
        generalOrder.takerNonce = 3;
        generalOrder.makerSide = IOrderBook.OrderSide.BUY;
        generalOrder.takerSide = IOrderBook.OrderSide.SELL;
        generalOrder.fees.maker = 2 * 1e12;
        generalOrder.fees.taker = 3 * 1e12;
        generalOrder.fees.sequencer = 5 * 1e12;

        bytes memory operation;

        // avoid "Stack too deep"
        {
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                IOrderBook.Order({
                    sender: maker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.makerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.makerSide,
                    orderHash: bytes32(0)
                }),
                generalOrder.isLiquidated,
                generalOrder.fees.maker
            );
            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                IOrderBook.Order({
                    sender: taker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.takerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.takerSide,
                    orderHash: bytes32(0)
                }),
                generalOrder.isLiquidated,
                generalOrder.fees.taker
            );

            operation = _encodeDataToOperation(
                IExchange.OperationType.MatchOrders,
                _encodeOrders(makerEncodedOrder, takerEncodedOrder, generalOrder.fees.sequencer)
            );
        }

        vm.expectEmit();
        emit IOrderBook.OrderMatched(
            generalOrder.productId,
            maker,
            taker,
            generalOrder.makerSide,
            generalOrder.makerNonce,
            generalOrder.takerNonce,
            generalOrder.size,
            generalOrder.price,
            generalOrder.fees,
            generalOrder.isLiquidated
        );
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_matchOrders_revertsIfLiquidatedOrders() public {
        vm.startPrank(sequencer);

        uint8 productId = 1;

        bool[2] memory isLiquidated = [true, false];

        for (uint256 i = 0; i < isLiquidated.length; i++) {
            bool makerIsLiquidated = isLiquidated[i];
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                IOrderBook.Order({
                    sender: maker,
                    size: 0,
                    price: 0,
                    nonce: 50,
                    productIndex: productId,
                    orderSide: IOrderBook.OrderSide.BUY,
                    orderHash: bytes32(0)
                }),
                makerIsLiquidated,
                0
            );

            bool takerIsLiquidated = !makerIsLiquidated;
            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                IOrderBook.Order({
                    sender: taker,
                    size: 0,
                    price: 0,
                    nonce: 60,
                    productIndex: productId,
                    orderSide: IOrderBook.OrderSide.SELL,
                    orderHash: bytes32(0)
                }),
                takerIsLiquidated,
                0
            );

            uint128 sequencerFee = 0;
            bytes memory operation = _encodeDataToOperation(
                IExchange.OperationType.MatchOrders, _encodeOrders(makerEncodedOrder, takerEncodedOrder, sequencerFee)
            );

            vm.expectRevert(
                abi.encodeWithSelector(Errors.Exchange_LiquidatedOrder.selector, exchange.executedTransactionCounter())
            );
            exchange.processBatch(operation.toArray());
        }
    }

    function test_processBatch_matchOrders_revertsIfProductIdMismatch() public {
        vm.startPrank(sequencer);

        bool isLiquidated = false;
        uint8 makerProductId = 1;
        bytes memory makerEncodedOrder = _encodeOrder(
            makerSignerKey,
            IOrderBook.Order({
                sender: maker,
                size: 0,
                price: 0,
                nonce: 66,
                productIndex: makerProductId,
                orderSide: IOrderBook.OrderSide.BUY,
                orderHash: bytes32(0)
            }),
            isLiquidated,
            0
        );

        uint8 takerProductId = 2;
        bytes memory takerEncodedOrder = _encodeOrder(
            takerSignerKey,
            IOrderBook.Order({
                sender: taker,
                size: 0,
                price: 0,
                nonce: 77,
                productIndex: takerProductId,
                orderSide: IOrderBook.OrderSide.SELL,
                orderHash: bytes32(0)
            }),
            isLiquidated,
            0
        );

        uint128 sequencerFee = 0;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.MatchOrders, _encodeOrders(makerEncodedOrder, takerEncodedOrder, sequencerFee)
        );

        vm.expectRevert(Errors.Exchange_ProductIdMismatch.selector);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_matchOrders_revertsIfUnauthorizedSigner() public {
        vm.startPrank(sequencer);

        (address maliciousSigner, uint256 maliciousSignerKey) = makeAddrAndKey("maliciousSigner");

        bool isLiquidated = false;
        uint8 productId = 1;
        address[2] memory accounts = [maker, taker];

        for (uint256 i = 0; i < 2; i++) {
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                IOrderBook.Order({
                    sender: maker,
                    size: 10,
                    price: 20,
                    nonce: 66,
                    productIndex: productId,
                    orderSide: IOrderBook.OrderSide.BUY,
                    orderHash: bytes32(0)
                }),
                isLiquidated,
                0
            );
            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                IOrderBook.Order({
                    sender: taker,
                    size: 10,
                    price: 20,
                    nonce: 77,
                    productIndex: productId,
                    orderSide: IOrderBook.OrderSide.SELL,
                    orderHash: bytes32(0)
                }),
                isLiquidated,
                0
            );

            address account = accounts[i];
            if (account == maker) {
                makerEncodedOrder = _encodeOrder(
                    maliciousSignerKey,
                    IOrderBook.Order({
                        sender: maker,
                        size: 0,
                        price: 0,
                        nonce: 66,
                        productIndex: productId,
                        orderSide: IOrderBook.OrderSide.BUY,
                        orderHash: bytes32(0)
                    }),
                    isLiquidated,
                    0
                );
            } else {
                takerEncodedOrder = _encodeOrder(
                    maliciousSignerKey,
                    IOrderBook.Order({
                        sender: taker,
                        size: 0,
                        price: 0,
                        nonce: 77,
                        productIndex: productId,
                        orderSide: IOrderBook.OrderSide.SELL,
                        orderHash: bytes32(0)
                    }),
                    isLiquidated,
                    0
                );
            }

            uint128 sequencerFee = 0;
            bytes memory operation = _encodeDataToOperation(
                IExchange.OperationType.MatchOrders, _encodeOrders(makerEncodedOrder, takerEncodedOrder, sequencerFee)
            );

            vm.expectRevert(
                abi.encodeWithSelector(Errors.Exchange_UnauthorizedSigner.selector, account, maliciousSigner)
            );
            exchange.processBatch(operation.toArray());
        }
    }

    function test_processBatch_matchOrders_revertsIfInvalidSignerSignature() public {
        vm.startPrank(sequencer);

        (address maliciousSigner, uint256 maliciousSignerKey) = makeAddrAndKey("maliciousSigner");

        uint8 productId = 1;
        bool isLiquidated = false;
        address[2] memory signers = [makerSigner, takerSigner];

        for (uint256 i = 0; i < 2; i++) {
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                IOrderBook.Order({
                    sender: maker,
                    size: 10,
                    price: 20,
                    nonce: 77,
                    productIndex: productId,
                    orderSide: IOrderBook.OrderSide.BUY,
                    orderHash: bytes32(0)
                }),
                isLiquidated,
                0
            );
            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                IOrderBook.Order({
                    sender: taker,
                    size: 10,
                    price: 20,
                    nonce: 77,
                    productIndex: productId,
                    orderSide: IOrderBook.OrderSide.SELL,
                    orderHash: bytes32(0)
                }),
                isLiquidated,
                0
            );

            address expectedSigner = signers[i];
            if (expectedSigner == makerSigner) {
                makerEncodedOrder = _encodeOrderWithSigner(
                    makerSigner,
                    maliciousSignerKey,
                    IOrderBook.Order({
                        sender: maker,
                        size: 0,
                        price: 0,
                        nonce: 33,
                        productIndex: productId,
                        orderSide: IOrderBook.OrderSide.BUY,
                        orderHash: bytes32(0)
                    }),
                    isLiquidated,
                    0
                );
            } else {
                takerEncodedOrder = _encodeOrderWithSigner(
                    takerSigner,
                    maliciousSignerKey,
                    IOrderBook.Order({
                        sender: taker,
                        size: 0,
                        price: 0,
                        nonce: 88,
                        productIndex: productId,
                        orderSide: IOrderBook.OrderSide.SELL,
                        orderHash: bytes32(0)
                    }),
                    isLiquidated,
                    0
                );
            }

            bytes memory operation = _encodeDataToOperation(
                IExchange.OperationType.MatchOrders, _encodeOrders(makerEncodedOrder, takerEncodedOrder, 0)
            );

            vm.expectRevert(
                abi.encodeWithSelector(Errors.Exchange_InvalidSignerSignature.selector, maliciousSigner, expectedSigner)
            );
            exchange.processBatch(operation.toArray());
        }
    }

    function test_processBatch_matchLiquidatedOrders() public {
        vm.startPrank(sequencer);

        WrappedOrder memory generalOrder;
        generalOrder.isLiquidated = true;
        generalOrder.productId = 1;
        generalOrder.size = 5 * 1e18;
        generalOrder.price = 75_000 * 1e18;
        generalOrder.makerNonce = 70;
        generalOrder.takerNonce = 30;
        generalOrder.makerSide = IOrderBook.OrderSide.BUY;
        generalOrder.takerSide = IOrderBook.OrderSide.SELL;
        generalOrder.fees.maker = 2 * 1e12;
        generalOrder.fees.taker = 3 * 1e12;
        generalOrder.fees.liquidation = 4e14;
        generalOrder.fees.sequencer = 5 * 1e12;

        bytes memory operation;

        // avoid "Stack too deep"
        {
            bool makerIsLiquidated = false;
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                IOrderBook.Order({
                    sender: maker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.makerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.makerSide,
                    orderHash: bytes32(0)
                }),
                makerIsLiquidated,
                generalOrder.fees.maker
            );
            bytes memory takerEncodedOrder = _encodeLiquidatedOrder(
                IOrderBook.Order({
                    sender: taker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.takerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.takerSide,
                    orderHash: bytes32(0)
                }),
                generalOrder.isLiquidated,
                generalOrder.fees.taker
            );

            operation = _encodeDataToOperation(
                IExchange.OperationType.MatchLiquidationOrders,
                _encodeOrders(
                    makerEncodedOrder, takerEncodedOrder, generalOrder.fees.sequencer, generalOrder.fees.liquidation
                )
            );
        }

        vm.expectEmit();
        emit IOrderBook.OrderMatched(
            generalOrder.productId,
            maker,
            taker,
            generalOrder.makerSide,
            generalOrder.makerNonce,
            generalOrder.takerNonce,
            generalOrder.size,
            generalOrder.price,
            generalOrder.fees,
            generalOrder.isLiquidated
        );
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_matchLiquidationOrders_withBsxFees() public {
        vm.startPrank(sequencer);

        WrappedOrder memory generalOrder;
        generalOrder.isLiquidated = true;
        generalOrder.productId = 1;
        generalOrder.size = 5 * 1e18;
        generalOrder.price = 75_000 * 1e18;
        generalOrder.makerNonce = 66;
        generalOrder.takerNonce = 77;
        generalOrder.makerSide = IOrderBook.OrderSide.BUY;
        generalOrder.takerSide = IOrderBook.OrderSide.SELL;

        generalOrder.fees.maker = 2 * 1e12;
        generalOrder.fees.taker = 3 * 1e12;
        generalOrder.fees.sequencer = 5 * 1e12;
        generalOrder.fees.liquidation = 4e12;
        generalOrder.fees.isMakerFeeInBSX = true;
        generalOrder.fees.isTakerFeeInBSX = true;

        bytes memory operation;

        {
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                IOrderBook.Order({
                    sender: maker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.makerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.makerSide,
                    orderHash: bytes32(0)
                }),
                false,
                generalOrder.fees.maker
            );

            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                IOrderBook.Order({
                    sender: taker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.takerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.takerSide,
                    orderHash: bytes32(0)
                }),
                generalOrder.isLiquidated,
                generalOrder.fees.taker
            );

            ReferralRebate memory referralRebate;
            operation = _encodeDataToOperation(
                IExchange.OperationType.MatchLiquidationOrders,
                _encodeOrders(
                    makerEncodedOrder,
                    takerEncodedOrder,
                    generalOrder.fees.sequencer,
                    referralRebate,
                    generalOrder.fees.liquidation,
                    generalOrder.fees.isMakerFeeInBSX,
                    generalOrder.fees.isTakerFeeInBSX
                )
            );
        }

        IClearingService.InsuranceFund memory insuranceFundBefore = clearingService.getInsuranceFundBalance();

        vm.expectEmit(address(orderbook));
        emit IOrderBook.OrderMatched(
            generalOrder.productId,
            maker,
            taker,
            generalOrder.makerSide,
            generalOrder.makerNonce,
            generalOrder.takerNonce,
            generalOrder.size,
            generalOrder.price,
            generalOrder.fees,
            generalOrder.isLiquidated
        );
        exchange.processBatch(operation.toArray());

        IOrderBook.FeeCollection memory tradingFees = orderbook.getTradingFees();
        assertEq(tradingFees.inBSX, generalOrder.fees.maker + generalOrder.fees.taker);

        IPerp.Balance memory makerPerpBalance = perpEngine.getOpenPosition(maker, generalOrder.productId);
        IPerp.Balance memory takerPerpBalance = perpEngine.getOpenPosition(taker, generalOrder.productId);

        // maker goes long
        assertEq(makerPerpBalance.size, int128(generalOrder.size));
        assertEq(makerPerpBalance.quoteBalance, -int128(generalOrder.size).mul18D(int128(generalOrder.price)));

        // taker goes short
        assertEq(takerPerpBalance.size, -int128(generalOrder.size));
        assertEq(takerPerpBalance.quoteBalance, int128(generalOrder.size).mul18D(int128(generalOrder.price)));

        IClearingService.InsuranceFund memory insuranceFundAfter = clearingService.getInsuranceFundBalance();
        assertEq(insuranceFundAfter.inUSDC, insuranceFundBefore.inUSDC);
        assertEq(insuranceFundAfter.inBSX, insuranceFundBefore.inBSX + generalOrder.fees.liquidation);

        assertEq(exchange.balanceOf(maker, address(collateralToken)), 0);
        assertEq(exchange.balanceOf(maker, BSX_TOKEN), -generalOrder.fees.maker);

        assertEq(exchange.balanceOf(taker, address(collateralToken)), 0);
        assertEq(
            exchange.balanceOf(taker, BSX_TOKEN),
            -(generalOrder.fees.taker + int128(generalOrder.fees.sequencer) + int128(generalOrder.fees.liquidation))
        );
    }

    function test_processBatch_matchLiquidatedOrders_revertsIfNotLiquidatedOrder() public {
        vm.startPrank(sequencer);

        uint8 productId = 1;

        bool makerIsLiquidated = false;
        bytes memory makerEncodedOrder = _encodeOrder(
            makerSignerKey,
            IOrderBook.Order({
                sender: maker,
                size: 0,
                price: 0,
                nonce: 50,
                productIndex: productId,
                orderSide: IOrderBook.OrderSide.BUY,
                orderHash: bytes32(0)
            }),
            makerIsLiquidated,
            0
        );

        bool takerIsLiquidated = false;
        bytes memory takerEncodedOrder = _encodeLiquidatedOrder(
            IOrderBook.Order({
                sender: taker,
                size: 0,
                price: 0,
                nonce: 60,
                productIndex: productId,
                orderSide: IOrderBook.OrderSide.SELL,
                orderHash: bytes32(0)
            }),
            takerIsLiquidated,
            0
        );

        uint128 sequencerFee = 0;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.MatchLiquidationOrders,
            _encodeOrders(makerEncodedOrder, takerEncodedOrder, sequencerFee)
        );

        vm.expectRevert(
            abi.encodeWithSelector(Errors.Exchange_NotLiquidatedOrder.selector, exchange.executedTransactionCounter())
        );
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_matchLiquidatedOrders_revertsIfMakerIsLiquidatedOrder() public {
        vm.startPrank(sequencer);

        uint8 productId = 1;

        bool makerIsLiquidated = true;
        bytes memory makerEncodedOrder = _encodeOrder(
            makerSignerKey,
            IOrderBook.Order({
                sender: maker,
                size: 0,
                price: 0,
                nonce: 50,
                productIndex: productId,
                orderSide: IOrderBook.OrderSide.BUY,
                orderHash: bytes32(0)
            }),
            makerIsLiquidated,
            0
        );

        bool takerIsLiquidated = true;
        bytes memory takerEncodedOrder = _encodeLiquidatedOrder(
            IOrderBook.Order({
                sender: taker,
                size: 0,
                price: 0,
                nonce: 60,
                productIndex: productId,
                orderSide: IOrderBook.OrderSide.SELL,
                orderHash: bytes32(0)
            }),
            takerIsLiquidated,
            0
        );

        uint128 sequencerFee = 0;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.MatchLiquidationOrders,
            _encodeOrders(makerEncodedOrder, takerEncodedOrder, sequencerFee)
        );

        vm.expectRevert(
            abi.encodeWithSelector(Errors.Exchange_MakerLiquidatedOrder.selector, exchange.executedTransactionCounter())
        );
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_matchLiquidatedOrders_revertsIfProductIdMismatch() public {
        vm.startPrank(sequencer);

        bool isLiquidated = true;

        uint8 makerProductId = 1;
        bool makerIsLiquidated = false;
        bytes memory makerEncodedOrder = _encodeOrder(
            makerSignerKey,
            IOrderBook.Order({
                sender: maker,
                size: 0,
                price: 0,
                nonce: 66,
                productIndex: makerProductId,
                orderSide: IOrderBook.OrderSide.BUY,
                orderHash: bytes32(0)
            }),
            makerIsLiquidated,
            0
        );

        uint8 takerProductId = 2;
        bytes memory takerEncodedOrder = _encodeLiquidatedOrder(
            IOrderBook.Order({
                sender: taker,
                size: 0,
                price: 0,
                nonce: 77,
                productIndex: takerProductId,
                orderSide: IOrderBook.OrderSide.SELL,
                orderHash: bytes32(0)
            }),
            isLiquidated,
            0
        );

        uint128 sequencerFee = 0;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.MatchLiquidationOrders,
            _encodeOrders(makerEncodedOrder, takerEncodedOrder, sequencerFee)
        );

        vm.expectRevert(Errors.Exchange_ProductIdMismatch.selector);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_matchLiquidatedOrders_revertsIfUnauthorizedSigner() public {
        vm.startPrank(sequencer);

        (address maliciousSigner, uint256 maliciousSignerKey) = makeAddrAndKey("maliciousSigner");

        bool isLiquidated = true;
        uint8 productId = 1;

        bool makerIsLiquidated = false;
        bytes memory makerEncodedOrder = _encodeOrder(
            maliciousSignerKey,
            IOrderBook.Order({
                sender: maker,
                size: 0,
                price: 0,
                nonce: 66,
                productIndex: productId,
                orderSide: IOrderBook.OrderSide.BUY,
                orderHash: bytes32(0)
            }),
            makerIsLiquidated,
            0
        );
        bytes memory takerEncodedOrder = _encodeLiquidatedOrder(
            IOrderBook.Order({
                sender: taker,
                size: 0,
                price: 0,
                nonce: 77,
                productIndex: productId,
                orderSide: IOrderBook.OrderSide.SELL,
                orderHash: bytes32(0)
            }),
            isLiquidated,
            0
        );

        uint128 sequencerFee = 0;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.MatchLiquidationOrders,
            _encodeOrders(makerEncodedOrder, takerEncodedOrder, sequencerFee)
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_UnauthorizedSigner.selector, maker, maliciousSigner));
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_matchLiquidatedOrders_revertsIfInvalidSignerSignature() public {
        vm.startPrank(sequencer);

        (address maliciousSigner, uint256 maliciousSignerKey) = makeAddrAndKey("maliciousSigner");

        uint8 productId = 1;
        bool isLiquidated = true;

        bool makerIsLiquidated = false;
        bytes memory makerEncodedOrder = _encodeOrderWithSigner(
            makerSigner,
            maliciousSignerKey,
            IOrderBook.Order({
                sender: maker,
                size: 0,
                price: 0,
                nonce: 77,
                productIndex: productId,
                orderSide: IOrderBook.OrderSide.BUY,
                orderHash: bytes32(0)
            }),
            makerIsLiquidated,
            0
        );
        bytes memory takerEncodedOrder = _encodeLiquidatedOrder(
            IOrderBook.Order({
                sender: taker,
                size: 0,
                price: 0,
                nonce: 77,
                productIndex: productId,
                orderSide: IOrderBook.OrderSide.SELL,
                orderHash: bytes32(0)
            }),
            isLiquidated,
            0
        );

        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.MatchLiquidationOrders, _encodeOrders(makerEncodedOrder, takerEncodedOrder, 0)
        );

        vm.expectRevert(
            abi.encodeWithSelector(Errors.Exchange_InvalidSignerSignature.selector, maliciousSigner, makerSigner)
        );
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_matchOrders_referralRebate() public {
        vm.startPrank(sequencer);

        WrappedOrder memory generalOrder;
        generalOrder.isLiquidated = false;
        generalOrder.productId = 1;
        generalOrder.size = 5 * 1e18;
        generalOrder.price = 75_000 * 1e18;
        generalOrder.makerNonce = 66;
        generalOrder.takerNonce = 77;
        generalOrder.makerSide = IOrderBook.OrderSide.BUY;
        generalOrder.takerSide = IOrderBook.OrderSide.SELL;
        generalOrder.fees.maker = 2 * 1e12;
        generalOrder.fees.taker = 3 * 1e12;

        bytes memory makerEncodedOrder = _encodeOrder(
            makerSignerKey,
            IOrderBook.Order({
                sender: maker,
                size: generalOrder.size,
                price: generalOrder.price,
                nonce: generalOrder.makerNonce,
                productIndex: generalOrder.productId,
                orderSide: generalOrder.makerSide,
                orderHash: bytes32(0)
            }),
            generalOrder.isLiquidated,
            generalOrder.fees.maker
        );

        bytes memory takerEncodedOrder = _encodeOrder(
            takerSignerKey,
            IOrderBook.Order({
                sender: taker,
                size: generalOrder.size,
                price: generalOrder.price,
                nonce: generalOrder.takerNonce,
                productIndex: generalOrder.productId,
                orderSide: generalOrder.takerSide,
                orderHash: bytes32(0)
            }),
            generalOrder.isLiquidated,
            generalOrder.fees.taker
        );

        ReferralRebate memory referralRebate = ReferralRebate({
            makerReferrer: makeAddr("makerReferrer"),
            makerReferrerRebateRate: 1000, // 10%
            takerReferrer: makeAddr("takerReferrer"),
            takerReferrerRebateRate: 500 // 5%
        });

        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.MatchOrders,
            _encodeOrders(makerEncodedOrder, takerEncodedOrder, generalOrder.fees.sequencer, referralRebate)
        );

        generalOrder.fees.makerReferralRebate =
            uint128(generalOrder.fees.maker).calculatePercentage(referralRebate.makerReferrerRebateRate);
        generalOrder.fees.takerReferralRebate =
            uint128(generalOrder.fees.taker).calculatePercentage(referralRebate.takerReferrerRebateRate);

        vm.expectEmit(address(exchange));
        emit IExchange.RebateReferrer(
            referralRebate.makerReferrer,
            uint128(generalOrder.fees.maker).calculatePercentage(referralRebate.makerReferrerRebateRate),
            false
        );
        emit IExchange.RebateReferrer(
            referralRebate.takerReferrer,
            uint128(generalOrder.fees.taker).calculatePercentage(referralRebate.takerReferrerRebateRate),
            false
        );
        vm.expectEmit(address(orderbook));
        emit IOrderBook.OrderMatched(
            generalOrder.productId,
            maker,
            taker,
            generalOrder.makerSide,
            generalOrder.makerNonce,
            generalOrder.takerNonce,
            generalOrder.size,
            generalOrder.price,
            generalOrder.fees,
            generalOrder.isLiquidated
        );
        exchange.processBatch(operation.toArray());

        int256 makerReferrerBalance = exchange.balanceOf(referralRebate.makerReferrer, address(collateralToken));
        int256 takerReferrerBalance = exchange.balanceOf(referralRebate.takerReferrer, address(collateralToken));
        assertEq(
            uint256(makerReferrerBalance),
            uint128(generalOrder.fees.maker).calculatePercentage(referralRebate.makerReferrerRebateRate)
        );
        assertEq(
            uint256(takerReferrerBalance),
            uint128(generalOrder.fees.taker).calculatePercentage(referralRebate.takerReferrerRebateRate)
        );

        IOrderBook.FeeCollection memory tradingFees = orderbook.getTradingFees();
        assertEq(
            tradingFees.inUSDC,
            generalOrder.fees.maker + generalOrder.fees.taker - int128(generalOrder.fees.makerReferralRebate)
                - int128(generalOrder.fees.takerReferralRebate)
        );

        IPerp.Balance memory makerPerpBalance = perpEngine.getOpenPosition(maker, generalOrder.productId);
        IPerp.Balance memory takerPerpBalance = perpEngine.getOpenPosition(taker, generalOrder.productId);

        // maker goes long
        assertEq(makerPerpBalance.size, int128(generalOrder.size));
        assertEq(
            makerPerpBalance.quoteBalance,
            -int128(generalOrder.size).mul18D(int128(generalOrder.price)) - generalOrder.fees.maker
        );

        // taker goes short
        assertEq(takerPerpBalance.size, -int128(generalOrder.size));
        assertEq(
            takerPerpBalance.quoteBalance,
            int128(generalOrder.size).mul18D(int128(generalOrder.price)) - generalOrder.fees.taker
        );
    }

    function test_processBatch_matchLiquidatedOrders_referralRebate() public {
        vm.startPrank(sequencer);

        WrappedOrder memory generalOrder;
        generalOrder.isLiquidated = true;
        generalOrder.productId = 1;
        generalOrder.size = 5 * 1e18;
        generalOrder.price = 75_000 * 1e18;
        generalOrder.makerNonce = 66;
        generalOrder.takerNonce = 77;
        generalOrder.makerSide = IOrderBook.OrderSide.BUY;
        generalOrder.takerSide = IOrderBook.OrderSide.SELL;
        generalOrder.fees.maker = 2 * 1e12;
        generalOrder.fees.taker = 3 * 1e12;
        generalOrder.fees.liquidation = 4e12;

        ReferralRebate memory referralRebate;
        bytes memory operation;

        {
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                IOrderBook.Order({
                    sender: maker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.makerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.makerSide,
                    orderHash: bytes32(0)
                }),
                false,
                generalOrder.fees.maker
            );

            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                IOrderBook.Order({
                    sender: taker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.takerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.takerSide,
                    orderHash: bytes32(0)
                }),
                generalOrder.isLiquidated,
                generalOrder.fees.taker
            );

            referralRebate = ReferralRebate({
                makerReferrer: makeAddr("makerReferrer"),
                makerReferrerRebateRate: 1000, // 10%
                takerReferrer: makeAddr("takerReferrer"),
                takerReferrerRebateRate: 500 // 5%
            });

            operation = _encodeDataToOperation(
                IExchange.OperationType.MatchLiquidationOrders,
                _encodeOrders(
                    makerEncodedOrder,
                    takerEncodedOrder,
                    generalOrder.fees.sequencer,
                    referralRebate,
                    generalOrder.fees.liquidation
                )
            );
        }

        generalOrder.fees.makerReferralRebate =
            uint128(generalOrder.fees.maker).calculatePercentage(referralRebate.makerReferrerRebateRate);
        generalOrder.fees.takerReferralRebate =
            uint128(generalOrder.fees.taker).calculatePercentage(referralRebate.takerReferrerRebateRate);

        IClearingService.InsuranceFund memory insuranceFundBefore = clearingService.getInsuranceFundBalance();

        vm.expectEmit(address(exchange));
        emit IExchange.RebateReferrer(
            referralRebate.makerReferrer,
            uint128(generalOrder.fees.maker).calculatePercentage(referralRebate.makerReferrerRebateRate),
            false
        );
        emit IExchange.RebateReferrer(
            referralRebate.takerReferrer,
            uint128(generalOrder.fees.taker).calculatePercentage(referralRebate.takerReferrerRebateRate),
            false
        );
        vm.expectEmit(address(orderbook));
        emit IOrderBook.OrderMatched(
            generalOrder.productId,
            maker,
            taker,
            generalOrder.makerSide,
            generalOrder.makerNonce,
            generalOrder.takerNonce,
            generalOrder.size,
            generalOrder.price,
            generalOrder.fees,
            generalOrder.isLiquidated
        );
        exchange.processBatch(operation.toArray());

        int256 makerReferrerBalance = exchange.balanceOf(referralRebate.makerReferrer, address(collateralToken));
        int256 takerReferrerBalance = exchange.balanceOf(referralRebate.takerReferrer, address(collateralToken));
        assertEq(
            uint256(makerReferrerBalance),
            uint128(generalOrder.fees.maker).calculatePercentage(referralRebate.makerReferrerRebateRate)
        );
        assertEq(
            uint256(takerReferrerBalance),
            uint128(generalOrder.fees.taker).calculatePercentage(referralRebate.takerReferrerRebateRate)
        );

        IOrderBook.FeeCollection memory tradingFees = orderbook.getTradingFees();
        assertEq(
            tradingFees.inUSDC,
            generalOrder.fees.maker + generalOrder.fees.taker - int128(generalOrder.fees.makerReferralRebate)
                - int128(generalOrder.fees.takerReferralRebate)
        );

        IPerp.Balance memory makerPerpBalance = perpEngine.getOpenPosition(maker, generalOrder.productId);
        IPerp.Balance memory takerPerpBalance = perpEngine.getOpenPosition(taker, generalOrder.productId);

        // maker goes long
        assertEq(makerPerpBalance.size, int128(generalOrder.size));
        assertEq(
            makerPerpBalance.quoteBalance,
            -int128(generalOrder.size).mul18D(int128(generalOrder.price)) - generalOrder.fees.maker
        );

        // taker goes short
        assertEq(takerPerpBalance.size, -int128(generalOrder.size));
        assertEq(
            takerPerpBalance.quoteBalance,
            int128(generalOrder.size).mul18D(int128(generalOrder.price)) - generalOrder.fees.taker
                - int128(generalOrder.fees.liquidation)
        );

        IClearingService.InsuranceFund memory insuranceFundAfter = clearingService.getInsuranceFundBalance();
        assertEq(insuranceFundAfter.inUSDC, insuranceFundBefore.inUSDC + generalOrder.fees.liquidation);
        assertEq(insuranceFundAfter.inBSX, insuranceFundBefore.inBSX);
    }

    function test_processBatch_matchLiquidationOrders_referralRebate_withBsxFees() public {
        vm.startPrank(sequencer);

        WrappedOrder memory generalOrder;
        generalOrder.isLiquidated = true;
        generalOrder.productId = 1;
        generalOrder.size = 5 * 1e18;
        generalOrder.price = 75_000 * 1e18;
        generalOrder.makerNonce = 66;
        generalOrder.takerNonce = 77;
        generalOrder.makerSide = IOrderBook.OrderSide.BUY;
        generalOrder.takerSide = IOrderBook.OrderSide.SELL;

        generalOrder.fees.maker = 2 * 1e12;
        generalOrder.fees.taker = 3 * 1e12;
        generalOrder.fees.sequencer = 5 * 1e12;
        generalOrder.fees.liquidation = 4e12;
        generalOrder.fees.isMakerFeeInBSX = true;
        generalOrder.fees.isTakerFeeInBSX = true;

        ReferralRebate memory referralRebate = ReferralRebate({
            makerReferrer: makeAddr("makerReferrer"),
            makerReferrerRebateRate: 1000, // 10%
            takerReferrer: makeAddr("takerReferrer"),
            takerReferrerRebateRate: 500 // 5%
        });
        bytes memory operation;

        {
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                IOrderBook.Order({
                    sender: maker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.makerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.makerSide,
                    orderHash: bytes32(0)
                }),
                false,
                generalOrder.fees.maker
            );

            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                IOrderBook.Order({
                    sender: taker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.takerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.takerSide,
                    orderHash: bytes32(0)
                }),
                generalOrder.isLiquidated,
                generalOrder.fees.taker
            );

            operation = _encodeDataToOperation(
                IExchange.OperationType.MatchLiquidationOrders,
                _encodeOrders(
                    makerEncodedOrder,
                    takerEncodedOrder,
                    generalOrder.fees.sequencer,
                    referralRebate,
                    generalOrder.fees.liquidation,
                    generalOrder.fees.isMakerFeeInBSX,
                    generalOrder.fees.isTakerFeeInBSX
                )
            );

            generalOrder.fees.makerReferralRebate =
                uint128(generalOrder.fees.maker).calculatePercentage(referralRebate.makerReferrerRebateRate);
            generalOrder.fees.takerReferralRebate =
                uint128(generalOrder.fees.taker).calculatePercentage(referralRebate.takerReferrerRebateRate);
        }
        IClearingService.InsuranceFund memory insuranceFundBefore = clearingService.getInsuranceFundBalance();

        vm.expectEmit(address(exchange));
        emit IExchange.RebateReferrer(
            referralRebate.makerReferrer,
            uint128(generalOrder.fees.maker).calculatePercentage(referralRebate.makerReferrerRebateRate),
            true
        );
        emit IExchange.RebateReferrer(
            referralRebate.takerReferrer,
            uint128(generalOrder.fees.taker).calculatePercentage(referralRebate.takerReferrerRebateRate),
            true
        );
        vm.expectEmit(address(orderbook));
        emit IOrderBook.OrderMatched(
            generalOrder.productId,
            maker,
            taker,
            generalOrder.makerSide,
            generalOrder.makerNonce,
            generalOrder.takerNonce,
            generalOrder.size,
            generalOrder.price,
            generalOrder.fees,
            generalOrder.isLiquidated
        );
        exchange.processBatch(operation.toArray());

        int256 makerReferrerBalance = exchange.balanceOf(referralRebate.makerReferrer, BSX_TOKEN);
        int256 takerReferrerBalance = exchange.balanceOf(referralRebate.takerReferrer, BSX_TOKEN);
        assertEq(uint256(makerReferrerBalance), generalOrder.fees.makerReferralRebate);
        assertEq(uint256(takerReferrerBalance), generalOrder.fees.takerReferralRebate);

        IOrderBook.FeeCollection memory tradingFees = orderbook.getTradingFees();
        assertEq(
            tradingFees.inBSX,
            generalOrder.fees.maker + generalOrder.fees.taker - int128(generalOrder.fees.makerReferralRebate)
                - int128(generalOrder.fees.takerReferralRebate)
        );

        IPerp.Balance memory makerPerpBalance = perpEngine.getOpenPosition(maker, generalOrder.productId);
        IPerp.Balance memory takerPerpBalance = perpEngine.getOpenPosition(taker, generalOrder.productId);

        // maker goes long
        assertEq(makerPerpBalance.size, int128(generalOrder.size));
        assertEq(makerPerpBalance.quoteBalance, -int128(generalOrder.size).mul18D(int128(generalOrder.price)));

        // taker goes short
        assertEq(takerPerpBalance.size, -int128(generalOrder.size));
        assertEq(takerPerpBalance.quoteBalance, int128(generalOrder.size).mul18D(int128(generalOrder.price)));

        IClearingService.InsuranceFund memory insuranceFundAfter = clearingService.getInsuranceFundBalance();
        assertEq(insuranceFundAfter.inUSDC, insuranceFundBefore.inUSDC);
        assertEq(insuranceFundAfter.inBSX, insuranceFundBefore.inBSX + generalOrder.fees.liquidation);

        assertEq(exchange.balanceOf(maker, address(collateralToken)), 0);
        assertEq(exchange.balanceOf(maker, BSX_TOKEN), -generalOrder.fees.maker);

        assertEq(exchange.balanceOf(taker, address(collateralToken)), 0);
        assertEq(
            exchange.balanceOf(taker, BSX_TOKEN),
            -(generalOrder.fees.taker + int128(generalOrder.fees.sequencer) + int128(generalOrder.fees.liquidation))
        );
    }

    function test_processBatch_matchOrders_referralRebate_revertsIfExceedMaxRebateRate() public {
        vm.startPrank(sequencer);

        WrappedOrder memory generalOrder;
        generalOrder.isLiquidated = false;
        generalOrder.productId = 1;
        generalOrder.size = 5 * 1e18;
        generalOrder.price = 75_000 * 1e18;
        generalOrder.makerNonce = 66;
        generalOrder.takerNonce = 77;
        generalOrder.makerSide = IOrderBook.OrderSide.BUY;
        generalOrder.takerSide = IOrderBook.OrderSide.SELL;
        generalOrder.fees.maker = 2 * 1e12;
        generalOrder.fees.taker = 3 * 1e12;

        bytes memory makerEncodedOrder = _encodeOrder(
            makerSignerKey,
            IOrderBook.Order({
                sender: maker,
                size: generalOrder.size,
                price: generalOrder.price,
                nonce: generalOrder.makerNonce,
                productIndex: generalOrder.productId,
                orderSide: generalOrder.makerSide,
                orderHash: bytes32(0)
            }),
            generalOrder.isLiquidated,
            generalOrder.fees.maker
        );

        bytes memory takerEncodedOrder = _encodeOrder(
            takerSignerKey,
            IOrderBook.Order({
                sender: taker,
                size: generalOrder.size,
                price: generalOrder.price,
                nonce: generalOrder.takerNonce,
                productIndex: generalOrder.productId,
                orderSide: generalOrder.takerSide,
                orderHash: bytes32(0)
            }),
            generalOrder.isLiquidated,
            generalOrder.fees.taker
        );

        ReferralRebate memory referralRebate = ReferralRebate({
            makerReferrer: makeAddr("makerReferrer"),
            makerReferrerRebateRate: 0,
            takerReferrer: makeAddr("takerReferrer"),
            takerReferrerRebateRate: 0
        });

        for (uint256 i = 0; i < 2; i++) {
            uint16 invalidRebateRate = MAX_REBATE_RATE + 1;
            if (i == 0) {
                referralRebate.makerReferrerRebateRate = invalidRebateRate;
                referralRebate.takerReferrerRebateRate = 0;
            } else {
                referralRebate.makerReferrerRebateRate = 0;
                referralRebate.takerReferrerRebateRate = invalidRebateRate;
            }

            bytes memory operation = _encodeDataToOperation(
                IExchange.OperationType.MatchOrders,
                _encodeOrders(makerEncodedOrder, takerEncodedOrder, generalOrder.fees.sequencer, referralRebate)
            );

            vm.expectRevert(
                abi.encodeWithSelector(
                    Errors.Exchange_ExceededMaxRebateRate.selector, invalidRebateRate, MAX_REBATE_RATE
                )
            );
            exchange.processBatch(operation.toArray());
        }
    }

    function test_processBatch_mathOrders_rebateMaker() public {
        vm.startPrank(sequencer);

        WrappedOrder memory generalOrder;
        generalOrder.isLiquidated = false;
        generalOrder.productId = 1;
        generalOrder.size = 5 * 1e18;
        generalOrder.price = 75_000 * 1e18;
        generalOrder.makerNonce = 66;
        generalOrder.takerNonce = 77;
        generalOrder.makerSide = IOrderBook.OrderSide.BUY;
        generalOrder.takerSide = IOrderBook.OrderSide.SELL;
        generalOrder.fees.sequencer = 3 * 1e12;

        int128 rebateMaker = -2 * 1e12;
        generalOrder.fees.maker = rebateMaker;
        generalOrder.fees.taker = 3 * 1e12;

        ReferralRebate memory referralRebate = ReferralRebate({
            makerReferrer: makeAddr("makerReferrer"),
            makerReferrerRebateRate: 1000, // 10%
            takerReferrer: makeAddr("takerReferrer"),
            takerReferrerRebateRate: 500 // 5%
        });
        bytes memory operation;
        {
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                IOrderBook.Order({
                    sender: maker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.makerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.makerSide,
                    orderHash: bytes32(0)
                }),
                generalOrder.isLiquidated,
                rebateMaker
            );

            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                IOrderBook.Order({
                    sender: taker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.takerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.takerSide,
                    orderHash: bytes32(0)
                }),
                generalOrder.isLiquidated,
                generalOrder.fees.taker
            );

            operation = _encodeDataToOperation(
                IExchange.OperationType.MatchOrders,
                _encodeOrders(makerEncodedOrder, takerEncodedOrder, generalOrder.fees.sequencer, referralRebate)
            );

            // referrer rebate for only taker
            generalOrder.fees.takerReferralRebate =
                uint128(generalOrder.fees.taker).calculatePercentage(referralRebate.takerReferrerRebateRate);
        }

        // not charge maker fee
        generalOrder.fees.maker = 0;

        vm.expectEmit(address(exchange));
        emit IExchange.RebateMaker(maker, uint128(-rebateMaker), false);
        vm.expectEmit(address(orderbook));
        emit IOrderBook.OrderMatched(
            generalOrder.productId,
            maker,
            taker,
            generalOrder.makerSide,
            generalOrder.makerNonce,
            generalOrder.takerNonce,
            generalOrder.size,
            generalOrder.price,
            generalOrder.fees,
            generalOrder.isLiquidated
        );
        exchange.processBatch(operation.toArray());

        int256 makerReferrerBalance = exchange.balanceOf(referralRebate.makerReferrer, address(collateralToken));
        int256 takerReferrerBalance = exchange.balanceOf(referralRebate.takerReferrer, address(collateralToken));
        assertEq(uint256(makerReferrerBalance), 0);
        assertEq(
            uint256(takerReferrerBalance),
            uint128(generalOrder.fees.taker).calculatePercentage(referralRebate.takerReferrerRebateRate)
        );

        IOrderBook.FeeCollection memory tradingFees = orderbook.getTradingFees();
        assertEq(tradingFees.inUSDC, generalOrder.fees.taker - int128(generalOrder.fees.takerReferralRebate));

        IPerp.Balance memory makerPerpBalance = perpEngine.getOpenPosition(maker, generalOrder.productId);
        IPerp.Balance memory takerPerpBalance = perpEngine.getOpenPosition(taker, generalOrder.productId);

        // maker goes long
        assertEq(makerPerpBalance.size, int128(generalOrder.size));
        assertEq(makerPerpBalance.quoteBalance, -int128(generalOrder.size).mul18D(int128(generalOrder.price)));

        // taker goes short
        assertEq(takerPerpBalance.size, -int128(generalOrder.size));
        assertEq(
            takerPerpBalance.quoteBalance,
            int128(generalOrder.size).mul18D(int128(generalOrder.price)) - generalOrder.fees.taker
                - int128(generalOrder.fees.sequencer)
        );

        // rebate fee to Maker account
        assertEq(exchange.balanceOf(maker, address(collateralToken)), -rebateMaker);
    }

    function test_processBatch_matchLiquidatedOrders_rebateMaker_succeeds() public {
        vm.startPrank(sequencer);

        WrappedOrder memory generalOrder;
        generalOrder.isLiquidated = true;
        generalOrder.productId = 1;
        generalOrder.size = 5 * 1e18;
        generalOrder.price = 75_000 * 1e18;
        generalOrder.makerNonce = 66;
        generalOrder.takerNonce = 77;
        generalOrder.makerSide = IOrderBook.OrderSide.BUY;
        generalOrder.takerSide = IOrderBook.OrderSide.SELL;
        generalOrder.fees.sequencer = 5 * 1e12;

        int128 rebateMaker = -2 * 1e12;
        generalOrder.fees.maker = rebateMaker;
        generalOrder.fees.taker = 3 * 1e12;
        generalOrder.fees.liquidation = 4e12;

        ReferralRebate memory referralRebate = ReferralRebate({
            makerReferrer: makeAddr("makerReferrer"),
            makerReferrerRebateRate: 1000, // 10%
            takerReferrer: makeAddr("takerReferrer"),
            takerReferrerRebateRate: 500 // 5%
        });
        bytes memory operation;

        {
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                IOrderBook.Order({
                    sender: maker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.makerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.makerSide,
                    orderHash: bytes32(0)
                }),
                false,
                rebateMaker
            );

            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                IOrderBook.Order({
                    sender: taker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.takerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.takerSide,
                    orderHash: bytes32(0)
                }),
                generalOrder.isLiquidated,
                generalOrder.fees.taker
            );

            operation = _encodeDataToOperation(
                IExchange.OperationType.MatchLiquidationOrders,
                _encodeOrders(
                    makerEncodedOrder,
                    takerEncodedOrder,
                    generalOrder.fees.sequencer,
                    referralRebate,
                    generalOrder.fees.liquidation
                )
            );

            // referrer rebate for only taker
            generalOrder.fees.takerReferralRebate =
                uint128(generalOrder.fees.taker).calculatePercentage(referralRebate.takerReferrerRebateRate);
        }
        IClearingService.InsuranceFund memory insuranceFundBefore = clearingService.getInsuranceFundBalance();

        // not charge maker fee
        generalOrder.fees.maker = 0;

        vm.expectEmit();
        emit IOrderBook.OrderMatched(
            generalOrder.productId,
            maker,
            taker,
            generalOrder.makerSide,
            generalOrder.makerNonce,
            generalOrder.takerNonce,
            generalOrder.size,
            generalOrder.price,
            generalOrder.fees,
            generalOrder.isLiquidated
        );
        exchange.processBatch(operation.toArray());

        assertEq(uint256(exchange.balanceOf(referralRebate.makerReferrer, address(collateralToken))), 0);
        assertEq(
            uint256(exchange.balanceOf(referralRebate.takerReferrer, address(collateralToken))),
            uint128(generalOrder.fees.taker).calculatePercentage(referralRebate.takerReferrerRebateRate)
        );

        IOrderBook.FeeCollection memory tradingFees = orderbook.getTradingFees();
        assertEq(tradingFees.inUSDC, generalOrder.fees.taker - int128(generalOrder.fees.takerReferralRebate));

        IPerp.Balance memory makerPerpBalance = perpEngine.getOpenPosition(maker, generalOrder.productId);
        IPerp.Balance memory takerPerpBalance = perpEngine.getOpenPosition(taker, generalOrder.productId);

        // maker goes long
        assertEq(makerPerpBalance.size, int128(generalOrder.size));
        assertEq(makerPerpBalance.quoteBalance, -int128(generalOrder.size).mul18D(int128(generalOrder.price)));

        // taker goes short
        assertEq(takerPerpBalance.size, -int128(generalOrder.size));
        assertEq(
            takerPerpBalance.quoteBalance,
            int128(generalOrder.size).mul18D(int128(generalOrder.price)) - generalOrder.fees.taker
                - int128(generalOrder.fees.sequencer) - int128(generalOrder.fees.liquidation)
        );

        // rebate fee to Maker account
        assertEq(exchange.balanceOf(maker, address(collateralToken)), -rebateMaker);

        IClearingService.InsuranceFund memory insuranceFundAfter = clearingService.getInsuranceFundBalance();
        assertEq(insuranceFundAfter.inUSDC, insuranceFundBefore.inUSDC + generalOrder.fees.liquidation);
        assertEq(insuranceFundAfter.inBSX, insuranceFundBefore.inBSX);
    }

    function test_processBatch_matchLiquidatedOrders_rebateMaker_withBsxFees() public {
        vm.startPrank(sequencer);

        WrappedOrder memory generalOrder;
        generalOrder.isLiquidated = true;
        generalOrder.productId = 1;
        generalOrder.size = 5 * 1e18;
        generalOrder.price = 75_000 * 1e18;
        generalOrder.makerNonce = 66;
        generalOrder.takerNonce = 77;
        generalOrder.makerSide = IOrderBook.OrderSide.BUY;
        generalOrder.takerSide = IOrderBook.OrderSide.SELL;

        int128 rebateMaker = -2 * 1e12;
        generalOrder.fees.maker = rebateMaker;
        generalOrder.fees.taker = 3 * 1e12;
        generalOrder.fees.liquidation = 4e12;
        generalOrder.fees.sequencer = 5 * 1e12;
        generalOrder.fees.isMakerFeeInBSX = true;
        generalOrder.fees.isTakerFeeInBSX = true;

        ReferralRebate memory referralRebate = ReferralRebate({
            makerReferrer: makeAddr("makerReferrer"),
            makerReferrerRebateRate: 1000, // 10%
            takerReferrer: makeAddr("takerReferrer"),
            takerReferrerRebateRate: 500 // 5%
        });
        bytes memory operation;

        {
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                IOrderBook.Order({
                    sender: maker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.makerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.makerSide,
                    orderHash: bytes32(0)
                }),
                false,
                rebateMaker
            );

            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                IOrderBook.Order({
                    sender: taker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.takerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.takerSide,
                    orderHash: bytes32(0)
                }),
                generalOrder.isLiquidated,
                generalOrder.fees.taker
            );

            operation = _encodeDataToOperation(
                IExchange.OperationType.MatchLiquidationOrders,
                _encodeOrders(
                    makerEncodedOrder,
                    takerEncodedOrder,
                    generalOrder.fees.sequencer,
                    referralRebate,
                    generalOrder.fees.liquidation,
                    generalOrder.fees.isMakerFeeInBSX,
                    generalOrder.fees.isTakerFeeInBSX
                )
            );

            // referrer rebate for only taker
            generalOrder.fees.takerReferralRebate =
                uint128(generalOrder.fees.taker).calculatePercentage(referralRebate.takerReferrerRebateRate);
        }
        IClearingService.InsuranceFund memory insuranceFundBefore = clearingService.getInsuranceFundBalance();

        // not charge maker fee
        generalOrder.fees.maker = 0;

        vm.expectEmit(address(exchange));
        emit IExchange.RebateReferrer(
            referralRebate.takerReferrer,
            uint128(generalOrder.fees.taker).calculatePercentage(referralRebate.takerReferrerRebateRate),
            true
        );

        vm.expectEmit(address(exchange));
        emit IExchange.RebateMaker(maker, uint128(-rebateMaker), true);

        vm.expectEmit(address(orderbook));
        emit IOrderBook.OrderMatched(
            generalOrder.productId,
            maker,
            taker,
            generalOrder.makerSide,
            generalOrder.makerNonce,
            generalOrder.takerNonce,
            generalOrder.size,
            generalOrder.price,
            generalOrder.fees,
            generalOrder.isLiquidated
        );
        exchange.processBatch(operation.toArray());

        assertEq(uint256(exchange.balanceOf(referralRebate.makerReferrer, address(collateralToken))), 0);
        assertEq(uint256(exchange.balanceOf(referralRebate.takerReferrer, address(collateralToken))), 0);

        assertEq(uint256(exchange.balanceOf(referralRebate.makerReferrer, BSX_TOKEN)), 0);
        assertEq(
            uint256(exchange.balanceOf(referralRebate.takerReferrer, BSX_TOKEN)),
            uint128(generalOrder.fees.taker).calculatePercentage(referralRebate.takerReferrerRebateRate)
        );

        IOrderBook.FeeCollection memory tradingFees = orderbook.getTradingFees();
        assertEq(tradingFees.inUSDC, 0);
        assertEq(tradingFees.inBSX, generalOrder.fees.taker - int128(generalOrder.fees.takerReferralRebate));

        IPerp.Balance memory makerPerpBalance = perpEngine.getOpenPosition(maker, generalOrder.productId);
        IPerp.Balance memory takerPerpBalance = perpEngine.getOpenPosition(taker, generalOrder.productId);

        // maker goes long
        assertEq(makerPerpBalance.size, int128(generalOrder.size));
        assertEq(makerPerpBalance.quoteBalance, -int128(generalOrder.size).mul18D(int128(generalOrder.price)));

        // taker goes short
        IClearingService.InsuranceFund memory insuranceFundAfter = clearingService.getInsuranceFundBalance();
        assertEq(insuranceFundAfter.inUSDC, insuranceFundBefore.inUSDC);
        assertEq(insuranceFundAfter.inBSX, insuranceFundBefore.inBSX + generalOrder.fees.liquidation);

        assertEq(takerPerpBalance.size, -int128(generalOrder.size));
        assertEq(takerPerpBalance.quoteBalance, int128(generalOrder.size).mul18D(int128(generalOrder.price)));

        assertEq(exchange.balanceOf(maker, address(collateralToken)), 0);
        assertEq(exchange.balanceOf(maker, BSX_TOKEN), -rebateMaker);

        assertEq(exchange.balanceOf(taker, address(collateralToken)), 0);
        assertEq(
            exchange.balanceOf(taker, BSX_TOKEN),
            -(generalOrder.fees.taker + int128(generalOrder.fees.sequencer) + int128(generalOrder.fees.liquidation))
        );
    }

    function _accountSetup() private {
        (maker, makerKey) = makeAddrAndKey("maker");
        (makerSigner, makerSignerKey) = makeAddrAndKey("makerSigner");
        (taker, takerKey) = makeAddrAndKey("taker");
        (takerSigner, takerSignerKey) = makeAddrAndKey("takerSigner");

        _authorizeSigner(makerKey, makerSignerKey);
        _authorizeSigner(takerKey, takerSignerKey);
    }

    function _authorizeSigner(uint256 accountKey, uint256 signerKey) private {
        address account = vm.addr(accountKey);
        address signer = vm.addr(signerKey);

        string memory message = "message";
        uint64 nonce = 0;
        while (exchange.isRegisterSignerNonceUsed(account, nonce)) {
            nonce++;
        }

        bytes32 accountStructHash =
            keccak256(abi.encode(REGISTER_TYPEHASH, signer, keccak256(abi.encodePacked(message)), nonce));
        bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

        bytes32 signerStructHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, account));
        bytes memory signerSignature = _signTypedDataHash(signerKey, signerStructHash);

        bytes memory authorizeSignerData =
            abi.encode(IExchange.AddSigningWallet(account, signer, message, nonce, accountSignature, signerSignature));
        IExchange.OperationType opType = IExchange.OperationType.AddSigningWallet;
        uint32 transactionId = exchange.executedTransactionCounter();
        bytes memory opData = abi.encodePacked(opType, transactionId, authorizeSignerData);

        bytes[] memory data = new bytes[](1);
        data[0] = opData;
        exchange.processBatch(data);
    }

    function _encodeOrders(bytes memory makerEncodedOrder, bytes memory takerEncodedOrder, uint128 sequencerFee)
        private
        pure
        returns (bytes memory)
    {
        return _encodeOrders(makerEncodedOrder, takerEncodedOrder, sequencerFee, 0);
    }

    function _encodeOrders(
        bytes memory makerEncodedOrder,
        bytes memory takerEncodedOrder,
        uint128 sequencerFee,
        uint128 liquidationFee
    ) private pure returns (bytes memory) {
        ReferralRebate memory referralRebate;
        return _encodeOrders(makerEncodedOrder, takerEncodedOrder, sequencerFee, referralRebate, liquidationFee);
    }

    function _encodeOrders(
        bytes memory makerEncodedOrder,
        bytes memory takerEncodedOrder,
        uint128 sequencerFee,
        ReferralRebate memory referral
    ) private pure returns (bytes memory) {
        return _encodeOrders(makerEncodedOrder, takerEncodedOrder, sequencerFee, referral, 0);
    }

    function _encodeOrders(
        bytes memory makerEncodedOrder,
        bytes memory takerEncodedOrder,
        uint128 sequencerFee,
        ReferralRebate memory referral,
        uint128 liquidationFee
    ) private pure returns (bytes memory) {
        bytes memory encodedReferral = abi.encodePacked(
            referral.makerReferrer,
            referral.makerReferrerRebateRate,
            referral.takerReferrer,
            referral.takerReferrerRebateRate
        );
        return abi.encodePacked(makerEncodedOrder, takerEncodedOrder, sequencerFee, encodedReferral, liquidationFee);
    }

    function _encodeOrders(
        bytes memory makerEncodedOrder,
        bytes memory takerEncodedOrder,
        uint128 sequencerFee,
        ReferralRebate memory referral,
        uint128 liquidationFee,
        bool isMakerFeeInBSX,
        bool isTakerFeeInBSX
    ) private pure returns (bytes memory) {
        bytes memory encodedReferral = abi.encodePacked(
            referral.makerReferrer,
            referral.makerReferrerRebateRate,
            referral.takerReferrer,
            referral.takerReferrerRebateRate
        );
        return abi.encodePacked(
            makerEncodedOrder,
            takerEncodedOrder,
            sequencerFee,
            encodedReferral,
            liquidationFee,
            isMakerFeeInBSX,
            isTakerFeeInBSX
        );
    }

    function _encodeOrder(uint256 signerKey, IOrderBook.Order memory order, bool isLiquidated, int128 tradingFee)
        private
        view
        returns (bytes memory)
    {
        address signer = vm.addr(signerKey);
        return _encodeOrderWithSigner(signer, signerKey, order, isLiquidated, tradingFee);
    }

    function _encodeOrderWithSigner(
        address signer,
        uint256 signerKey,
        IOrderBook.Order memory order,
        bool isLiquidated,
        int128 tradingFee
    ) private view returns (bytes memory) {
        bytes memory signerSignature = _signTypedDataHash(
            signerKey,
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    order.sender,
                    order.size,
                    order.price,
                    order.nonce,
                    order.productIndex,
                    order.orderSide
                )
            )
        );
        return abi.encodePacked(
            order.sender,
            order.size,
            order.price,
            order.nonce,
            order.productIndex,
            order.orderSide,
            signerSignature,
            signer,
            isLiquidated,
            tradingFee
        );
    }

    function _encodeLiquidatedOrder(IOrderBook.Order memory order, bool isLiquidated, int128 tradingFee)
        private
        pure
        returns (bytes memory)
    {
        address mockSigner = address(0);
        bytes memory mockSignature = abi.encodePacked(bytes32(0), bytes32(0), uint8(0));
        return abi.encodePacked(
            order.sender,
            order.size,
            order.price,
            order.nonce,
            order.productIndex,
            order.orderSide,
            mockSignature,
            mockSigner,
            isLiquidated,
            tradingFee
        );
    }

    function _encodeDataToOperation(IExchange.OperationType operationType, bytes memory data)
        private
        view
        returns (bytes memory)
    {
        uint32 transactionId = exchange.executedTransactionCounter();
        return abi.encodePacked(operationType, transactionId, data);
    }

    function _signTypedDataHash(uint256 privateKey, bytes32 structHash) private view returns (bytes memory) {
        return Helper.signTypedDataHash(exchange, privateKey, structHash);
    }
}

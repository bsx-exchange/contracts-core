// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IExchange} from "../../interfaces/IExchange.sol";
import {IOrderBook} from "../../interfaces/IOrderBook.sol";
import {ISpot} from "../../interfaces/ISpot.sol";
import {Errors} from "../../lib/Errors.sol";
import {MathHelper} from "../../lib/MathHelper.sol";
import {Percentage} from "../../lib/Percentage.sol";
import {MAX_REBATE_RATE} from "../../share/Constants.sol";
import {GenericLogic} from "./GenericLogic.sol";

library OrderLogic {
    using MathHelper for int128;
    using MathHelper for uint128;
    using Percentage for uint128;

    enum OrderSide {
        BUY,
        SELL
    }

    struct Order {
        address sender;
        uint128 size;
        uint128 price;
        uint64 nonce;
        uint8 productIndex;
        OrderSide orderSide;
    }

    struct SignedOrder {
        Order order;
        bytes signature;
        address signer;
        bool isLiquidation;
    }

    struct MatchOrders {
        SignedOrder maker;
        SignedOrder taker;
    }

    struct OrderEngine {
        IOrderBook orderbook;
        ISpot spot;
    }

    bytes32 public constant ORDER_TYPEHASH =
        keccak256("Order(address sender,uint128 size,uint128 price,uint64 nonce,uint8 productIndex,uint8 orderSide)");

    /// @notice Match two non-liquidation orders
    function matchOrders(IExchange exchange, OrderEngine calldata engine, bytes calldata data) external {
        uint32 transactionId = uint32(bytes4(data[1:5]));

        SignedOrder memory maker;
        SignedOrder memory taker;
        IOrderBook.Fee memory matchFee;
        IOrderBook.OrderHash memory digest;

        // 165 bytes for an order
        (maker.order, maker.signature, maker.signer, maker.isLiquidation, matchFee.maker) =
            _parseDataToOrder(data[5:169]);
        digest.maker = _getOrderDigest(exchange.hashTypedDataV4, maker.order);
        GenericLogic.verifySignature(maker.signer, digest.maker, maker.signature);
        if (!exchange.isSigningWallet(maker.order.sender, maker.signer)) {
            revert Errors.Exchange_UnauthorizedSigner(maker.order.sender, maker.signer);
        }
        // 165 bytes for an order
        (taker.order, taker.signature, taker.signer, taker.isLiquidation, matchFee.taker) =
            _parseDataToOrder(data[169:333]);
        uint128 takerSequencerFee = uint128(bytes16(data[333:349])); //16 bytes for takerSequencerFee
        digest.taker = _getOrderDigest(exchange.hashTypedDataV4, taker.order);

        if (taker.isLiquidation || maker.isLiquidation) {
            revert Errors.Exchange_LiquidatedOrder(transactionId);
        }

        GenericLogic.verifySignature(taker.signer, digest.taker, taker.signature);
        if (!exchange.isSigningWallet(taker.order.sender, taker.signer)) {
            revert Errors.Exchange_UnauthorizedSigner(taker.order.sender, taker.signer);
        }

        if (maker.order.productIndex != taker.order.productIndex) {
            revert Errors.Exchange_ProductIdMismatch();
        }

        // 20 bytes is makerReferrer
        // 2 bytes is makerReferrerRebateRate
        // 20 bytes is takerReferrer
        // 2 bytes is takerReferrerRebateRate
        if (data.length > 349) {
            (address makerReferrer, uint16 makerReferrerRebateRate) = _parseReferralData(data[349:371]);
            matchFee.referralRebate += _rebateReferrer(engine, matchFee.maker, makerReferrer, makerReferrerRebateRate);

            (address takerReferrer, uint16 takerReferrerRebateRate) = _parseReferralData(data[371:393]);
            matchFee.referralRebate += _rebateReferrer(engine, matchFee.taker, takerReferrer, takerReferrerRebateRate);
        }
        matchFee.maker = _rebateMaker(engine, maker.order.sender, matchFee.maker);

        engine.orderbook.matchOrders(maker, taker, digest, maker.order.productIndex, takerSequencerFee, matchFee);
    }

    /// @notice Match a liquidation order with a non-liquidation order
    function matchLiquidationOrders(IExchange exchange, OrderEngine calldata engine, bytes calldata data) external {
        uint32 transactionId = uint32(bytes4(data[1:5]));

        SignedOrder memory maker;
        SignedOrder memory taker;
        IOrderBook.Fee memory matchFee;
        IOrderBook.OrderHash memory digest;

        // 165 bytes for an order
        (maker.order, maker.signature, maker.signer, maker.isLiquidation, matchFee.maker) =
            _parseDataToOrder(data[5:169]);
        digest.maker = _getOrderDigest(exchange.hashTypedDataV4, maker.order);

        // 165 bytes for an order
        (taker.order, taker.signature, taker.signer, taker.isLiquidation, matchFee.taker) =
            _parseDataToOrder(data[169:333]);
        uint128 takerSequencerFee = uint128(bytes16(data[333:349])); //16 bytes for takerSequencerFee
        digest.taker = _getOrderDigest(exchange.hashTypedDataV4, taker.order);

        if (!taker.isLiquidation) {
            revert Errors.Exchange_NotLiquidatedOrder(transactionId);
        }
        if (maker.isLiquidation) {
            revert Errors.Exchange_MakerLiquidatedOrder(transactionId);
        }

        GenericLogic.verifySignature(maker.signer, digest.maker, maker.signature);
        if (!exchange.isSigningWallet(maker.order.sender, maker.signer)) {
            revert Errors.Exchange_UnauthorizedSigner(maker.order.sender, maker.signer);
        }

        if (maker.order.productIndex != taker.order.productIndex) {
            revert Errors.Exchange_ProductIdMismatch();
        }

        // 20 bytes is makerReferrer
        // 2 bytes is makerReferrerRebateRate
        // 20 bytes is takerReferrer
        // 2 bytes is takerReferrerRebateRate
        if (data.length > 349) {
            (address makerReferrer, uint16 makerReferrerRebateRate) = _parseReferralData(data[349:371]);
            matchFee.referralRebate += _rebateReferrer(engine, matchFee.maker, makerReferrer, makerReferrerRebateRate);

            (address takerReferrer, uint16 takerReferrerRebateRate) = _parseReferralData(data[371:393]);
            matchFee.referralRebate += _rebateReferrer(engine, matchFee.taker, takerReferrer, takerReferrerRebateRate);
        }
        matchFee.maker = _rebateMaker(engine, maker.order.sender, matchFee.maker);

        // 16 bytes is liquidation fee
        if (data.length > 393) {
            uint128 liquidationFee = uint128(bytes16(data[393:409])); //16 bytes for liquidation fee
            matchFee.liquidationPenalty = liquidationFee;
        }

        engine.orderbook.matchOrders(maker, taker, digest, maker.order.productIndex, takerSequencerFee, matchFee);
    }

    /// @dev Hash an order using EIP712
    function _getOrderDigest(function (bytes32) external view returns(bytes32) _hashTypedDataV4, Order memory order)
        internal
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
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
    }

    /// @dev Parse encoded data to order
    function _parseDataToOrder(bytes calldata data)
        internal
        pure
        returns (Order memory, bytes memory signature, address signer, bool isLiquidation, int128 matchFee)
    {
        //Fisrt 20 bytes is sender
        //next  16 bytes is size
        //next  16 bytes is price
        //next  8 bytes is nonce
        //next  1 byte is product index
        //next  1 byte is order side
        //next  65 bytes is signature
        //next  20 bytes is signer
        //next  1 byte is isLiquidation
        //next  16 bytes is match fee
        //sum 164
        Order memory order;
        order.sender = address(bytes20(data[0:20]));
        order.size = uint128(bytes16(data[20:36]));
        order.price = uint128(bytes16(data[36:52]));
        order.nonce = uint64(bytes8(data[52:60]));
        order.productIndex = uint8(data[60]);
        order.orderSide = OrderSide(uint8(data[61]));
        signature = data[62:127];
        signer = address(bytes20(data[127:147]));
        isLiquidation = uint8(data[147]) == 1;
        matchFee = int128(uint128(bytes16(data[148:164])));

        return (order, signature, signer, isLiquidation, matchFee);
    }

    /// @dev Parses referral data from encoded data
    /// @param data Encoded data
    function _parseReferralData(bytes calldata data)
        internal
        pure
        returns (address referrer, uint16 referrerRebateRate)
    {
        // 20 bytes is referrer
        // 2 bytes is referrer rebate rate
        referrer = address(bytes20(data[0:20]));
        referrerRebateRate = uint16(bytes2(data[20:22]));
    }

    /// @dev Calculate the fee and rebate for an order
    function _rebateReferrer(OrderEngine calldata engine, int128 fee, address referrer, uint16 rebateRate)
        internal
        returns (uint128 rebate)
    {
        if (referrer == address(0) || rebateRate == 0 || fee <= 0) {
            return 0;
        }

        if (rebateRate > MAX_REBATE_RATE) {
            revert Errors.Exchange_ExceededMaxRebateRate(rebateRate, MAX_REBATE_RATE);
        }

        rebate = fee.safeUInt128().calculatePercentage(rebateRate);

        ISpot.AccountDelta[] memory productDeltas = new ISpot.AccountDelta[](1);
        productDeltas[0] = ISpot.AccountDelta(engine.orderbook.getCollateralToken(), referrer, rebate.safeInt128());
        engine.spot.modifyAccount(productDeltas);

        emit IExchange.RebateReferrer(referrer, rebate);
    }

    /// @dev Rebate maker if the fee is defined as negative
    /// @return Maker fee after rebate
    function _rebateMaker(OrderEngine calldata engine, address maker, int128 fee) internal returns (int128) {
        if (fee >= 0) {
            return fee;
        }

        uint128 rebate = fee.abs();
        ISpot.AccountDelta[] memory productDeltas = new ISpot.AccountDelta[](1);
        productDeltas[0] = ISpot.AccountDelta(engine.orderbook.getCollateralToken(), maker, rebate.safeInt128());
        engine.spot.modifyAccount(productDeltas);

        emit IExchange.RebateMaker(maker, rebate);

        return 0;
    }
}

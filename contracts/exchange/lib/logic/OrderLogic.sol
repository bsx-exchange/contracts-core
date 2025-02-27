// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IExchange} from "../../interfaces/IExchange.sol";
import {IOrderBook} from "../../interfaces/IOrderBook.sol";
import {ISpot} from "../../interfaces/ISpot.sol";
import {Errors} from "../../lib/Errors.sol";
import {MathHelper} from "../../lib/MathHelper.sol";
import {Percentage} from "../../lib/Percentage.sol";
import {BSX_TOKEN, MAX_REBATE_RATE} from "../../share/Constants.sol";
import {GenericLogic} from "./GenericLogic.sol";

library OrderLogic {
    using MathHelper for int128;
    using MathHelper for uint128;
    using Percentage for uint128;

    uint256 private constant TRANSACTION_ID_BYTES = 4;
    uint256 private constant ORDER_BYTES = 164;
    uint256 private constant SEQUENCER_FEE_BYTES = 16;
    uint256 private constant REFERRAL_BYTES = 22;
    uint256 private constant LIQUIDATION_FEE_BYTES = 16;
    uint256 private constant IS_FEE_IN_BSX_BYTES = 1;

    struct SignedOrder {
        IOrderBook.Order order;
        bytes signature;
        address signer;
        bool isLiquidation;
    }

    struct OrderEngine {
        IOrderBook orderbook;
        ISpot spot;
    }

    bytes32 public constant ORDER_TYPEHASH =
        keccak256("Order(address sender,uint128 size,uint128 price,uint64 nonce,uint8 productIndex,uint8 orderSide)");

    /// @notice Match two non-liquidation orders
    function matchOrders(IExchange exchange, OrderEngine calldata engine, bytes calldata data) external {
        WrappedData memory wd = _decodeData(data);

        wd.maker.order.orderHash = _getOrderDigest(exchange.hashTypedDataV4, wd.maker.order);
        GenericLogic.verifySignature(wd.maker.signer, wd.maker.order.orderHash, wd.maker.signature);
        if (!exchange.isSigningWallet(wd.maker.order.sender, wd.maker.signer)) {
            revert Errors.Exchange_UnauthorizedSigner(wd.maker.order.sender, wd.maker.signer);
        }

        wd.taker.order.orderHash = _getOrderDigest(exchange.hashTypedDataV4, wd.taker.order);
        GenericLogic.verifySignature(wd.taker.signer, wd.taker.order.orderHash, wd.taker.signature);
        if (!exchange.isSigningWallet(wd.taker.order.sender, wd.taker.signer)) {
            revert Errors.Exchange_UnauthorizedSigner(wd.taker.order.sender, wd.taker.signer);
        }

        if (wd.taker.isLiquidation || wd.maker.isLiquidation) {
            revert Errors.Exchange_LiquidatedOrder(wd.transactionId);
        }

        if (wd.maker.order.productIndex != wd.taker.order.productIndex) {
            revert Errors.Exchange_ProductIdMismatch();
        }

        wd.fees.makerReferralRebate = _rebateReferrer(engine, wd.makerReferral, wd.fees.maker, wd.fees.isMakerFeeInBSX);
        wd.fees.takerReferralRebate = _rebateReferrer(engine, wd.takerReferral, wd.fees.taker, wd.fees.isTakerFeeInBSX);

        wd.fees.maker = _rebateMaker(engine, wd.maker.order.sender, wd.fees.maker, wd.fees.isMakerFeeInBSX);

        engine.orderbook.matchOrders(
            wd.maker.order.productIndex, wd.maker.order, wd.taker.order, wd.fees, wd.taker.isLiquidation
        );
    }

    /// @notice Match a liquidation order with a non-liquidation order
    function matchLiquidationOrders(IExchange exchange, OrderEngine calldata engine, bytes calldata data) external {
        WrappedData memory wd = _decodeData(data);

        wd.maker.order.orderHash = _getOrderDigest(exchange.hashTypedDataV4, wd.maker.order);
        GenericLogic.verifySignature(wd.maker.signer, wd.maker.order.orderHash, wd.maker.signature);
        if (!exchange.isSigningWallet(wd.maker.order.sender, wd.maker.signer)) {
            revert Errors.Exchange_UnauthorizedSigner(wd.maker.order.sender, wd.maker.signer);
        }

        wd.taker.order.orderHash = _getOrderDigest(exchange.hashTypedDataV4, wd.taker.order);

        if (!wd.taker.isLiquidation) {
            revert Errors.Exchange_NotLiquidatedOrder(wd.transactionId);
        }
        if (wd.maker.isLiquidation) {
            revert Errors.Exchange_MakerLiquidatedOrder(wd.transactionId);
        }

        if (wd.maker.order.productIndex != wd.taker.order.productIndex) {
            revert Errors.Exchange_ProductIdMismatch();
        }

        wd.fees.makerReferralRebate = _rebateReferrer(engine, wd.makerReferral, wd.fees.maker, wd.fees.isMakerFeeInBSX);
        wd.fees.takerReferralRebate = _rebateReferrer(engine, wd.takerReferral, wd.fees.taker, wd.fees.isTakerFeeInBSX);

        wd.fees.maker = _rebateMaker(engine, wd.maker.order.sender, wd.fees.maker, wd.fees.isMakerFeeInBSX);

        engine.orderbook.matchOrders(
            wd.maker.order.productIndex, wd.maker.order, wd.taker.order, wd.fees, wd.taker.isLiquidation
        );
    }

    /// @dev Hash an order using EIP712
    function _getOrderDigest(
        function (bytes32) external view returns(bytes32) _hashTypedDataV4,
        IOrderBook.Order memory order
    ) internal view returns (bytes32) {
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

    /// @dev Calculate the fee and rebate for an order
    function _rebateReferrer(OrderEngine calldata engine, Referral memory referral, int128 fee, bool isFeeInBSX)
        internal
        returns (uint128 rebate)
    {
        if (referral.referrer == address(0) || referral.rebateRate == 0 || fee <= 0) {
            return 0;
        }

        if (referral.rebateRate > MAX_REBATE_RATE) {
            revert Errors.Exchange_ExceededMaxRebateRate(referral.rebateRate, MAX_REBATE_RATE);
        }

        rebate = fee.safeUInt128().calculatePercentage(referral.rebateRate);

        address token = isFeeInBSX ? BSX_TOKEN : engine.orderbook.getCollateralToken();
        engine.spot.updateBalance(referral.referrer, token, rebate.safeInt128());

        emit IExchange.RebateReferrer(referral.referrer, rebate, isFeeInBSX);
    }

    /// @dev Rebate maker if the fee is defined as negative
    /// @return Maker fee after rebate
    function _rebateMaker(OrderEngine calldata engine, address maker, int128 fee, bool isFeeInBSX)
        internal
        returns (int128)
    {
        if (fee >= 0) {
            return fee;
        }

        uint128 rebate = fee.abs();
        address token = isFeeInBSX ? BSX_TOKEN : engine.orderbook.getCollateralToken();
        engine.spot.updateBalance(maker, token, rebate.safeInt128());

        emit IExchange.RebateMaker(maker, rebate, isFeeInBSX);

        return 0;
    }

    enum DataType {
        TransactionId,
        MakerOrder,
        TakerOrder,
        TakerSequencerFee,
        MakerReferrer,
        TakerReferrer,
        LiquidationFee,
        IsMakerFeeInBSX,
        IsTakerFeeInBSX
    }

    function _getDataIndexRange(DataType t) private pure returns (uint256 startIdx, uint256 endIdx) {
        startIdx = 0;
        endIdx += TRANSACTION_ID_BYTES;
        if (t == DataType.TransactionId) {
            return (startIdx, endIdx);
        }

        startIdx = endIdx;
        endIdx += ORDER_BYTES;
        if (t == DataType.MakerOrder) {
            return (startIdx, endIdx);
        }

        startIdx = endIdx;
        endIdx += ORDER_BYTES;
        if (t == DataType.TakerOrder) {
            return (startIdx, endIdx);
        }

        startIdx = endIdx;
        endIdx += SEQUENCER_FEE_BYTES;
        if (t == DataType.TakerSequencerFee) {
            return (startIdx, endIdx);
        }

        startIdx = endIdx;
        endIdx += REFERRAL_BYTES;
        if (t == DataType.MakerReferrer) {
            return (startIdx, endIdx);
        }

        startIdx = endIdx;
        endIdx += REFERRAL_BYTES;
        if (t == DataType.TakerReferrer) {
            return (startIdx, endIdx);
        }

        startIdx = endIdx;
        endIdx += LIQUIDATION_FEE_BYTES;
        if (t == DataType.LiquidationFee) {
            return (startIdx, endIdx);
        }

        startIdx = endIdx;
        endIdx += IS_FEE_IN_BSX_BYTES;
        if (t == DataType.IsMakerFeeInBSX) {
            return (startIdx, endIdx);
        }

        startIdx = endIdx;
        endIdx += IS_FEE_IN_BSX_BYTES;
        if (t == DataType.IsTakerFeeInBSX) {
            return (startIdx, endIdx);
        }
    }

    struct Referral {
        address referrer;
        uint16 rebateRate;
    }

    struct WrappedData {
        uint32 transactionId;
        SignedOrder maker;
        SignedOrder taker;
        IOrderBook.Fees fees;
        Referral makerReferral;
        Referral takerReferral;
    }

    function _decodeData(bytes calldata data) private pure returns (WrappedData memory wrappedData) {
        (uint256 from, uint256 to) = _getDataIndexRange(DataType.TransactionId);
        wrappedData.transactionId = uint32(bytes4(data[from:to]));

        (from, to) = _getDataIndexRange(DataType.MakerOrder);
        (wrappedData.maker, wrappedData.fees.maker) = _decodeSignedOrder(data[from:to]);

        (from, to) = _getDataIndexRange(DataType.TakerOrder);
        (wrappedData.taker, wrappedData.fees.taker) = _decodeSignedOrder(data[from:to]);

        (from, to) = _getDataIndexRange(DataType.TakerSequencerFee);
        wrappedData.fees.sequencer = uint128(bytes16(data[from:to]));

        (from, to) = _getDataIndexRange(DataType.MakerReferrer);
        wrappedData.makerReferral = _decodeReferralData(data[from:to]);

        (from, to) = _getDataIndexRange(DataType.TakerReferrer);
        wrappedData.takerReferral = _decodeReferralData(data[from:to]);

        (from, to) = _getDataIndexRange(DataType.LiquidationFee);
        wrappedData.fees.liquidation = uint128(bytes16(data[from:to]));

        // avoid breaking changes
        if (data.length == to) {
            return wrappedData;
        }

        (from, to) = _getDataIndexRange(DataType.IsMakerFeeInBSX);
        wrappedData.fees.isMakerFeeInBSX = uint8(data[from]) != 0;

        (from, to) = _getDataIndexRange(DataType.IsTakerFeeInBSX);
        wrappedData.fees.isTakerFeeInBSX = uint8(data[from]) != 0;
    }

    /// @dev Parse encoded data to order
    function _decodeSignedOrder(bytes calldata data)
        internal
        pure
        returns (SignedOrder memory signedOrder, int128 tradingFee)
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
        //next  16 bytes is trading fee
        //sum 164
        signedOrder.order.sender = address(bytes20(data[0:20]));
        signedOrder.order.size = uint128(bytes16(data[20:36]));
        signedOrder.order.price = uint128(bytes16(data[36:52]));
        signedOrder.order.nonce = uint64(bytes8(data[52:60]));
        signedOrder.order.productIndex = uint8(data[60]);
        signedOrder.order.orderSide = IOrderBook.OrderSide(uint8(data[61]));
        signedOrder.signature = data[62:127];
        signedOrder.signer = address(bytes20(data[127:147]));
        signedOrder.isLiquidation = uint8(data[147]) == 1;
        tradingFee = int128(uint128(bytes16(data[148:164])));

        return (signedOrder, tradingFee);
    }

    /// @dev Parses referral data from encoded data
    /// @param data Encoded data
    function _decodeReferralData(bytes calldata data) internal pure returns (Referral memory referral) {
        // 20 bytes is referrer
        // 2 bytes is referrer rebate rate
        referral.referrer = address(bytes20(data[0:20]));
        referral.rebateRate = uint16(bytes2(data[20:22]));
    }
}

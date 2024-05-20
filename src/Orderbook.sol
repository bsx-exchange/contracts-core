// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Gateway} from "./abstracts/Gateway.sol";
import {IAccess} from "./interfaces/IAccess.sol";
import {IClearinghouse} from "./interfaces/IClearinghouse.sol";
import {IOrderbook} from "./interfaces/IOrderbook.sol";
import {IPerpEngine} from "./interfaces/IPerpEngine.sol";
import {ISpotEngine} from "./interfaces/ISpotEngine.sol";
import {Errors} from "./libraries/Errors.sol";
import {Math} from "./libraries/Math.sol";
import {OrderSide} from "./types/DataTypes.sol";

/// @title Orderbook contract
/// @notice This contract is used for matching orders
/// @dev This contract is upgradeable
contract Orderbook is Gateway, IOrderbook, Initializable {
    using Math for int128;
    using Math for uint128;

    uint128 public constant MAX_TRADING_FEE_RATE = 2e16; // 2%
    uint128 public constant MAX_SEQUENCER_FEE = 1e18; // 1$
    uint128 public constant LIQUIDATION_FEE_RATE = 1e16; // 1%

    IClearinghouse public clearinghouse;
    ISpotEngine public spotEngine;
    IPerpEngine public perpEngine;
    IAccess public access;

    ///@notice manage the fullfiled amount of an order
    mapping(bytes32 hashedOrder => uint128 amount) public filled;
    mapping(address account => mapping(uint64 nonce => bool used)) public isNonceUsed;

    uint128 private _collectedTradingFee;

    mapping(uint8 productId => int256 fee) private _legacySequencerFee; //deprecated

    address private _collateralToken;
    uint256 private _collectedSequencerFee;

    function initialize(
        address clearinghouse_,
        address spotEngine_,
        address perpEngine_,
        address access_,
        address collateralToken_
    ) public initializer {
        if (
            clearinghouse_ == address(0) || spotEngine_ == address(0) || perpEngine_ == address(0)
                || access_ == address(0) || collateralToken_ == address(0)
        ) {
            revert Errors.ZeroAddress();
        }

        clearinghouse = IClearinghouse(clearinghouse_);
        spotEngine = ISpotEngine(spotEngine_);
        perpEngine = IPerpEngine(perpEngine_);
        access = IAccess(access_);
        _collateralToken = collateralToken_;
    }

    // solhint-disable code-complexity
    /// @inheritdoc IOrderbook
    function matchOrders(
        uint8 productId,
        Order calldata makerOrder,
        Order calldata takerOrder,
        Fee calldata fee,
        bool isLquidated
    ) external override authorized {
        if (makerOrder.orderSide == takerOrder.orderSide || makerOrder.account == takerOrder.account) {
            revert Errors.Orderbook_InvalidOrder();
        }

        _validateNonce(makerOrder.account, makerOrder.nonce);
        _validateNonce(takerOrder.account, takerOrder.nonce);

        _validatePrice(makerOrder.orderSide, makerOrder.price, takerOrder.price);

        uint128 matchedBaseAmount =
            Math.min(makerOrder.size - filled[makerOrder.orderHash], takerOrder.size - filled[makerOrder.orderHash]);
        uint128 matchedQuoteAmount = matchedBaseAmount.mul18D(makerOrder.price);

        _validateFee(fee, matchedQuoteAmount);

        uint128 makerFee = fee.maker;
        uint128 takerFee = fee.taker;
        _collectTradingFee(makerFee, takerFee, fee.referralRebate);

        if (filled[takerOrder.orderHash] == 0) {
            _collectedSequencerFee += fee.sequencer;
            takerFee += fee.sequencer;
        }
        if (isLquidated) {
            uint128 liquidationFee = matchedQuoteAmount.mul18D(LIQUIDATION_FEE_RATE);
            _collectedTradingFee += liquidationFee;
            takerFee += liquidationFee;
        }

        filled[makerOrder.orderHash] += matchedBaseAmount;
        filled[takerOrder.orderHash] += matchedBaseAmount;
        if (filled[makerOrder.orderHash] == makerOrder.size) {
            isNonceUsed[makerOrder.account][makerOrder.nonce] = true;
        }
        if (filled[takerOrder.orderHash] == takerOrder.size) {
            isNonceUsed[takerOrder.account][takerOrder.nonce] = true;
        }

        // avoid "stack too deep"
        {
            int128 makerPnl;
            int128 takerPnl;
            int128 makerBaseAmount;
            int128 makerQuoteAmount;
            if (makerOrder.orderSide == OrderSide.LONG) {
                makerBaseAmount = int128(matchedBaseAmount);
                makerQuoteAmount = -int128(matchedQuoteAmount);

                makerPnl = perpEngine.settlePositionPnl(
                    productId, makerOrder.account, makerBaseAmount, makerQuoteAmount - int128(makerFee)
                );
                takerPnl = perpEngine.settlePositionPnl(
                    productId, takerOrder.account, -makerBaseAmount, -makerQuoteAmount - int128(takerFee)
                );
            } else {
                makerBaseAmount = -int128(matchedBaseAmount);
                makerQuoteAmount = int128(matchedQuoteAmount);

                makerPnl = perpEngine.settlePositionPnl(
                    productId, makerOrder.account, makerBaseAmount, makerQuoteAmount - int128(makerFee)
                );
                takerPnl = perpEngine.settlePositionPnl(
                    productId, takerOrder.account, -makerBaseAmount, -makerQuoteAmount - int128(takerFee)
                );
            }

            if (makerPnl != 0) {
                spotEngine.updateAccount(makerOrder.account, _collateralToken, makerPnl);
            }
            if (takerPnl != 0) {
                spotEngine.updateAccount(takerOrder.account, _collateralToken, takerPnl);
            }
        }

        emit OrderMatched(
            productId,
            makerOrder.account,
            takerOrder.account,
            makerOrder.orderSide,
            makerOrder.nonce,
            takerOrder.nonce,
            matchedBaseAmount,
            makerOrder.price,
            fee,
            isLquidated
        );
    }

    /// @inheritdoc IOrderbook
    function claimCollectedSequencerFees() external override authorized returns (uint256) {
        uint256 totalFee = _collectedSequencerFee;
        _collectedSequencerFee = 0;
        return totalFee;
    }

    /// @inheritdoc IOrderbook
    function claimCollectedTradingFees() external override authorized returns (uint256) {
        uint256 totalFee = _collectedTradingFee;
        _collectedTradingFee = 0;
        return totalFee;
    }

    /// @inheritdoc IOrderbook
    function getCollateralToken() external view override returns (address) {
        return _collateralToken;
    }

    /// @inheritdoc IOrderbook
    function getCollectedSequencerFees() external view override returns (uint256) {
        return _collectedSequencerFee;
    }

    /// @inheritdoc IOrderbook
    function getCollectedTradingFees() external view override returns (uint256) {
        return _collectedTradingFee;
    }

    /// @inheritdoc Gateway
    function _isAuthorized(address caller) internal view override returns (bool) {
        return caller == access.getExchange();
    }

    function _collectTradingFee(uint128 makerFee, uint128 takerFee, uint128 referralRebate) private {
        uint128 fee = makerFee + takerFee - referralRebate;
        _collectedTradingFee += fee;
    }

    function _validateNonce(address account, uint64 nonce) private view {
        if (isNonceUsed[account][nonce]) {
            revert Errors.Orderbook_UsedNonce(account, nonce);
        }
    }

    function _validateFee(Fee calldata fee, uint128 quoteAmount) private pure {
        if (
            fee.maker > quoteAmount.mul18D(MAX_TRADING_FEE_RATE) || fee.taker > quoteAmount.mul18D(MAX_TRADING_FEE_RATE)
        ) {
            revert Errors.Orderbook_ExceededMaxTradingFee();
        }
        if (fee.sequencer > MAX_SEQUENCER_FEE) {
            revert Errors.Orderbook_ExceededMaxSequencerFee();
        }
        if (fee.referralRebate > fee.maker + fee.taker) {
            revert Errors.Orderbook_InvalidReferralFee();
        }
    }

    function _validatePrice(OrderSide makerSide, uint128 makerPrice, uint128 takerPrice) private pure {
        if (makerSide == OrderSide.LONG && makerPrice < takerPrice) {
            revert Errors.Orderbook_InvalidPrice();
        } else if (makerSide == OrderSide.SHORT && makerPrice > takerPrice) {
            revert Errors.Orderbook_InvalidPrice();
        }
    }
}

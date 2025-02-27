// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Access} from "./access/Access.sol";
import {IClearingService} from "./interfaces/IClearingService.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {IPerp} from "./interfaces/IPerp.sol";
import {ISpot} from "./interfaces/ISpot.sol";
import {Errors} from "./lib/Errors.sol";
import {MathHelper} from "./lib/MathHelper.sol";
import {Percentage} from "./lib/Percentage.sol";
import {
    BSX_ORACLE,
    BSX_TOKEN,
    MAX_LIQUIDATION_FEE_RATE,
    MAX_TAKER_SEQUENCER_FEE_IN_USD,
    MAX_TRADING_FEE_RATE
} from "./share/Constants.sol";

/// @title Orderbook contract
/// @notice This contract is used for matching orders
/// @dev This contract is upgradeable
contract OrderBook is IOrderBook, Initializable {
    using MathHelper for int128;
    using MathHelper for uint128;
    using Percentage for uint128;
    using SafeCast for uint256;

    IClearingService public clearingService;
    ISpot public spotEngine;
    IPerp public perpEngine;
    Access public access;

    ///@notice manage the fullfiled amount of an order
    mapping(bytes32 orderHash => uint128 filledAmount) public filled;
    mapping(address account => mapping(uint64 nonce => bool used)) public isNonceUsed;

    FeeCollection private _tradingFees;
    mapping(uint8 productId => int256 fee) private _sequencerFee; //deprecated
    address private _collateralToken;
    FeeCollection private _sequencerFees;

    uint128 private constant BSX_FEE_MULTIPLIER = 10;

    // function initialize(
    //     address _clearingService,
    //     address _spotEngine,
    //     address _perpEngine,
    //     address _access,
    //     address _collateralToken
    // ) public initializer {
    //     if (
    //         _clearingService == address(0) || _spotEngine == address(0) || _perpEngine == address(0)
    //             || _access == address(0) || _collateralToken == address(0)
    //     ) {
    //         revert Errors.ZeroAddress();
    //     }
    //     clearingService = IClearingService(_clearingService);
    //     spotEngine = ISpot(_spotEngine);
    //     perpEngine = IPerp(_perpEngine);
    //     access = Access(_access);
    //     collateralToken = _collateralToken;
    // }

    modifier onlySequencer() {
        if (msg.sender != address(access.getExchange())) {
            revert Errors.Unauthorized();
        }
        _;
    }

    /// @inheritdoc IOrderBook
    // solhint-disable code-complexity
    function matchOrders(
        uint8 productIndex,
        Order calldata maker,
        Order calldata taker,
        Fees calldata fees,
        bool isLiquidation
    ) external onlySequencer {
        if (maker.orderSide == taker.orderSide) {
            revert Errors.Orderbook_OrdersWithSameSides();
        }
        if (maker.sender == taker.sender) {
            revert Errors.Orderbook_OrdersWithSameAccounts();
        }

        uint128 fillAmount = MathHelper.min(maker.size - filled[maker.orderHash], taker.size - filled[taker.orderHash]);
        _verifyUsedNonce(maker.sender, maker.nonce);
        _verifyUsedNonce(taker.sender, taker.nonce);

        _validatePrice(maker.orderSide, maker.price, taker.price);
        uint128 price = maker.price;

        Delta memory takerDelta;
        Delta memory makerDelta;
        if (taker.orderSide == OrderSide.SELL) {
            takerDelta.productAmount = -fillAmount.safeInt128();
            makerDelta.productAmount = fillAmount.safeInt128();
            takerDelta.quoteAmount = price.mul18D(fillAmount).safeInt128();
            makerDelta.quoteAmount = -takerDelta.quoteAmount;
        } else {
            takerDelta.productAmount = fillAmount.safeInt128();
            makerDelta.productAmount = -fillAmount.safeInt128();
            makerDelta.quoteAmount = price.mul18D(fillAmount).safeInt128();
            takerDelta.quoteAmount = -makerDelta.quoteAmount;
        }

        uint128 bsxPriceUSD;
        if (fees.isMakerFeeInBSX || fees.isTakerFeeInBSX) {
            bsxPriceUSD = BSX_ORACLE.getTokenPriceInUsd(BSX_TOKEN).toUint128();
        }
        _validateTradingFee(fees.maker, makerDelta.quoteAmount.abs(), fees.isMakerFeeInBSX, bsxPriceUSD);
        _validateTradingFee(fees.taker, takerDelta.quoteAmount.abs(), fees.isTakerFeeInBSX, bsxPriceUSD);
        _validateSequencerFee(fees.sequencer, fees.isTakerFeeInBSX, bsxPriceUSD);

        FeesInBSX memory feesInBSX;

        if (isLiquidation) {
            _collectLiquidationFee(fees.liquidation, taker, takerDelta);
        }

        _collectTradingFees(fees, makerDelta, takerDelta, feesInBSX);

        if (filled[taker.orderHash] == 0) {
            _collectSequencerFee(fees.sequencer.safeInt128(), fees.isTakerFeeInBSX, takerDelta, feesInBSX);
        }

        _collectFeesInBSX(feesInBSX, maker.sender, taker.sender);

        filled[maker.orderHash] += fillAmount;
        filled[taker.orderHash] += fillAmount;
        if (maker.size == filled[maker.orderHash]) {
            isNonceUsed[maker.sender][maker.nonce] = true;
        }
        if (taker.size == filled[taker.orderHash]) {
            isNonceUsed[taker.sender][taker.nonce] = true;
        }
        (makerDelta.quoteAmount, makerDelta.productAmount) =
            _settleBalance(productIndex, maker.sender, makerDelta.productAmount, makerDelta.quoteAmount, price);

        //handle taker position settle
        (takerDelta.quoteAmount, takerDelta.productAmount) =
            _settleBalance(productIndex, taker.sender, takerDelta.productAmount, takerDelta.quoteAmount, price);

        _updatePerpAccounts(productIndex, maker, taker, makerDelta, takerDelta);

        emit OrderMatched(
            productIndex,
            maker.sender,
            taker.sender,
            maker.orderSide,
            maker.nonce,
            taker.nonce,
            fillAmount,
            price,
            fees,
            isLiquidation
        );
    }

    /// @inheritdoc IOrderBook
    function claimTradingFees() external onlySequencer returns (FeeCollection memory tradingFees) {
        tradingFees = _tradingFees;
        delete _tradingFees;
    }

    /// @inheritdoc IOrderBook
    function claimSequencerFees() external onlySequencer returns (FeeCollection memory sequencerFees) {
        sequencerFees = _sequencerFees;
        delete _sequencerFees;
    }

    /// @inheritdoc IOrderBook
    function getCollateralToken() external view returns (address) {
        return _collateralToken;
    }

    /// @inheritdoc IOrderBook
    function getTradingFees() external view returns (FeeCollection memory) {
        return _tradingFees;
    }

    /// @inheritdoc IOrderBook
    function getSequencerFees() external view returns (FeeCollection memory) {
        return _sequencerFees;
    }

    /// @inheritdoc IOrderBook
    function isMatched(address _userA, uint64 _nonceA, address _userB, uint64 _nonceB) external view returns (bool) {
        return isNonceUsed[_userA][_nonceA] || isNonceUsed[_userB][_nonceB];
    }

    /// @dev This internal function is used to call modify trading account
    /// @param _accountDeltas The trading account delta
    function _modifyAccounts(IPerp.AccountDelta[] memory _accountDeltas) internal {
        perpEngine.modifyAccount(_accountDeltas);
    }

    function _collectLiquidationFee(uint128 liquidationFee, Order memory taker, Delta memory takerDelta) internal {
        uint128 maxLiquidationFee = takerDelta.quoteAmount.abs().calculatePercentage(MAX_LIQUIDATION_FEE_RATE);

        if (liquidationFee > maxLiquidationFee) {
            revert Errors.Orderbook_ExceededMaxLiquidationFee();
        }

        takerDelta.quoteAmount -= liquidationFee.safeInt128();
        clearingService.collectLiquidationFee(taker.sender, taker.nonce, liquidationFee);
    }

    function _collectTradingFees(
        Fees calldata fees,
        Delta memory makerDelta,
        Delta memory takerDelta,
        FeesInBSX memory feesInBSX
    ) internal {
        int128 makerTradingFee = fees.maker - fees.makerReferralRebate.safeInt128();
        if (fees.isMakerFeeInBSX) {
            feesInBSX.maker += fees.maker;
            _tradingFees.inBSX += makerTradingFee;
        } else {
            makerDelta.quoteAmount -= fees.maker;
            _tradingFees.inUSDC += makerTradingFee;
        }

        int128 takerTradingFee = fees.taker - fees.takerReferralRebate.safeInt128();
        if (fees.isTakerFeeInBSX) {
            feesInBSX.taker += fees.taker;
            _tradingFees.inBSX += takerTradingFee;
        } else {
            takerDelta.quoteAmount -= fees.taker;
            _tradingFees.inUSDC += takerTradingFee;
        }
    }

    function _collectSequencerFee(
        int128 sequencerFee,
        bool isTakerFeeInBSX,
        Delta memory takerDelta,
        FeesInBSX memory feesInBSX
    ) internal {
        if (isTakerFeeInBSX) {
            _sequencerFees.inBSX += sequencerFee;
            feesInBSX.taker += sequencerFee;
        } else {
            _sequencerFees.inUSDC += sequencerFee;
            takerDelta.quoteAmount -= sequencerFee;
        }
    }

    function _collectFeesInBSX(FeesInBSX memory feesInBSX, address maker, address taker) internal {
        if (feesInBSX.maker > 0) {
            spotEngine.updateBalance(maker, BSX_TOKEN, -feesInBSX.maker);
        }

        if (feesInBSX.taker > 0) {
            spotEngine.updateBalance(taker, BSX_TOKEN, -feesInBSX.taker);
        }
    }

    function _settleBalance(uint8 _productIndex, address _account, int128 _matchSize, int128 _quote, uint128 _price)
        internal
        returns (int128, int128)
    {
        IPerp.Balance memory balance = perpEngine.getOpenPosition(_account, _productIndex);
        IPerp.FundingRate memory fundingRate = perpEngine.getFundingRate(_productIndex);

        //pay funding first
        int128 funding = (fundingRate.cumulativeFunding18D - balance.lastFunding).mul18D(balance.size);
        int128 newQuote = _quote + balance.quoteBalance - funding;
        int128 newSize = balance.size + _matchSize;
        int128 amountToSettle;
        if (balance.size.mul18D(newSize) < 0) {
            amountToSettle = newQuote + newSize.mul18D(_price.safeInt128());
        } else if (newSize == 0) {
            amountToSettle = newQuote;
        }

        spotEngine.updateBalance(_account, _collateralToken, amountToSettle);
        newQuote = newQuote - amountToSettle;
        return (newQuote, newSize);
    }

    function _updatePerpAccounts(
        uint8 _productIndex,
        Order memory maker,
        Order memory taker,
        Delta memory makerDelta,
        Delta memory takerDelta
    ) internal {
        IPerp.AccountDelta[] memory accountDeltas = new IPerp.AccountDelta[](2);
        accountDeltas[0] =
            _createAccountDelta(_productIndex, maker.sender, makerDelta.productAmount, makerDelta.quoteAmount);
        accountDeltas[1] =
            _createAccountDelta(_productIndex, taker.sender, takerDelta.productAmount, takerDelta.quoteAmount);
        _modifyAccounts(accountDeltas);
    }

    function _validatePrice(OrderSide makerSide, uint128 makerPrice, uint128 takerPrice) internal pure {
        if (makerSide == OrderSide.BUY && makerPrice < takerPrice) {
            revert Errors.Orderbook_InvalidOrderPrice();
        }
        if (makerSide == OrderSide.SELL && makerPrice > takerPrice) {
            revert Errors.Orderbook_InvalidOrderPrice();
        }
    }

    function _validateTradingFee(int128 fee, uint128 quoteAmount, bool isFeeInBSX, uint128 bsxPriceUSD) internal pure {
        uint128 maxTradingFeeInUSD = quoteAmount.calculatePercentage(MAX_TRADING_FEE_RATE);
        if (isFeeInBSX) {
            uint128 maxTradingFeeInBSX =
                Math.mulDiv(maxTradingFeeInUSD, 1e18, bsxPriceUSD).toUint128() * BSX_FEE_MULTIPLIER;
            if (fee > maxTradingFeeInBSX.safeInt128()) {
                revert Errors.Orderbook_ExceededMaxTradingFee();
            }
        } else {
            if (fee > maxTradingFeeInUSD.safeInt128()) {
                revert Errors.Orderbook_ExceededMaxTradingFee();
            }
        }
    }

    function _validateSequencerFee(uint128 fee, bool isFeeInBSX, uint128 bsxPriceUSD) internal pure {
        if (isFeeInBSX) {
            uint128 maxSequencerFeeInBSX =
                Math.mulDiv(MAX_TAKER_SEQUENCER_FEE_IN_USD, 1e18, bsxPriceUSD).toUint128() * BSX_FEE_MULTIPLIER;
            if (fee > maxSequencerFeeInBSX) {
                revert Errors.Orderbook_ExceededMaxSequencerFee();
            }
        } else {
            if (fee > MAX_TAKER_SEQUENCER_FEE_IN_USD) {
                revert Errors.Orderbook_ExceededMaxSequencerFee();
            }
        }
    }

    function _verifyUsedNonce(address user, uint64 nonce) internal view {
        if (isNonceUsed[user][nonce]) {
            revert Errors.Orderbook_NonceUsed(user, nonce);
        }
    }

    /// @dev This helper function is used to create an account delta.
    /// @param productIndex Product id
    /// @param account Account address
    /// @param amount Amount of product token
    /// @param quoteAmount Amount of quote
    /// @return Account delta
    function _createAccountDelta(uint8 productIndex, address account, int128 amount, int128 quoteAmount)
        internal
        pure
        returns (IPerp.AccountDelta memory)
    {
        return
            IPerp.AccountDelta({productIndex: productIndex, account: account, amount: amount, quoteAmount: quoteAmount});
    }
}

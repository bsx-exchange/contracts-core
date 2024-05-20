// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Gateway} from "./abstracts/Gateway.sol";
import {IAccess} from "./interfaces/IAccess.sol";
import {IPerpEngine} from "./interfaces/IPerpEngine.sol";
import {Errors} from "./libraries/Errors.sol";
import {Math} from "./libraries/Math.sol";

/// @title Perp contract
/// @notice Manage openning positions
/// @dev This contract is upgradeable
contract PerpEngine is Gateway, IPerpEngine, Initializable {
    using Math for int128;

    IAccess public access;

    mapping(address account => mapping(uint8 productId => OpenPosition position)) private _openPositions;
    mapping(uint8 productId => MarketMetrics metrics) private _marketMetrics;

    function initialize(address _access) public initializer {
        if (_access == address(0)) {
            revert Errors.ZeroAddress();
        }
        access = IAccess(_access);
    }

    /// @inheritdoc IPerpEngine
    function settlePositionPnl(
        uint8 productId,
        address account,
        int128 deltaBaseAmount,
        int128 deltaQuoteAmount
    ) external override authorized returns (int128) {
        OpenPosition memory openPosition = _openPositions[account][productId];

        int128 cumulativeFunding = _marketMetrics[productId].cumulativeFundingRate;
        int128 fundingFee = (cumulativeFunding - openPosition.lastFunding).mul18D(openPosition.baseAmount);
        int128 newBaseAmount = openPosition.baseAmount + deltaBaseAmount;
        int128 newQuoteAmount = openPosition.quoteAmount + deltaQuoteAmount - fundingFee;

        int128 pnl;
        if (newBaseAmount == 0) {
            pnl = newQuoteAmount;
            newQuoteAmount = 0;
        } else if (openPosition.baseAmount.mul18D(newBaseAmount) < 0) {
            pnl = newQuoteAmount - newBaseAmount.mulDiv(deltaQuoteAmount, deltaBaseAmount);
            newQuoteAmount -= pnl;
        }

        _updateOpenInterest(productId, openPosition.baseAmount, newBaseAmount);
        _updatePosition(productId, account, newBaseAmount, newQuoteAmount, cumulativeFunding);

        return pnl;
    }

    /// @inheritdoc IPerpEngine
    function cumulateFundingRate(uint8 productId, int128 premiumRate) external override authorized returns (int128) {
        int128 updatedCumulativeFunding = _marketMetrics[productId].cumulativeFundingRate + premiumRate;
        _marketMetrics[productId].cumulativeFundingRate = updatedCumulativeFunding;
        return updatedCumulativeFunding;
    }

    /// @inheritdoc IPerpEngine
    function getMarketMetrics(uint8 productId) external view override returns (MarketMetrics memory) {
        return _marketMetrics[productId];
    }

    /// @inheritdoc IPerpEngine
    function getOpenPosition(uint8 productId, address account) external view override returns (OpenPosition memory) {
        return _openPositions[account][productId];
    }

    /// @inheritdoc Gateway
    function _isAuthorized(address caller) internal view override returns (bool) {
        return caller == access.getExchange() || caller == access.getClearinghouse() || caller == access.getOrderbook();
    }

    function _updateOpenInterest(uint8 productId, int128 oldBaseAmount, int128 newBaseAmount) private {
        int128 deltaOpenInterest;
        if (oldBaseAmount > 0) {
            deltaOpenInterest -= oldBaseAmount;
        }
        if (newBaseAmount > 0) {
            deltaOpenInterest += newBaseAmount;
        }

        _marketMetrics[productId].openInterest += deltaOpenInterest;
    }

    function _updatePosition(
        uint8 productId,
        address account,
        int128 baseAmount,
        int128 quoteAmount,
        int128 lastCumulativeFunding
    ) private {
        _openPositions[account][productId] = OpenPosition(baseAmount, quoteAmount, lastCumulativeFunding);
    }
}

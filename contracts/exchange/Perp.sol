// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Access} from "./access/Access.sol";
import {IPerp} from "./interfaces/IPerp.sol";
import {Errors} from "./lib/Errors.sol";

/// @title Perp contract
/// @notice Manage openning positions
/// @dev This contract is upgradeable
contract Perp is IPerp, Initializable {
    Access public access;

    mapping(address account => mapping(uint8 productId => Balance balance)) public balance;
    mapping(uint8 productId => FundingRate marketMetrics) public fundingRate;
    mapping(address account => uint256 openPos) public openPositions;

    // function initialize(address _access) public initializer {
    //     if (_access == address(0)) {
    //         revert Errors.ZeroAddress();
    //     }
    //     access = Access(_access);
    // }

    modifier onlySequencer() {
        if (
            msg.sender != address(access.getExchange()) && msg.sender != address(access.getClearingService())
                && msg.sender != address(access.getOrderBook())
        ) {
            revert Errors.Unauthorized();
        }
        _;
    }

    /// @inheritdoc IPerp
    function modifyAccount(IPerp.AccountDelta[] calldata _accountDeltas) external onlySequencer {
        uint64 length = uint64(_accountDeltas.length);
        for (uint64 index = 0; index < length; ++index) {
            IPerp.AccountDelta memory accountDelta = _accountDeltas[index];
            uint8 _productIndex = accountDelta.productIndex;
            int128 quote = accountDelta.quoteAmount;
            int128 amount = accountDelta.amount;
            FundingRate memory _fundingRate = fundingRate[_productIndex];
            Balance memory _balance = balance[accountDelta.account][_productIndex];

            int256 prevSize = _balance.size;
            _updateAccountBalance(_fundingRate, _balance, amount, quote);
            balance[accountDelta.account][_productIndex] = _balance;
            fundingRate[_productIndex] = _fundingRate;
            int256 newSize = _balance.size;

            if (prevSize == 0 && newSize != 0) {
                openPositions[accountDelta.account] += 1;
            } else if (prevSize != 0 && newSize == 0) {
                openPositions[accountDelta.account] -= 1;
            }
        }
    }

    /// @inheritdoc IPerp
    function updateFundingRate(uint8 _productIndex, int128 priceDiff) external onlySequencer returns (int128) {
        FundingRate memory _fundingRate = fundingRate[_productIndex];
        _fundingRate.cumulativeFunding18D = _fundingRate.cumulativeFunding18D + priceDiff;
        fundingRate[_productIndex] = _fundingRate;
        return _fundingRate.cumulativeFunding18D;
    }

    /// @inheritdoc IPerp
    function getOpenPosition(address account, uint8 productIndex) public view returns (Balance memory position) {
        position = balance[account][productIndex];
    }

    /// @inheritdoc IPerp
    function getFundingRate(uint8 _productIndex) external view returns (FundingRate memory) {
        return fundingRate[_productIndex];
    }

    /**
     * @dev This function update the position of an account of a market. Include update the funding rate.
     * @param _fundingRate The funding rate of the market
     * @param _balance The balance of the account
     * @param _amount The amount of the position
     * @param _quote The quote of the positions
     */
    function _updateAccountBalance(
        FundingRate memory _fundingRate,
        Balance memory _balance,
        int128 _amount,
        int128 _quote
    ) internal pure {
        _fundingRate.openInterest -= (_balance.size > 0) ? _balance.size : int128(0);
        _balance.size = _amount;
        _balance.quoteBalance = _quote;

        _balance.lastFunding = _fundingRate.cumulativeFunding18D;
        _fundingRate.openInterest += (_balance.size > 0) ? _balance.size : int128(0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Access} from "./access/Access.sol";
import {IPerp} from "./interfaces/IPerp.sol";
import {Errors} from "./lib/Errors.sol";

/// @title Perp contract
/// @notice Manage openning positions
/// @dev This contract is upgradeable
contract Perp is IPerp, Initializable, OwnableUpgradeable {
    Access public access;

    mapping(address account => mapping(uint8 productId => Balance balance)) public balance;
    mapping(uint8 productId => FundingRate marketMetrics) public fundingRate;

    function initialize(address _access) public initializer {
        if (_access == address(0)) {
            revert Errors.ZeroAddress();
        }
        access = Access(_access);
    }

    function _onlySequencer() internal view {
        if (
            msg.sender != access.getExchange() && msg.sender != access.getClearingService()
                && msg.sender != access.getOrderBook()
        ) {
            revert Errors.Unauthorized();
        }
    }

    modifier onlySequencer() {
        _onlySequencer();
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

            _updateAccountBalance(_fundingRate, _balance, amount, quote);
            balance[accountDelta.account][_productIndex] = _balance;
            fundingRate[_productIndex] = _fundingRate;
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
    function getBalance(address account, uint8 productIndex) public view returns (Balance memory) {
        Balance memory _balance = balance[account][productIndex];
        return _balance;
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

    /*//////////////////////////////////////////////////////////////////////////
                                DEVELOPMENT ONLY
    //////////////////////////////////////////////////////////////////////////*/
    struct Market {
        uint8 productIndex;
        Balance balance;
    }

    struct UserAllMarketBalanceInfo {
        address account;
        Market[] markets;
    }

    function resetBalance(uint8[] memory productId, address account) external onlySequencer {
        uint64 length = uint64(productId.length);
        for (uint64 index = 0; index < length; ++index) {
            uint8 productIndex = productId[index];
            Balance memory _balance = balance[account][productIndex];
            _balance.size = 0;
            _balance.quoteBalance = 0;
            _balance.lastFunding = 0;
            balance[account][productIndex] = _balance;
        }
    }

    function resetFundingRate(uint8[] memory productId) external onlySequencer {
        uint64 length = uint64(productId.length);
        for (uint64 index = 0; index < length; ++index) {
            uint8 productIndex = productId[index];
            FundingRate memory _fundingRate = fundingRate[productIndex];
            _fundingRate.cumulativeFunding18D = 0;
            _fundingRate.openInterest = 0;
            fundingRate[productIndex] = _fundingRate;
        }
    }

    function getAllUserMarketBalances(
        address[] calldata _accounts,
        uint8[] calldata _productIndexs
    ) external view returns (UserAllMarketBalanceInfo[] memory) {
        uint256 length = _accounts.length;
        UserAllMarketBalanceInfo[] memory balances = new UserAllMarketBalanceInfo[](length);
        for (uint256 index = 0; index < length; ++index) {
            address account = _accounts[index];
            Market[] memory balanceInfos = new Market[](_productIndexs.length);
            for (uint256 balanceIndex = 0; balanceIndex < _productIndexs.length; balanceIndex++) {
                uint8 productIndex = _productIndexs[balanceIndex];
                balanceInfos[balanceIndex] = Market(productIndex, balance[account][productIndex]);
            }
            balances[index] = UserAllMarketBalanceInfo(account, balanceInfos);
        }
        return balances;
    }
}

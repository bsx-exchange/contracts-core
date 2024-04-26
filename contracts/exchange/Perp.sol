// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/IPerp.sol";
import "./interfaces/IClearingService.sol";
//solhint-disable-next-line
import "hardhat/console.sol";
import "./access/Access.sol";
import "./lib/MathHelper.sol";
import "./Spot.sol";
import "./share/RevertReason.sol";

/**
 * @title Perp contract
 * @author BSX
 * @notice This contract is only used for managing the position of an account.
 * @dev This contract is upgradeable.
 */
contract Perp is IPerp, OwnableUpgradeable {
    using MathHelper for int128;
    Access public access;

    mapping(address => mapping(uint8 => Balance)) public balance;
    mapping(uint8 => FundingRate) public fundingRate;

    function initialize(address _access) public initializer {
        __Ownable_init(msg.sender);
        if (_access == address(0)) {
            revert(INVALID_ADDRESS);
        }
        access = Access(_access);
    }

    function _onlySequencer() internal view {
        if (
            msg.sender != access.getExchange() &&
            msg.sender != access.getClearingService() &&
            msg.sender != access.getOrderBook()
        ) {
            revert(NOT_SEQUENCER);
        }
    }

    // function _onlyGeneralAdmin() internal view {
    //     if (!access.hasRole(access.ADMIN_GENERAL_ROLE(), msg.sender)) {
    //         revert(NOT_ADMIN_GENERAL);
    //     }
    // }

    modifier onlySequencer() {
        _onlySequencer();
        _;
    }

    // modifier onlyGeneralAdmin() {
    //     _onlyGeneralAdmin();
    //     _;
    // }

    /// @inheritdoc IPerp
    function modifyAccount(
        IPerp.AccountDelta[] calldata _accountDeltas
    ) external onlySequencer {
        uint64 length = uint64(_accountDeltas.length);
        for (uint64 index = 0; index < length; ++index) {
            IPerp.AccountDelta memory accountDelta = _accountDeltas[index];
            uint8 _productIndex = accountDelta.productIndex;
            int128 quote = accountDelta.quoteAmount;
            int128 amount = accountDelta.amount;
            FundingRate memory _fundingRate = fundingRate[_productIndex];
            Balance memory _balance = balance[accountDelta.account][
                _productIndex
            ];

            _updateAccountBalance(_fundingRate, _balance, amount, quote);
            balance[accountDelta.account][_productIndex] = _balance;
            fundingRate[_productIndex] = _fundingRate;
        }
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
        _fundingRate.openInterest -= (_balance.size > 0)
            ? _balance.size
            : int128(0);
        _balance.size = _amount;
        _balance.quoteBalance = _quote;

        _balance.lastFunding = _fundingRate.cumulativeFunding18D;
        _fundingRate.openInterest += (_balance.size > 0)
            ? _balance.size
            : int128(0);
    }

    /// @inheritdoc IPerp
    function getBalance(
        address _account,
        uint8 _productIndex
    ) public view returns (Balance memory) {
        Balance memory _balance = balance[_account][_productIndex];
        return _balance;
    }

    /// @inheritdoc IPerp
    function updateFundingRate(
        uint8 _productIndex,
        int128 priceDiff
    ) external onlySequencer returns (int128) {
        FundingRate memory _fundingRate = fundingRate[_productIndex];
        _fundingRate.cumulativeFunding18D =
            _fundingRate.cumulativeFunding18D +
            priceDiff;
        fundingRate[_productIndex] = _fundingRate;
        return _fundingRate.cumulativeFunding18D;
    }

    /**
     * @dev This function gets the funding rate of a market.
     * @param _productIndex Product Id
     */
    function getFundingRate(
        uint8 _productIndex
    ) external view returns (FundingRate memory) {
        return fundingRate[_productIndex];
    }

    /// @inheritdoc IPerp
    function assertOpenInterest(
        OpenInterestPair[] calldata pairs
    ) external onlySequencer {
        for (uint128 i = 0; i < pairs.length; ++i) {
            if (pairs[i].openInterest < 0) {
                revert(INVALID_OPEN_INTEREST);
            }
            FundingRate storage _fundingRate = fundingRate[
                pairs[i].productIndex
            ];
            _fundingRate.openInterest = pairs[i].openInterest;
        }
    }
}

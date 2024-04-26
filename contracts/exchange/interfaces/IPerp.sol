// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

import "./IClearingService.sol";

interface IPerp {
    error NotSequencer();
    error InvalidOpenInterest();
    error PositionNotZero();
    /**
     * @dev Struct of account delta, used to modify account balance.
     * @param productIndex Product id
     * @param _account Account address
     * @param spotEngine Spot engine address
     */
    struct AccountDelta {
        uint8 productIndex;
        address account;
        int128 amount;
        int128 quoteAmount;
    }
    /**
     * @dev This struct represents the balance of an market.
     * @param size Position size
     * @param quoteBalance Quote amount
     * @param lastFunding Last funding to pay
     */
    struct Balance {
        int128 size;
        int128 quoteBalance;
        int128 lastFunding;
    }

    /**
     * @dev This struct represents the configuration of funding rate of an market.
     * @param cummulativeFuding18D cummulative for funding rate
     * @param openInterest Open interest
     */
    struct FundingRate {
        int128 cumulativeFunding18D;
        int128 openInterest;
    }

    /**
     * @dev This struct represents the token price pair.
     * @param productIndex  Product id
     * @param price Token price
     */
    struct TokenPricePair {
        bytes32 productIndex;
        uint128 price;
    }

    /**
     * @dev This struct represents the open interest pair.
     * @param productIndex  Product id
     * @param openInterest Open interest
     */
    struct OpenInterestPair {
        uint8 productIndex;
        int128 openInterest;
    }

    struct Market {
        uint8 productIndex;
        Balance balance;
    }
    struct UserAllMarketBalanceInfo {
        address account;
        Market[] markets;
    }

    struct FundingRateInfo {
        uint8 productIndex;
        int128 cumulativeFunding18D;
        int128 openInterest;
    }

    /**
     * @dev This function gets the balance of an account. This function will update the funding rate.
     * @param _productIndex Product Id
     * @param _account Account address
     * @return Balance of the account
     */
    function getBalance(
        address _account,
        uint8 _productIndex
    ) external view returns (Balance memory);

    /**
     * @dev This function modifies the balance of an account of a market.
     * @param _accountDeltas The information of the account to modify
     * Include token address, account address, amount of product, amount of quote
     */
    function modifyAccount(IPerp.AccountDelta[] memory _accountDeltas) external;

    /**
     * @dev This function updates the funding rate of a market.
     * @param _productIndex Product id
     * @param diffPrice Difference between index price and mark price
     */
    function updateFundingRate(
        uint8 _productIndex,
        int128 diffPrice
    ) external returns (int128);

    /**
     * @dev This function asserts the open interest of a market.
     * @param pairs List of open interest pairs. Includes token address and open interest.
     */
    function assertOpenInterest(OpenInterestPair[] memory pairs) external;

    function getFundingRate(
        uint8 _productIndex
    ) external view returns (FundingRate memory);
}

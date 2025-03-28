// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

/// @title Perp Engine interface
/// @notice Manage openning positions
interface IPerp {
    /// @notice Stores the market metrics of a market, including the funding rate and open interest.
    struct FundingRate {
        int128 cumulativeFunding18D;
        int128 openInterest;
    }

    /// @notice Stores openning position of an account of a market.
    struct Balance {
        int128 size;
        int128 quoteBalance;
        int128 lastFunding;
    }

    /// @notice Information of the account to modify
    struct AccountDelta {
        uint8 productIndex;
        address account;
        int128 amount;
        int128 quoteAmount;
    }

    /// @notice Modifies the balance of an account of a market
    /// @param accountDeltas The information of the account to modify
    /// Include token address, account address, amount of product, amount of quote
    function modifyAccount(IPerp.AccountDelta[] memory accountDeltas) external;

    /// @notice Updates the funding rate of a market
    /// @param productIndex Product id
    /// @param diffPrice Difference between index price and mark price
    function updateFundingRate(uint8 productIndex, int128 diffPrice) external returns (int128);

    /// @notice Gets the open position of an account of a market
    /// @param productIndex Product Id
    /// @param account Account address
    /// @return Balance of the account
    function getOpenPosition(address account, uint8 productIndex) external view returns (Balance memory);

    /// @notice Gets the funding rate of a market.
    /// @param productIndex Product Id
    /// @return Funding rate of the market
    function getFundingRate(uint8 productIndex) external view returns (FundingRate memory);

    /// @notice Gets the number of open positions of an account
    /// @param account Account address
    /// @return Number of open positions
    function openPositions(address account) external view returns (uint256);
}

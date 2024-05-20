// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

interface IPerpEngine {
    /// @notice Store state of open position
    /// @dev Don't change the order of the variables
    struct OpenPosition {
        int128 baseAmount;
        int128 quoteAmount;
        int128 lastFunding;
    }

    /// @notice Store state of cumulative funding rate, and open interest
    /// @dev Don't change the order of the variables
    struct MarketMetrics {
        int128 cumulativeFundingRate;
        int128 openInterest;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Update positions of accounts of a market
    /// @param productId Product id of the market
    /// @param account Account address
    /// @param deltaBaseAmount Change of base amount
    /// @param deltaQuoteAmount Change of quote amount
    /// @return PnL of the position
    function settlePositionPnl(
        uint8 productId,
        address account,
        int128 deltaBaseAmount,
        int128 deltaQuoteAmount
    ) external returns (int128);

    /// @notice Cumulate funding rate of a market
    /// @param productId Product id of the market
    /// @param premiumRate Premium of new funding rate
    /// @return Updated cumulative funding rate
    function cumulateFundingRate(uint8 productId, int128 premiumRate) external returns (int128);

    /*//////////////////////////////////////////////////////////////////////////
                                CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Get the funding rate and open interest of a market
    function getMarketMetrics(uint8 productId) external view returns (MarketMetrics memory);

    /// @notice Get open position of an account of a market
    function getOpenPosition(uint8 productId, address account) external view returns (OpenPosition memory);
}

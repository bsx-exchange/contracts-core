// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title Handles percentage calculations
 * @notice With 10_000 representing 100%
 */
library Percentage {
    uint16 internal constant ONE_HUNDRED_PERCENT = 10_000;

    /**
     * @notice Calculates the percentage of an amount
     * @param amount The amount to calculate the percentage of
     * @param percentage The percentage to calculate
     * @return The calculated percentage
     */
    function calculatePercentage(uint128 amount, uint16 percentage) internal pure returns (uint128) {
        return (amount * percentage) / ONE_HUNDRED_PERCENT;
    }
}

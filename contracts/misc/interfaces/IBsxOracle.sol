// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IBsxOracle {
    /// @notice Get the price of token in USD with 18 decimals
    /// @param token The address of the token
    /// @return The price of the token in USD
    function getTokenPriceInUsd(address token) external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

interface IBsxOracle {
    /// @notice Get the price of BSX in USD with 18 decimals
    function getBsxPriceUsd() external view returns (uint256 bsxPriceUsd);

    /// @notice Get the price of ETH in USD with 18 decimals
    function getEthPriceUsd() external view returns (uint256 ethPriceUsd);
}

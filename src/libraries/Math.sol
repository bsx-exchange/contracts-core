// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title Math library
/// @author BSX
/// @notice This library contains helper functions for math.
/// @dev This library is still under development to adapt to the needs of the project.
/// We will continue to add/remove helper functions to this library as needed.
library Math {
    error UnderflowOrOverflow();

    function mul18D(int128 x, int128 y) internal pure returns (int128) {
        int256 res = (int256(x) * y) / 1e18;
        if (res > type(int128).max || res < type(int128).min) {
            revert UnderflowOrOverflow();
        }
        return int128(res);
    }

    function mul18D(uint128 x, uint128 y) internal pure returns (uint128) {
        uint256 res = (uint256(x) * y) / 1e18;
        if (res > type(uint128).max) {
            revert UnderflowOrOverflow();
        }
        return uint128(res);
    }

    function mulDiv(int128 x, int128 y, int128 z) internal pure returns (int128) {
        int256 res = (int256(x) * y) / z;
        if (res > type(int128).max || res < type(int128).min) {
            revert UnderflowOrOverflow();
        }
        return int128(res);
    }

    /// @dev Returns the smallest of two numbers.
    function min(uint128 a, uint128 b) internal pure returns (uint128) {
        return a < b ? a : b;
    }

    function convertTo18D(uint256 x, uint8 decimals) internal pure returns (uint256) {
        return x * 10 ** 18 / 10 ** decimals;
    }

    function convertFrom18D(uint256 x, uint8 decimals) internal pure returns (uint256) {
        return x * 10 ** decimals / 10 ** 18;
    }
}

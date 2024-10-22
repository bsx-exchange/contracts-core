// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20Extend} from "../interfaces/external/IERC20Extend.sol";

/**
 * @title MathHelper library
 * @author BSX
 * @notice This library contains helper functions for math.
 * @dev This library is still under development to adapt to the needs of the project.
 * We will continue to add/remove helper functions to this library as needed.
 */
library MathHelper {
    uint128 internal constant FACTOR_SCALE = 1e18;

    error InvalidUInt256();
    error InvalidUInt128();
    error InvalidInt256();
    error InvalidInt128();

    function min(uint128 a, uint128 b) internal pure returns (uint128) {
        return a > b ? b : a;
    }

    function max(uint128 a, uint128 b) internal pure returns (uint128) {
        return a > b ? a : b;
    }

    function mul18D(int128 x, int128 y) internal pure returns (int128) {
        int256 result = (int256(x) * y) / int128(FACTOR_SCALE);
        return safeInt128(result);
    }

    function mul18D(uint128 x, uint128 y) internal pure returns (uint128) {
        uint256 result = (uint256(x) * y) / FACTOR_SCALE;
        return safeUInt128(result);
    }

    function abs(int128 n) internal pure returns (uint128) {
        unchecked {
            // must be unchecked in order to support `n = type(int128).min`
            return uint128(n >= 0 ? n : -n);
        }
    }

    function convertFromScale(uint256 scaledAmount, address token) internal view returns (uint256 originalAmount) {
        IERC20Extend product = IERC20Extend(token);
        uint8 decimals = product.decimals();
        originalAmount = _convertFromScale(scaledAmount, decimals);
    }

    function roundDownAndConvertFromScale(uint256 scaledAmount, address token)
        internal
        view
        returns (uint256 roundDown, uint256 originalAmount)
    {
        IERC20Extend product = IERC20Extend(token);
        uint8 decimals = product.decimals();
        originalAmount = _convertFromScale(scaledAmount, decimals);
        roundDown = _convertToScale(originalAmount, decimals);
    }

    function convertToScale(uint256 rawAmount, address token) internal view returns (uint256 scaledAmount) {
        IERC20Extend product = IERC20Extend(token);
        uint8 decimals = product.decimals();
        scaledAmount = _convertToScale(rawAmount, decimals);
    }

    function safeUInt256(int256 n) internal pure returns (uint256) {
        if (n < 0) revert InvalidUInt256();
        return uint256(n);
    }

    function safeUInt128(int128 n) internal pure returns (uint128) {
        if (n < 0) revert InvalidUInt128();
        return uint128(n);
    }

    function safeUInt128(uint256 n) internal pure returns (uint128) {
        if (n > type(uint128).max) revert InvalidUInt128();
        return uint128(n);
    }

    function safeInt256(uint256 n) internal pure returns (int256) {
        if (n > uint256(type(int256).max)) revert InvalidInt256();
        return int256(n);
    }

    function safeInt128(uint128 n) internal pure returns (int128) {
        if (n > uint128(type(int128).max)) revert InvalidInt128();
        return int128(n);
    }

    function safeInt128(int256 n) internal pure returns (int128) {
        if (n > type(int128).max || n < type(int128).min) {
            revert InvalidInt128();
        }
        return int128(n);
    }

    function _convertToScale(uint256 rawAmount, uint8 decimals) internal pure returns (uint256) {
        return (rawAmount * FACTOR_SCALE) / 10 ** decimals;
    }

    function _convertFromScale(uint256 scaledAmount, uint8 decimals) internal pure returns (uint256) {
        return (scaledAmount * 10 ** decimals) / FACTOR_SCALE;
    }
}

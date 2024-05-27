// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title MathHelper library
 * @author BSX
 * @notice This library contains helper functions for math.
 * @dev This library is still under development to adapt to the needs of the project.
 * We will continue to add/remove helper functions to this library as needed.
 */
library MathHelper {
    int128 internal constant ONE_18D = 10 ** 18;

    error UnderflowOrOverflow();

    function min(uint128 a, uint128 b) internal pure returns (uint128) {
        return a > b ? b : a;
    }

    function max(uint128 a, uint128 b) internal pure returns (uint128) {
        return a > b ? a : b;
    }

    function mul18D(int128 x, int128 y) internal pure returns (int128) {
        int256 result = (int256(x) * y) / ONE_18D;
        if (result > type(int128).max || result < type(int128).min) {
            revert UnderflowOrOverflow();
        }
        return int128(result);
    }

    function abs(int128 a) internal pure returns (int128) {
        return a < 0 ? -a : a;
    }
}

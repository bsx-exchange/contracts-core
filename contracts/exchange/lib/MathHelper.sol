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
    int256 private constant _INT256_MIN = -2 ** 255;
    int128 private constant ONE_18D = 1000000000000000000;
    int128 private constant MIN_18D = -0x80000000000000000000000000000000;
    int128 private constant MAX_18D = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    string private constant ERR_OVERFLOW = "E_OF";

    function min(int256 a, int256 b) internal pure returns (int256) {
        return a > b ? b : a;
    }

    function min(uint128 a, uint128 b) internal pure returns (uint128) {
        return a > b ? b : a;
    }

    function max(uint128 a, uint128 b) internal pure returns (uint128) {
        return a > b ? a : b;
    }

    function max(int128 a, int128 b) internal pure returns (int128) {
        return a > b ? a : b;
    }

    function add(int256 a, int256 b) internal pure returns (int256) {
        int r = a + b;
        require((b >= 0 && r >= a) || (b < 0 && r < a), "Math: overflow");
        return r;
    }

    function sub(int256 a, int256 b) internal pure returns (int256) {
        int r = a - b;
        require((b >= 0 && r <= a) || (b < 0 && r > a), "Math: overflow");
        return r;
    }

    function div(int256 a, int256 b) internal pure returns (int256) {
        require(b != 0, "Math: divide by zero");
        require(!(b == -1 && a == _INT256_MIN), "Math: overflow");
        int256 r = a / b;
        return r;
    }

    function div18D(int256 x, int256 y) internal pure returns (int256) {
        unchecked {
            require(y != 0, "Math: divide by zero");
            int256 result = (x * ONE_18D) / y;
            require(result >= MIN_18D && result <= MAX_18D, "Math: overflow");
            return result;
        }
    }

    function div18D(uint128 x, uint128 y) internal pure returns (uint128) {
        unchecked {
            require(y != 0, "Math: divide by zero");
            uint128 result = (x * uint128(ONE_18D)) / y;
            require(
                result >= 0 && result <= uint128(MAX_18D),
                "Math: overflow"
            );
            return result;
        }
    }

    function mul(int256 a, int256 b) internal pure returns (int256) {
        if (a == 0 || b == 0) {
            return 0;
        }
        require(!(a == -1 && b == _INT256_MIN), "Math: overflow");
        int256 r = a * b;
        require(r / a == b, "Math: overflow");
        return r;
    }

    function mul18D(int128 x, int128 y) internal pure returns (int128) {
        int256 result = (int256(x) * y) / ONE_18D;
        require(
            result >= MIN_18D && result <= int128(MAX_18D),
            "Math: overflow"
        );
        return int128(result);
    }

    function abs(int128 a) internal pure returns (int128) {
        require(a != _INT256_MIN, "Math: overflow");
        return a < 0 ? -a : a;
    }

    function mod(int256 a, int256 m) internal pure returns (int256) {
        return sub(a, mul(div(a, m), m));
    }
}

contract MathHelperTest {
    function add(int256 a, int256 m) public pure returns (int256) {
        return MathHelper.add(a, m);
    }

    function sub(int256 a, int256 m) public pure returns (int256) {
        return MathHelper.sub(a, m);
    }

    function div(int256 a, int256 m) public pure returns (int256) {
        return MathHelper.div(a, m);
    }

    function mul(int256 a, int256 m) public pure returns (int256) {
        return MathHelper.mul(a, m);
    }

    function abs(int128 a) public pure returns (int128) {
        return MathHelper.abs(a);
    }

    function min(uint128 a, uint128 b) public pure returns (uint128) {
        return MathHelper.min(a, b);
    }

    function max(int128 a, int128 b) public pure returns (int128) {
        return MathHelper.max(a, b);
    }
}

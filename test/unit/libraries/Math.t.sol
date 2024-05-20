// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {Math} from "src/libraries/Math.sol";

contract MathTest is Test {
    using Math for int128;
    using Math for uint128;

    function test_mul18D_int128() public pure {
        int128 x = 10 * 1e18;
        int128 y = 20 * 1e18;
        assertEq(x.mul18D(y), 200 * 1e18);
    }

    function test_mul18D_int128_min() public pure {
        int128 x = type(int128).min;
        int128 y = 1e18;
        assertEq(x.mul18D(y), type(int128).min);
    }

    function test_mul18D_int128_revertsIfOverflow() public {
        int128 x = type(int128).max;
        int128 y = 1e18 + 1;
        vm.expectRevert(Math.UnderflowOrOverflow.selector);
        x.mul18D(y);
    }

    function test_mul18D_int128_revertsIfUnderflow() public {
        int128 x = type(int128).min;
        int128 y = 1e18 + 1;
        vm.expectRevert(Math.UnderflowOrOverflow.selector);
        x.mul18D(y);
    }

    function test_mul18D_uint128() public pure {
        uint128 x = 10 * 1e18;
        uint128 y = 20 * 1e18;
        assertEq(x.mul18D(y), 200 * 1e18);
    }

    function test_mul18D_uint128_max() public pure {
        uint128 x = type(uint128).max;
        uint128 y = 1e18;
        assertEq(x.mul18D(y), type(uint128).max);
    }

    function test_mul18D_uint128_min() public pure {
        uint128 x = 0;
        uint128 y = 1e18;
        assertEq(x.mul18D(y), 0);
    }

    function test_mul18D_uint128_revertsIfOverflow() public {
        uint128 x = type(uint128).max;
        uint128 y = 1e18 + 1;
        vm.expectRevert(Math.UnderflowOrOverflow.selector);
        x.mul18D(y);
    }

    function test_mulDiv() public pure {
        int128 x = 10;
        int128 y = 20;
        int128 z = 2;
        assertEq(x.mulDiv(y, z), 100);
    }

    function test_mulDiv_max() public pure {
        int128 x = type(int128).max;
        int128 y = type(int128).max;
        int128 z = type(int128).max;
        assertEq(x.mulDiv(y, z), type(int128).max);
    }

    function test_mulDiv_min() public pure {
        int128 x = type(int128).min;
        int128 y = type(int128).min;
        int128 z = type(int128).min;
        assertEq(x.mulDiv(y, z), type(int128).min);
    }

    function test_mulDiv_revertsIfOverflow() public {
        int128 x = type(int128).max;
        int128 y = 2;
        int128 z = 1;
        vm.expectRevert(Math.UnderflowOrOverflow.selector);
        x.mulDiv(y, z);
    }

    function test_mulDiv_revertsIfUnderflow() public {
        int128 x = type(int128).min;
        int128 y = 2;
        int128 z = 1;
        vm.expectRevert(Math.UnderflowOrOverflow.selector);
        x.mulDiv(y, z);
    }

    function test_min() public pure {
        uint128 x = 10;
        uint128 y = 20;
        assertEq(x.min(y), 10);

        x = 20;
        y = 10;
        assertEq(x.min(y), 10);
    }

    function test_convertFrom18D() public pure {
        uint128 x = 5 * 1e18;
        uint8 decimals = 6;
        assertEq(x.convertFrom18D(decimals), 5 * 10 ** decimals);
    }

    function test_convertTo18D() public pure {
        uint8 decimals = 6;
        uint128 x = uint128(5 * 10 ** decimals);
        assertEq(x.convertTo18D(decimals), 5 * 1e18);
    }
}

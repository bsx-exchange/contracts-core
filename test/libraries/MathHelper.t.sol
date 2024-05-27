// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {MathHelper} from "src/lib/MathHelper.sol";

contract MathHelperTest is Test {
    using MathHelper for int128;
    using MathHelper for uint128;

    function test_mul18D() public pure {
        int128 x = 10 * 1e18;
        int128 y = 20 * 1e18;
        assertEq(x.mul18D(y), 200 * 1e18);
    }

    function test_mul18D_min() public pure {
        int128 x = type(int128).min;
        int128 y = 1e18;
        assertEq(x.mul18D(y), type(int128).min);

        x = 1e18;
        y = type(int128).min;
        assertEq(x.mul18D(y), type(int128).min);
    }

    function test_mul18D_max() public pure {
        int128 x = type(int128).max;
        int128 y = 1e18;
        assertEq(x.mul18D(y), type(int128).max);

        x = 1e18;
        y = type(int128).max;
        assertEq(x.mul18D(y), type(int128).max);
    }

    function test_mul18D_revertsIfOverflow() public {
        int128 x = type(int128).max;
        int128 y = 1e18 + 1;
        vm.expectRevert(MathHelper.UnderflowOrOverflow.selector);
        x.mul18D(y);

        x = 1e18 + 1;
        y = type(int128).max;
        vm.expectRevert(MathHelper.UnderflowOrOverflow.selector);
    }

    function test_mul18D_revertsIfUnderflow() public {
        int128 x = type(int128).min;
        int128 y = 1e18 + 1;
        vm.expectRevert(MathHelper.UnderflowOrOverflow.selector);
        x.mul18D(y);

        x = 1e18 + 1;
        y = type(int128).min;
        vm.expectRevert(MathHelper.UnderflowOrOverflow.selector);
    }

    function test_min() public pure {
        uint128 x = 10;
        uint128 y = 20;
        assertEq(x.min(y), 10);

        x = 20;
        y = 10;
        assertEq(x.min(y), 10);

        x = 10;
        y = 10;
        assertEq(x.min(y), 10);
    }

    function test_max() public pure {
        uint128 x = 10;
        uint128 y = 20;
        assertEq(x.max(y), 20);

        x = 20;
        y = 10;
        assertEq(x.max(y), 20);

        x = 20;
        y = 20;
        assertEq(x.max(y), 20);
    }

    function test_abs() public pure {
        int128 x = 10;
        assertEq(x.abs(), 10);

        x = -10;
        assertEq(x.abs(), 10);

        x = 0;
        assertEq(x.abs(), 0);
    }
}

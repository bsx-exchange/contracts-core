// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {ERC20Simple} from "../../mock/ERC20Simple.sol";
import {MathHelper} from "contracts/exchange/lib/MathHelper.sol";

contract MathHelperCall {
    /// @dev add this to exclude from the coverage report
    function test() public pure returns (bool) {
        return true;
    }

    function safeInt128(uint128 a) public pure returns (int128) {
        return MathHelper.safeInt128(a);
    }

    function safeInt128(int256 a) public pure returns (int128) {
        return MathHelper.safeInt128(a);
    }
}

contract MathHelperTest is Test {
    using MathHelper for int128;
    using MathHelper for uint128;

    MathHelperCall private mathHelperCall = new MathHelperCall();
    ERC20Simple private token = new ERC20Simple(6);

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
        vm.expectRevert(MathHelper.InvalidInt128.selector);
        x.mul18D(y);
    }

    function test_mul18D_revertsIfUnderflow() public {
        int128 x = type(int128).min;
        int128 y = 1e18 + 1;
        vm.expectRevert(MathHelper.InvalidInt128.selector);
        x.mul18D(y);
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

    function test_convertToScale() public view {
        uint256 rawAmount = 100 * 10 ** token.decimals();
        uint256 scaledAmount = 100 * 10 ** 18;
        assertEq(MathHelper.convertToScale(rawAmount, address(token)), scaledAmount);
    }

    function test_convertFromScale() public view {
        uint256 scaledAmount = 100 * 10 ** 18;
        uint256 rawAmount = 100 * 10 ** token.decimals();
        assertEq(MathHelper.convertFromScale(scaledAmount, address(token)), rawAmount);
    }

    function test_roundDownAndConvertFromScale() public view {
        assertEq(token.decimals(), 6);

        uint256 smallFragment = 9 * 1e11;
        uint256 scaledAmount = (100 * 1e18) + smallFragment;

        (uint256 roundDownAmount, uint256 rawAmount) =
            MathHelper.roundDownAndConvertFromScale(scaledAmount, address(token));

        assertEq(rawAmount, 100 * 1e6);
        assertEq(roundDownAmount, 100 * 1e18);
    }

    function test_safeUInt256() public pure {
        int256 n = 100;
        assertEq(MathHelper.safeUInt256(n), 100);
    }

    function test_safeUInt256_revertsIfUnderflow() public {
        int256 n = -1;
        vm.expectRevert(MathHelper.InvalidUInt256.selector);
        MathHelper.safeUInt256(n);
    }

    function test_safeUInt128() public pure {
        uint256 n = 100;
        assertEq(MathHelper.safeUInt128(n), 100);
    }

    function test_safeUInt128_revertsIfOverflow() public {
        uint256 n = uint256(type(uint128).max) + 1;
        vm.expectRevert(MathHelper.InvalidUInt128.selector);
        MathHelper.safeUInt128(n);
    }

    function test_safeInt256() public pure {
        uint256 n = 100;
        assertEq(MathHelper.safeInt256(n), 100);
    }

    function test_safeInt256_revertsIfOverflow() public {
        uint256 n = uint256(type(int256).max) + 1;
        vm.expectRevert(MathHelper.InvalidInt256.selector);
        MathHelper.safeInt256(n);
    }

    function test_safeInt128() public pure {
        int256 n = 100;
        assertEq(MathHelper.safeInt128(n), 100);

        n = -100;
        assertEq(MathHelper.safeInt128(n), -100);
    }

    function test_safeInt128_revertsIfOverflow() public {
        int256 a = int256(type(int128).max) + 1;
        vm.expectRevert(MathHelper.InvalidInt128.selector);
        mathHelperCall.safeInt128(a);

        uint128 b = uint128(type(int128).max) + 1;
        vm.expectRevert(MathHelper.InvalidInt128.selector);
        mathHelperCall.safeInt128(b);
    }

    function test_safeInt128_revertsIfUnderflow() public {
        int256 a = int256(type(int128).min) - 1;
        vm.expectRevert(MathHelper.InvalidInt128.selector);
        MathHelper.safeInt128(a);
    }
}

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

    function mul18D(int128 x, int128 y) public pure returns (int128) {
        return MathHelper.mul18D(x, y);
    }

    function safeUInt256(int256 a) public pure returns (uint256) {
        return MathHelper.safeUInt256(a);
    }

    function safeInt256(uint256 a) public pure returns (int256) {
        return MathHelper.safeInt256(a);
    }

    function safeInt128(uint128 a) public pure returns (int128) {
        return MathHelper.safeInt128(a);
    }

    function safeInt128(int256 a) public pure returns (int128) {
        return MathHelper.safeInt128(a);
    }

    function safeUInt128(uint256 a) public pure returns (uint128) {
        return MathHelper.safeUInt128(a);
    }

    function safeUInt128(int128 a) public pure returns (uint128) {
        return MathHelper.safeUInt128(a);
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
        mathHelperCall.mul18D(x, y);
    }

    function test_mul18D_revertsIfUnderflow() public {
        int128 x = type(int128).min;
        int128 y = 1e18 + 1;
        vm.expectRevert(MathHelper.InvalidInt128.selector);
        mathHelperCall.mul18D(x, y);
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

        x = type(int128).min;
        assertEq(x.abs(), 2 ** 127);
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

    function test_roundUpScale() public view {
        assertEq(token.decimals(), 6);

        // Amount is already a multiple of 1e6, should REMAIN
        uint256 scaledAmount = 100 ether;
        uint256 roundUpAmount = MathHelper.roundUpScale(scaledAmount, address(token));
        assertEq(roundUpAmount, 100 ether);

        // Amount is not a multiple of 1e6, should ROUND UP
        scaledAmount = 100.0000002 ether;
        roundUpAmount = MathHelper.roundUpScale(scaledAmount, address(token));
        assertGt(roundUpAmount, scaledAmount);
        assertEq(roundUpAmount, 100.000001 ether);
    }

    function test_safeUInt256() public view {
        int256 n = 100;
        assertEq(mathHelperCall.safeUInt256(n), 100);
    }

    function test_safeUInt256_revertsIfUnderflow() public {
        int256 n = -1;
        vm.expectRevert(MathHelper.InvalidUInt256.selector);
        mathHelperCall.safeUInt256(n);
    }

    function test_safeUInt128() public view {
        uint256 a = 100;
        assertEq(mathHelperCall.safeUInt128(a), 100);

        int128 b = 50;
        assertEq(mathHelperCall.safeUInt128(b), 50);
    }

    function test_safeUInt128_revertsIfOverflow() public {
        uint256 n = uint256(type(uint128).max) + 1;
        vm.expectRevert(MathHelper.InvalidUInt128.selector);
        mathHelperCall.safeUInt128(n);
    }

    function test_safeUInt128_revertsIfUnderflow() public {
        int128 n = -1;
        vm.expectRevert(MathHelper.InvalidUInt128.selector);
        mathHelperCall.safeUInt128(n);
    }

    function test_safeInt256() public view {
        uint256 n = 100;
        assertEq(mathHelperCall.safeInt256(n), 100);
    }

    function test_safeInt256_revertsIfOverflow() public {
        uint256 n = uint256(type(int256).max) + 1;
        vm.expectRevert(MathHelper.InvalidInt256.selector);
        mathHelperCall.safeInt256(n);
    }

    function test_safeInt128() public view {
        int256 n = 100;
        assertEq(mathHelperCall.safeInt128(n), 100);

        n = -100;
        assertEq(mathHelperCall.safeInt128(n), -100);
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
        mathHelperCall.safeInt128(a);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {Percentage} from "contracts/exchange/lib/Percentage.sol";

contract PercentageCall {
    /// @dev add this to exclude from the coverage report
    function test() public pure returns (bool) {
        return true;
    }

    function calculatePercentage(uint128 amount, uint16 percentage) public pure returns (uint128) {
        return Percentage.calculatePercentage(amount, percentage);
    }
}

contract PercentageTest is Test {
    using Percentage for uint128;

    PercentageCall private percentageCall = new PercentageCall();

    function test_calculatePercentage() public pure {
        uint128 amount = 50_000;

        uint16 percentage = 1; // 0.01%
        assertEq(amount.calculatePercentage(percentage), 5);

        percentage = 10; // 0.1%
        assertEq(amount.calculatePercentage(percentage), 50);

        percentage = 100; // 1%
        assertEq(amount.calculatePercentage(percentage), 500);

        percentage = 1000; // 10%
        assertEq(amount.calculatePercentage(percentage), 5000);

        percentage = 10_000; // 100%
        assertEq(amount.calculatePercentage(percentage), 50_000);
    }

    function test_calculatePercentage_revertsIfOverflow() public {
        uint128 amount = type(uint128).max;

        uint16 percentage = 10_001; // 100.01%
        vm.expectRevert();
        percentageCall.calculatePercentage(amount, percentage);
    }
}

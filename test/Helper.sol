// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

library Helper {
    /// @dev add this to exclude from the coverage report
    function test() public pure returns (bool) {
        return true;
    }

    function toArray(bytes memory data) internal pure returns (bytes[] memory) {
        bytes[] memory array = new bytes[](1);
        array[0] = data;
        return array;
    }

    function convertTo18D(uint256 x, uint8 decimals) internal pure returns (uint256) {
        return x * 10 ** 18 / 10 ** decimals;
    }

    function convertFrom18D(uint256 x, uint8 decimals) internal pure returns (uint256) {
        return x * 10 ** decimals / 10 ** 18;
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {ERC20Simple} from "./ERC20Simple.sol";

contract UniversalRouter {
    address private exchange;

    constructor(address _exchange) {
        exchange = _exchange;
    }

    /// @dev add this to exclude from the coverage report
    function test() public pure returns (bool) {
        return true;
    }

    function execute(bytes calldata, bytes[] calldata mockInputs) external {
        (address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut) =
            abi.decode(mockInputs[0], (address, uint256, address, uint256));
        ERC20Simple(tokenIn).transferFrom(exchange, address(this), amountIn);
        ERC20Simple(tokenOut).mint(address(this), amountOut);
        ERC20Simple(tokenOut).transfer(exchange, amountOut);
    }
}

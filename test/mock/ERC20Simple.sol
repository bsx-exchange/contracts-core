//SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ERC20Simple is ERC20 {
    constructor() ERC20("ERC20Simple", "SIM") {}

    /// @dev add this to exclude from the coverage report
    function test() public pure returns (bool) {
        return true;
    }

    // An external minting function allows anyone to mint as many tokens as they want
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

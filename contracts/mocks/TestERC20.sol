//SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestERC20 is ERC20 {
    constructor(string memory name, uint256 initialSupply) ERC20(name, name) {
        _mint(msg.sender, initialSupply);
    }

    // An external minting function allows anyone to mint as many tokens as they want
    function mint(uint256 amount, address to) external {
        _mint(to, amount);
    }
}

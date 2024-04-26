//SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

contract TestERC20Upgradeable is ERC20Upgradeable, OwnableUpgradeable {
    function initialize(
        string memory name,
        uint256 initialSupply
    ) public initializer {
        __ERC20_init(name, name);
        __Ownable_init(msg.sender);
        _mint(msg.sender, initialSupply);
    }

    // An external minting function allows anyone to mint as many tokens as they want
    function mint(uint256 amount, address to) external onlyOwner {
        _mint(to, amount);
    }

    function airdrop(
        address[] memory recipients,
        uint256 amounts
    ) external onlyOwner {
        for (uint256 i = 0; i < recipients.length; i++) {
            _mint(recipients[i], amounts);
        }
    }
}

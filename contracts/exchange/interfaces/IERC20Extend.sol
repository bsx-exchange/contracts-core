// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IERC20Extend interface
 * @author BSX
 * @notice This interface extends IERC20Upgradeable to add decimals function.
 */
interface IERC20Extend is IERC20 {
    function decimals() external view returns (uint8);
}

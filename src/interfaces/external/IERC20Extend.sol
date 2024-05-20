// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ERC20 Extend for BSX
/// @notice Interface for ERC20 token with decimals
interface IERC20Extend is IERC20 {
    /// @notice Returns the number of decimals used to get its user representation
    function decimals() external view returns (uint8);
}

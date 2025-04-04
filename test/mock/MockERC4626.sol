//SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract MockERC4626 is ERC4626 {
    /// @notice OpenZeppelin decimals offset used by the ERC4626 implementation.
    /// @dev Calculated to be max(0, 18 - underlyingDecimals) at construction, so the initial conversion rate maximizes
    /// precision between shares and assets.
    uint8 public immutable DECIMALS_OFFSET;

    constructor(IERC20 asset) ERC4626(asset) ERC20("MockVault", "MV") {
        DECIMALS_OFFSET = uint8(18 - ERC20(address(asset)).decimals());
    }

    function _decimalsOffset() internal view override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    /// @dev add this to exclude from the coverage report
    function test() public pure returns (bool) {
        return true;
    }
}

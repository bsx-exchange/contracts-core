// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Errors} from "../libraries/Errors.sol";

/// @notice Gateway contract for authorization
abstract contract Gateway {
    modifier authorized() {
        if (!_isAuthorized(msg.sender)) {
            revert Errors.Gateway_Unauthorized();
        }
        _;
    }

    /// @notice Check if the caller is authorized
    /// @dev caller equals to msg.sender
    /// @param caller The caller address
    /// @return bool True if the caller is authorized
    function _isAuthorized(address caller) internal view virtual returns (bool);
}

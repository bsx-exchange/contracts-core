// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Commands} from "../../lib/Commands.sol";
import {Errors} from "../../lib/Errors.sol";

library GenericLogic {
    /// @dev Checks if unversal router commands are valid
    function checkUniversalRouterCommands(bytes memory commands) internal pure {
        if (commands.length == 0) {
            revert Errors.Exchange_UniversalRouter_EmptyCommand();
        }

        for (uint256 i = 0; i < commands.length; ++i) {
            uint256 command = uint8(commands[i] & Commands.COMMAND_TYPE_MASK);

            if (
                command != Commands.V3_SWAP_EXACT_IN && command != Commands.V2_SWAP_EXACT_IN
                    && command != Commands.V3_SWAP_EXACT_OUT && command != Commands.V2_SWAP_EXACT_OUT
            ) {
                revert Errors.Exchange_UniversalRouter_InvalidCommand(command);
            }
        }
    }
}

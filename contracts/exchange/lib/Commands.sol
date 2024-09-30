// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title Commands
/// @notice Universal Router Commands
library Commands {
    bytes1 internal constant COMMAND_TYPE_MASK = 0x3f;

    uint256 internal constant V3_SWAP_EXACT_IN = 0x00;
    uint256 internal constant V3_SWAP_EXACT_OUT = 0x01;

    uint256 internal constant V2_SWAP_EXACT_IN = 0x08;
    uint256 internal constant V2_SWAP_EXACT_OUT = 0x09;
}

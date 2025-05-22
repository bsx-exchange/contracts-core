// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

library Roles {
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    bytes32 internal constant GENERAL_ROLE = keccak256("GENERAL_ROLE");

    bytes32 internal constant BATCH_OPERATOR_ROLE = keccak256("BATCH_OPERATOR_ROLE");

    bytes32 internal constant BSX1000_OPERATOR_ROLE = keccak256("BSX1000_OPERATOR_ROLE");

    bytes32 internal constant SIGNER_OPERATOR_ROLE = keccak256("SIGNER_OPERATOR_ROLE");

    bytes32 internal constant COLLATERAL_OPERATOR_ROLE = keccak256("COLLATERAL_OPERATOR_ROLE");
}

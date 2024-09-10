// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

/// @title Universal Signature Validator
/// @notice Signature Validation for Predeploy Contracts
interface IUniversalSigValidator {
    /// @notice Validate signature with side effects
    function isValidSigWithSideEffects(address _signer, bytes32 _hash, bytes calldata _signature)
        external
        returns (bool);

    /// @notice Validate signature without side effects
    function isValidSig(address _signer, bytes32 _hash, bytes calldata _signature) external returns (bool);
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

/// @title Minimal ERC3009 for BSX
/// @dev Contains  a subset of the ERC3009 interface that is used in BSX
interface IERC3009Minimal {
    /// @notice Receive a transfer with a signed authorization from the payer
    /// @dev This has an additional check to ensure that the payee's address matches
    /// the caller of this function to prevent front-running attacks. (See security
    /// considerations)
    /// @param from Payer's address (Authorizer)
    /// @param to Payee's address
    /// @param value Amount to be transferred
    /// @param validAfter The time after which this is valid (unix time in seconds)
    /// @param validBefore The time before which this is valid (unix time in seconds)
    /// @param nonce Unique nonce
    /// @param signature Signature byte array produced by an EOA wallet or a contract wallet
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
}

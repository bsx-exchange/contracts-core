// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title Access Control
/// @notice Manage roles and permissions of BSX contracts
interface IAccess {
    /*//////////////////////////////////////////////////////////////////////////
                                NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Grant role for an account
    /// @dev Only admin role can call this function
    /// @param account Account is granted role
    /// @param role Role name
    function grantRoleForAccount(address account, bytes32 role) external;

    /// @notice Revoke role of an account
    /// @dev Only admin role can call this function
    /// @param account Account is revoked role
    /// @param role Role name
    function revokeRoleForAccount(address account, bytes32 role) external;

    /// @notice Set the exchange contract
    /// @dev Only admin role can call this function
    function setExchange(address exchange) external;

    /// @notice Set the clearinghouse contract
    /// @dev Only admin role can call this function
    function setClearinghouse(address clearinghouse) external;

    /// @notice Set the orderbook contract
    /// @dev Only admin role can call this function
    function setOrderbook(address orderbook) external;

    /*//////////////////////////////////////////////////////////////////////////
                                CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Get the exchange contract
    function getExchange() external view returns (address);

    /// @notice Get the clearinghouse contract
    function getClearinghouse() external view returns (address);

    /// @notice Get the orderbook contract
    function getOrderbook() external view returns (address);
}

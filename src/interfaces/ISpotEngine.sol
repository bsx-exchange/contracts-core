// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

/// @title Spot Engine
/// @notice Manage token balances state
interface ISpotEngine {
    /// @notice Store account's token balance state
    /// @dev Don't change the order of the variables
    struct Balance {
        // Standardized amount of token (18 decimals)
        int256 amount;
    }

    /// @notice Emit when an account's token balance state is updated
    /// @param account Account address
    /// @param token Token address
    /// @param amount Token amount (18 decimals)
    /// @param newBalance Balance after updating (18 decimals)
    event UpdateAccount(address indexed account, address indexed token, int256 amount, int256 newBalance);

    /*//////////////////////////////////////////////////////////////////////////
                                NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Update the balance state of an account
    /// @dev Only the exchange, clearing service, and order book can call this function
    /// @param account Account address
    /// @param token Token address
    /// @param amount Token amount
    function updateAccount(address account, address token, int256 amount) external;

    /// @notice Increase the total balance state of a token
    /// @dev Only the exchange, clearing service, and order book can call this function
    /// @param token Token address
    /// @param amount Token amount
    function increaseTotalBalance(address token, uint256 amount) external;

    /// @notice Decrease the total balance of a token
    /// @dev Only the exchange, clearing service, and order book can call this function
    /// @param token Token address
    /// @param amount Token amount
    function decreaseTotalBalance(address token, uint256 amount) external;

    /*//////////////////////////////////////////////////////////////////////////
                                CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Get the token balance of an address
    /// @param account Account address
    /// @param token Token address
    /// @return Balance of the account
    function getBalance(address account, address token) external view returns (int256);

    /// @notice Get the total balance of a token
    /// @param token Token address
    /// @return Total balance of the token
    function getTotalBalance(address token) external view returns (uint256);
}

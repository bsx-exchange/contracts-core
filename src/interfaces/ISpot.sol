// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

/// @title Spot Engine interface
/// @notice Manage token balances state
interface ISpot {
    /// @dev Emitted when an account balance is updated
    /// @param account account address
    /// @param token token address
    /// @param delta amount of token to update
    /// @param newBalance new balance of the account
    event UpdateBalance(address indexed account, address token, int256 delta, int256 newBalance);

    /// @notice Stores collateral balance of an account
    struct Balance {
        int256 amount;
    }

    /// @notice Account delta information to modify
    struct AccountDelta {
        address token;
        address account;
        int256 amount;
    }

    /// @notice Modifies the balance of an account.
    /// @param productDeltas  The information of the account to modify.
    /// Include token address, account address, amount of product.
    function modifyAccount(AccountDelta[] memory productDeltas) external;

    /// @notice Updates the total balance of a collateral token
    /// @param token Token address
    /// @param amount Amount of token to set
    /// @param increase boolean value to increase or decrease
    function setTotalBalance(address token, uint256 amount, bool increase) external;

    /// @notice Gets the collateral balance of an account
    /// @param token Token address
    /// @param account Account address
    /// @return Balance of the account
    function getBalance(address token, address account) external view returns (int256);

    /// @notice Gets the total balance of a collateral token
    /// @param token Token address
    /// @return Total balance of the token
    function getTotalBalance(address token) external view returns (uint256);
}

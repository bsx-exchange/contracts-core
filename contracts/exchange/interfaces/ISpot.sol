// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;
import "./IClearingService.sol";

interface ISpot {
    error NotSequencer();

    /**
     * @dev This struct represents the balance of an account.
     * @param amount Number of tokens
     */
    struct Balance {
        int256 amount;
    }

    /**
     * @param productDeltas The information of the account to modify.
     * Include token address, account address, amount of product.
     */
    struct AccountDelta {
        address token;
        address account;
        int256 amount;
    }
    struct BalanceInfo {
        address account;
        address token;
        int256 amount;
    }

    /**
     * @dev This function modifies the balance of an account.
     * @param productDeltas  The information of the account to modify.
     * Include token address, account address, amount of product.
     */
    function modifyAccount(AccountDelta[] memory productDeltas) external;

    /**
     * @dev This function gets the balance of an account.
     * @param _token Token address
     * @param _account Account address
     * @return Balance of the account
     */
    function getBalance(
        address _token,
        address _account
    ) external view returns (int256);

    /**
     * @dev This function gets the total balance of a token.
     * @param _token Token address
     *@return Total balance of the token
     */
    function getTotalBalance(address _token) external view returns (uint256);

    /**
     * @dev This function set the total balance of a token. Decrease or increase.
     * @param _token Token address
     * @param _amount Amount of token to set
     * @param _increase boolean value to increase or decrease
     */
    function setTotalBalance(
        address _token,
        uint256 _amount,
        bool _increase
    ) external;
}

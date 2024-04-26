// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;
import "./IPerp.sol";
import "./ISpot.sol";

interface IClearingService {
    error NotExchange();
    error NotOrderBook();
    error InvalidAmount();
    error InsufficientBalance();
    error TransferFailed();

    /**
     * @dev Struct of account delta, used to modify account balance.
     * @param token Token address
     * @param account Account address
     * @param amount Amount of token
     * @param quoteAmount Amount of quote token
     */
    struct AccountDelta {
        address token;
        address account;
        int256 amount;
        int256 quoteAmount;
    }

    /**
     * @dev Deposit token to spot account.
     * @param account Account address
     * @param amount Amount of token
     * @param token Token address
     * @param spotEngine Spot engine address
     */
    function deposit(
        address account,
        uint256 amount,
        address token,
        ISpot spotEngine
    ) external;

    /**
     * @dev Withdraw token from spot account.
     * @param account Account address
     * @param amount Amount of token
     * @param token Token address
     * @param spotEngine Spot engine address
     */
    function withdraw(
        address account,
        uint256 amount,
        address token,
        ISpot spotEngine
    ) external;

    /**
     * @dev Deposit token to insurance fund.
     * @param amount Amount of token
     */
    function depositInsuranceFund(uint256 amount) external;

    /**
     * @dev Withdraw token from insurance fund.
     * @param amount Amount of token
     */
    function withdrawInsuranceFundEmergency(uint256 amount) external;

    /**
     * @dev Get insurance fund.
     */
    function getInsuranceFund() external view returns (uint256);

    /**
     * @dev This function will use the insurance fund to cover the loss of the account.
     * @param account Account address
     * @param amount Amount of token
     * @param spotEngine Spot engine address
     */
    function insuranceCoverLost(
        address account,
        uint256 amount,
        ISpot spotEngine,
        address token
    ) external;

    // /**
    //  * @dev This function will take the fee from the account and send it to the insurance fund.
    //  * @param amount Amount of token
    //  */
    // function contributeToInsuranceFund(int256 amount) external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title Clearinghouse
/// @notice Manage insurance fund state and interact with spot engine
interface IClearinghouse {
    /// @notice Throws when the insurance fund is insufficient
    error InsufficientFund(uint256 insuranceFund, uint256 amount);

    /// @notice Throws when there is no need to cover the loss
    error NoNeedToCover(address account, address token, int256 spotBalance);

    /*//////////////////////////////////////////////////////////////////////////
                                NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Deposit token to spot account
    /// @param account Account address
    /// @param token Token address
    /// @param amount Standardized amount of token (18 decimals)
    function deposit(address account, address token, uint256 amount) external;

    /// @notice Withdraw token from spot account
    /// @param account Account address
    /// @param token Token address
    /// @param amount Standardized amount of token (18 decimals)
    function withdraw(address account, address token, uint256 amount) external;

    /// @notice Deposit token to insurance fund
    /// @param amount Standardized amount of token (18 decimals)
    function depositInsuranceFund(uint256 amount) external;

    /// @notice Withdraw token from insurance fund
    /// @param amount Standardized amount of token (18 decimals)
    function withdrawInsuranceFund(uint256 amount) external;

    /// @notice Cover the loss of bankrupt account
    /// @param account Account address
    /// @param token Token address
    function coverLossWithInsuranceFund(address account, address token) external;

    /*//////////////////////////////////////////////////////////////////////////
                                CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Get insurance fund.
    function getInsuranceFund() external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title Clearing service interface
/// @notice Manage insurance fund and spot balance
interface IClearingService {
    /// @dev Emitted when liquidation fee is collected
    event CollectLiquidationFee(address indexed account, uint64 indexed nonce, uint256 amount, uint256 insuranceFund);

    /// @notice Deposits token to spot account
    /// @param account Account address
    /// @param amount Amount of token
    /// @param token Token address
    function deposit(address account, uint256 amount, address token) external;

    /// @notice Withdraws token from spot account
    /// @param account Account address
    /// @param amount Amount of token
    /// @param token Token address
    function withdraw(address account, uint256 amount, address token) external;

    /// @notice Deposits token to insurance fund
    /// @param amount Amount of token
    function depositInsuranceFund(uint256 amount) external;

    /// @notice Withdraw token from insurance fund
    /// @param amount Amount of token
    function withdrawInsuranceFundEmergency(uint256 amount) external;

    /// @notice Withdraw token from insurance fund
    /// @param account Account is liquidated
    /// @param nonce Order nonce
    /// @param amount Amount of token (in 18 decimals)
    function collectLiquidationFee(address account, uint64 nonce, uint256 amount) external;

    /// @notice Uses the insurance fund to cover the loss of the account
    /// @param account Account address to cover loss
    /// @param amount Amount to cover loss
    function coverLossWithInsuranceFund(address account, uint256 amount) external;

    /// @notice Gets insurance fund balance
    function getInsuranceFundBalance() external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title Clearing service interface
/// @notice Manage insurance fund and spot balance
interface IClearingService {
    /// @notice Insurance fund balance
    struct InsuranceFund {
        uint256 inUSDC;
        uint256 inBSX;
    }

    /// @dev Emitted when liquidation fee is collected
    event CollectLiquidationFee(
        address indexed account, uint64 indexed nonce, uint256 amount, bool isFeeInBSX, InsuranceFund insuranceFund
    );

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

    /// @notice Transfer token between 2 accounts
    /// @param from Sender address
    /// @param to Recipient address
    /// @param token Token address
    /// @param amount Amount of token
    function transfer(address from, address to, int256 amount, address token) external;

    /// @notice Deposits token to insurance fund
    /// @param token Token address
    /// @param amount Amount of token (in 18 decimals)
    function depositInsuranceFund(address token, uint256 amount) external;

    /// @notice Withdraw token from insurance fund
    /// @param token Token address
    /// @param amount Amount of token (in 18 decimals)
    function withdrawInsuranceFund(address token, uint256 amount) external;

    /// @notice Withdraw token from insurance fund
    /// @param account Account is liquidated
    /// @param nonce Order nonce
    /// @param amount Amount of token (in 18 decimals)
    /// @param isFeeInBSX Whether the fee is in BSX or not
    function collectLiquidationFee(address account, uint64 nonce, uint256 amount, bool isFeeInBSX) external;

    /// @notice Uses the insurance fund to cover the loss of the account
    /// @param account Account address to cover loss
    /// @param amount Amount to cover loss
    function coverLossWithInsuranceFund(address account, uint256 amount) external;

    /// @notice Gets insurance fund balance
    function getInsuranceFundBalance() external view returns (InsuranceFund memory);
}

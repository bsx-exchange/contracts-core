// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title ILiquidation
/// @notice Interface for collateral asset liquidation operations
interface ILiquidation {
    struct LiquidationParams {
        // The account whose collateral is being liquidated
        address account;
        // A unique nonce to prevent replay attacks
        uint256 nonce;
        // Details of the liquidation executions
        ExecutionParams[] executions;
        // The fee in pips to be charged for the liquidation
        uint16 feePips;
    }

    struct ExecutionParams {
        // The asset to be liquidated
        address liquidationAsset;
        // The commands to be executed by the Universal Router
        bytes commands;
        // The input parameters for the commands
        bytes[] inputs;
    }

    enum AccountLiquidationStatus {
        // The account liquidation succeeded fully
        Success,
        // The account liquidation succeeded partially
        Partial,
        // The account liquidation failed
        Failure
    }

    enum CollateralLiquidationStatus {
        // The collateral liquidation succeeded
        Success,
        // The collateral liquidation failed
        Failure
    }

    /// @notice Emitted when a collateral liquidation is attempted
    /// @param account The account whose collateral was involved
    /// @param nonce The unique nonce of the liquidation attempt
    /// @param collateral The collateral token being liquidated
    /// @param status The outcome of the liquidation (Success, Failure)
    /// @param liquidationAmount The amount of collateral attempted to liquidate (in 18 decimals)
    /// @param receivedAmount The amount received from the liquidation (in 18 decimals)
    /// @param feeAmount The amount of liquidation fee collected from received amount (in 18 decimals)
    event LiquidateCollateral(
        address indexed account,
        uint256 indexed nonce,
        address indexed collateral,
        CollateralLiquidationStatus status,
        uint256 liquidationAmount,
        uint256 receivedAmount,
        uint256 feeAmount
    );

    /// @notice Emitted when an account liquidation attempt is completed
    /// @param account The account whose liquidation was attempted
    /// @param nonce The unique nonce of the liquidation attempt
    /// @param status The result of the liquidation attempt (Success, Partial, Failure)
    event LiquidateAccount(address indexed account, uint256 indexed nonce, AccountLiquidationStatus status);

    /// @notice Liquidates collateral assets for multiple accounts in a batch
    /// @dev Can only be called by an address with the COLLATERAL_OPERATOR_ROLE
    /// @param params The array of liquidation parameters for each account
    function liquidateCollateralBatch(LiquidationParams[] calldata params) external;
}

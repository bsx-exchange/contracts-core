// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title ISwap
/// @notice Interface for swap operations
interface ISwap {
    enum SwapCollateralStatus {
        // Collateral swap succeeded
        Success,
        // Collateral swap failed
        Failure
    }

    struct SwapParams {
        address account;
        uint256 nonce;
        address assetIn;
        uint256 amountIn;
        address assetOut;
        uint256 minAmountOut;
        uint256 feeAmount;
        bytes commands;
        bytes[] inputs;
        bytes signature;
    }

    /// @notice Emitted when a collateral swap is attempted
    /// @param account The account whose collateral was involved
    /// @param nonce The unique nonce of the swap attempt
    /// @param assetIn The collateral asset being swapped
    /// @param amountIn The amount of collateral to be swapped (in 18 decimals)
    /// @param assetOut The asset being swapped to
    /// @param amountOut The amount of asset being swapped (in 18 decimals)
    /// @param feeAsset The token used for fees
    /// @param feeAmount The amount of fees (in 18 decimals)
    /// @param status The result of the swap attempt
    event SwapCollateral(
        address indexed account,
        uint256 indexed nonce,
        address assetIn,
        uint256 amountIn,
        address assetOut,
        uint256 amountOut,
        address feeAsset,
        uint256 feeAmount,
        SwapCollateralStatus status
    );

    /// @notice Swap collateral batch
    /// @param params The array of swap parameters
    /// @dev Can only be called by an address with the COLLATERAL_OPERATOR_ROLE
    function swapCollateralBatch(SwapParams[] calldata params) external;

    /// @notice Swap between two assets on a single account with user permission
    /// @dev Internal function to catch exceptions if fail to swap
    /// Only called by this contract.
    /// @param params The liquidation parameters for the account
    /// @return amountOutX18 The scaled amount out of the swap (in 18 decimals)
    function innerSwapWithPermit(SwapParams calldata params) external returns (uint256 amountOutX18);
}

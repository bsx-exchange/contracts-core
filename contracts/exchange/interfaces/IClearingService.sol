// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ISwap} from "./ISwap.sol";

/// @title Clearing service interface
/// @notice Manage insurance fund and spot balance
interface IClearingService {
    enum ActionStatus {
        Success,
        Failure
    }

    enum SwapType {
        Unknown,
        DepositVault,
        RedeemVault,
        LiquidateYieldAsset,
        EarnYieldAsset
    }

    /// @notice Insurance fund balance
    struct InsuranceFund {
        uint256 inUSDC;
        uint256 inBSX;
    }

    /// @notice Account shares of a yield vault
    struct VaultShare {
        // Total shares owned by the account (in 18 decimals)
        uint256 shares;
        // Average price of the shares (in 18 decimals)
        uint256 avgPrice;
    }

    /// @dev Emitted when a new yield asset is added
    event AddYieldAsset(address indexed token, address indexed yieldAsset);

    /// @dev Emitted when liquidation fee is collected
    event CollectLiquidationFee(
        address indexed account, uint64 indexed nonce, uint256 amount, bool isFeeInBSX, InsuranceFund insuranceFund
    );

    /// @dev Emitted when swap user assets
    event SwapAssets(
        address indexed account,
        uint256 nonce,
        address indexed assetIn,
        uint256 amountIn,
        address indexed assetOut,
        uint256 amountOut,
        address feeAsset,
        uint256 feeAmount,
        SwapType swapType,
        ActionStatus status
    );

    /// @notice Add a new yield asset for a token to farm yield for user collateral
    function addYieldAsset(address token, address yieldAsset) external;

    /// @notice Deposit collateral to yield vault
    function earnYieldAsset(address account, address assetIn, uint256 amountIn) external;

    /// @notice Swap between collateral and yield token with user permit
    function swapYieldAssetPermit(ISwap.SwapParams calldata params) external;

    /// @notice If the account has a yield asset and the current underlying balance is insufficient,
    /// pull assets from the vault.
    function liquidateYieldAssetIfNecessary(address account, address token) external;

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

    /// @notice Gets a yield asset of a collateral token
    function yieldAssets(address token) external view returns (address);
}

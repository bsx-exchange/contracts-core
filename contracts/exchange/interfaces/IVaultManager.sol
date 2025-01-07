// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IVaultManager {
    struct VaultConfig {
        uint256 profitShareBps;
        address feeRecipient;
        bool isRegistered;
    }

    struct VaultData {
        uint256 totalShares;
    }

    struct StakerData {
        uint256 shares;
        uint256 avgPrice;
    }

    /// @notice Registers a new vault
    /// @param vault The address of the vault
    /// @param feeRecipient The address of the fee recipient
    /// @param profitShareBps The profit share basis points (1 = 0.01%)
    /// @param signature The signature of the vault
    function registerVault(address vault, address feeRecipient, uint256 profitShareBps, bytes memory signature)
        external;

    /// @notice Gets the configuration of a vault
    function getVaultConfig(address vault) external view returns (VaultConfig memory);

    /// @notice Stakes a specified amount of the underlying asset
    /// @return shares The amount of shares minted
    function stake(address vault, address account, address token, uint256 amount, uint256 nonce, bytes memory signature)
        external
        returns (uint256 shares);

    /// @notice Unstakes a specified amount of the underlying asset
    /// @return shares The amount of shares burned
    /// @return fee The fee amount paid to the fee recipient
    /// @return feeRecipient The address of the fee recipient
    function unstake(
        address vault,
        address account,
        address token,
        uint256 amount,
        uint256 nonce,
        bytes memory signature
    ) external returns (uint256 shares, uint256 fee, address feeRecipient);

    /// @notice Return underlying asset address
    function asset() external view returns (address);

    /// @notice Checks if a vault is registered
    function isRegistered(address vault) external view returns (bool);

    /// @notice Gets the total assets of a vault
    function getTotalAssets(address vault) external view returns (int256);

    /// @notice Gets the total shares of a vault
    function getTotalShares(address vault) external view returns (uint256);

    /// @notice Converts assets to shares
    function convertToShares(address vault, uint256 assets) external view returns (uint256);

    /// @notice Converts shares to assets
    function convertToAssets(address vault, uint256 shares) external view returns (uint256);

    /// @notice Checks if a stake nonce is used
    function isStakeNonceUsed(address account, uint256 nonce) external view returns (bool);

    /// @notice Checks if an unstake nonce is used
    function isUnstakeNonceUsed(address account, uint256 nonce) external view returns (bool);
}

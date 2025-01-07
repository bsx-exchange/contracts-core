// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IVaultManager {
    struct VaultConfig {
        uint256 profitShareBps;
        address feeRecipient;
        bool isRegistered;
    }

    /// @notice Emitted when a new vault is registered
    event RegisterVault(address indexed vault, address indexed feeRecipient, uint256 profitShareBps);

    /// @notice Registers a new vault
    /// @param vault The address of the vault
    /// @param feeRecipient The address of the fee recipient
    /// @param profitShareBps The profit share basis points (1 = 0.01%)
    /// @param signature The signature of the vault
    function registerVault(address vault, address feeRecipient, uint256 profitShareBps, bytes memory signature)
        external;

    /// @notice Gets the configuration of a vault
    function getVaultConfig(address vault) external view returns (VaultConfig memory);

    /// @notice Checks if a vault is registered
    function isRegistered(address vault) external view returns (bool);
}

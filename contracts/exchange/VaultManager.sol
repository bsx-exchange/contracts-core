// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Access} from "./access/Access.sol";
import {IExchange} from "./interfaces/IExchange.sol";
import {ISpot} from "./interfaces/ISpot.sol";
import {IVaultManager} from "./interfaces/IVaultManager.sol";
import {Errors} from "./lib/Errors.sol";
import {UNIVERSAL_SIG_VALIDATOR} from "./share/Constants.sol";

contract VaultManager is IVaultManager, Initializable {
    bytes32 public constant REGISTER_VAULT_TYPEHASH =
        keccak256("RegisterVault(address vault,address feeRecipient,uint256 profitShareBps)");
    uint256 private constant MAX_PROFIT_SHARE_BPS = 10_000; // 100%

    Access public access;
    address public asset;

    mapping(address vault => VaultConfig config) private _vaultConfig;
    mapping(address feeRecipient => bool isRegistered) private _feeRecipients;

    modifier onlyExchange() {
        if (msg.sender != address(access.getExchange())) revert Errors.Unauthorized();
        _;
    }

    function initialize(address _access, address _asset) external initializer {
        access = Access(_access);
        asset = _asset;
    }

    /// @inheritdoc IVaultManager
    function registerVault(address vault, address feeRecipient, uint256 profitShareBps, bytes memory signature)
        external
        onlyExchange
    {
        if (isRegistered(vault)) revert Errors.Vault_AlreadyRegistered(vault);

        if (_feeRecipients[vault]) {
            revert Errors.Vault_InvalidVaultAddress(vault);
        }
        if (vault == feeRecipient || isRegistered(feeRecipient)) {
            revert Errors.Vault_InvalidFeeRecipient(vault, feeRecipient);
        }
        if (profitShareBps > MAX_PROFIT_SHARE_BPS) {
            revert Errors.Vault_InvalidProfitShareBps(vault, profitShareBps);
        }

        IExchange exchange = access.getExchange();
        ISpot spotEngine = access.getSpotEngine();

        // check signature
        bytes32 registerVaultHash = exchange.hashTypedDataV4(
            keccak256(abi.encode(REGISTER_VAULT_TYPEHASH, vault, feeRecipient, profitShareBps))
        );
        if (!UNIVERSAL_SIG_VALIDATOR.isValidSig(vault, registerVaultHash, signature)) {
            revert Errors.InvalidSignature(vault);
        }

        // check vault balance
        address[] memory supportedTokens = exchange.getSupportedTokenList();
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            int256 balance = spotEngine.getBalance(token, vault);
            if (balance != 0) {
                revert Errors.Vault_NotZeroBalance(vault, token, balance);
            }
        }

        _vaultConfig[vault] =
            VaultConfig({profitShareBps: profitShareBps, feeRecipient: feeRecipient, isRegistered: true});
        _feeRecipients[feeRecipient] = true;

        emit RegisterVault(vault, feeRecipient, profitShareBps);
    }

    /// @inheritdoc IVaultManager
    function getVaultConfig(address vault) public view returns (VaultConfig memory) {
        return _vaultConfig[vault];
    }

    /// @inheritdoc IVaultManager
    function isRegistered(address vault) public view override returns (bool) {
        return _vaultConfig[vault].isRegistered;
    }
}

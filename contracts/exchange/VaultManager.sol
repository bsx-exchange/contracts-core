// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

import {Access} from "./access/Access.sol";
import {IExchange} from "./interfaces/IExchange.sol";
import {ISpot} from "./interfaces/ISpot.sol";
import {IVaultManager} from "./interfaces/IVaultManager.sol";
import {Errors} from "./lib/Errors.sol";
import {UNIVERSAL_SIG_VALIDATOR} from "./share/Constants.sol";

contract VaultManager is IVaultManager, Initializable {
    using Math for uint256;
    using SafeCast for int256;
    using SafeCast for uint256;
    using SignedMath for int256;

    uint256 private constant BASIS_POINT_SCALE = 1e4;
    uint256 private constant PRICE_SCALE = 1e18;
    uint256 private constant MAX_PROFIT_SHARE_BPS = 10_000; // 100%

    bytes32 public constant REGISTER_VAULT_TYPEHASH =
        keccak256("RegisterVault(address vault,address feeRecipient,uint256 profitShareBps)");
    bytes32 public constant STAKE_VAULT_TYPEHASH =
        keccak256("StakeVault(address vault,address account,address token,uint256 amount,uint256 nonce)");
    bytes32 public constant UNSTAKE_VAULT_TYPEHASH =
        keccak256("UnstakeVault(address vault,address account,address token,uint256 amount,uint256 nonce)");

    Access public access;
    address public asset;

    mapping(address vault => VaultConfig config) private _vaultConfig;
    mapping(address feeRecipient => bool isRegistered) private _feeRecipients;
    mapping(address vault => VaultData data) private _vaults;
    mapping(address vault => mapping(address account => StakerData data)) private _stakers;
    mapping(address account => mapping(uint256 nonce => bool used)) public isStakeNonceUsed;
    mapping(address account => mapping(uint256 nonce => bool used)) public isUnstakeNonceUsed;
    mapping(address account => uint256 count) public vaultCount;

    modifier onlyExchange() {
        if (msg.sender != address(access.getExchange())) revert Errors.Unauthorized();
        _;
    }

    modifier isVault(address vault) {
        if (!isRegistered(vault)) revert Errors.Vault_NotRegistered(vault);
        _;
    }

    // function initialize(address _access, address _asset) external initializer {
    //     access = Access(_access);
    //     asset = _asset;
    // }

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
    }

    /// @inheritdoc IVaultManager
    function stake(address vault, address account, address token, uint256 amount, uint256 nonce, bytes memory signature)
        external
        onlyExchange
        isVault(vault)
        returns (uint256)
    {
        _assertMainAccount(account);

        if (token != asset) {
            revert Errors.Vault_InvalidToken(token, asset);
        }
        if (isStakeNonceUsed[account][nonce]) {
            revert Errors.Vault_Stake_UsedNonce(account, nonce);
        }
        isStakeNonceUsed[account][nonce] = true;

        // validate signature
        IExchange exchange = access.getExchange();
        bytes32 stakeHash =
            exchange.hashTypedDataV4(keccak256(abi.encode(STAKE_VAULT_TYPEHASH, vault, account, token, amount, nonce)));
        if (!UNIVERSAL_SIG_VALIDATOR.isValidSig(account, stakeHash, signature)) {
            revert Errors.InvalidSignature(account);
        }

        // withdraw from clearing service
        int256 currentBalance = exchange.balanceOf(account, asset);
        if (amount.toInt256() > currentBalance) {
            revert Errors.Vault_Stake_InsufficientBalance(account, currentBalance, amount);
        }

        amount = _coverVaultLoss(vault, account, amount);

        VaultData storage vaultData = _vaults[vault];
        StakerData storage staker = _stakers[vault][account];

        uint256 mintShares = convertToShares(vault, amount);
        uint256 currentPrice = amount.mulDiv(PRICE_SCALE, mintShares);

        uint256 prevShares = staker.shares;
        uint256 prevPrice = staker.avgPrice;

        staker.avgPrice = (prevShares * prevPrice + mintShares * currentPrice) / (prevShares + mintShares);
        staker.shares += mintShares;

        vaultData.totalShares += mintShares;

        if (prevShares == 0 && mintShares > 0) {
            vaultCount[account]++;
        }

        access.getClearingService().withdraw(account, amount, asset);
        access.getClearingService().deposit(vault, amount, asset);

        return mintShares;
    }

    /// @inheritdoc IVaultManager
    function unstake(
        address vault,
        address account,
        address token,
        uint256 amount,
        uint256 nonce,
        bytes memory signature
    ) external onlyExchange isVault(vault) returns (uint256 shares, uint256 fee, address feeRecipient) {
        if (token != asset) {
            revert Errors.Vault_InvalidToken(token, asset);
        }
        if (isUnstakeNonceUsed[account][nonce]) {
            revert Errors.Vault_Unstake_UsedNonce(account, nonce);
        }
        isUnstakeNonceUsed[account][nonce] = true;

        // validate signature
        IExchange exchange = access.getExchange();
        bytes32 unstakeHash = exchange.hashTypedDataV4(
            keccak256(abi.encode(UNSTAKE_VAULT_TYPEHASH, vault, account, token, amount, nonce))
        );
        if (!UNIVERSAL_SIG_VALIDATOR.isValidSig(account, unstakeHash, signature)) {
            revert Errors.InvalidSignature(account);
        }

        VaultConfig memory vaultConfig = getVaultConfig(vault);
        VaultData storage vaultData = _vaults[vault];
        StakerData storage staker = _stakers[vault][account];

        shares = convertToShares(vault, amount);
        if (shares > staker.shares) {
            revert Errors.Vault_Unstake_InsufficientShares(account, staker.shares, shares);
        }
        uint256 currentPrice = amount.mulDiv(PRICE_SCALE, shares);
        uint256 avgPrice = staker.avgPrice;
        if (currentPrice > avgPrice) {
            uint256 profit = shares.mulDiv(currentPrice - avgPrice, PRICE_SCALE);
            feeRecipient = vaultConfig.feeRecipient;
            fee = profit.mulDiv(vaultConfig.profitShareBps, BASIS_POINT_SCALE);
            access.getClearingService().deposit(feeRecipient, fee, asset);
        }

        staker.shares -= shares;
        vaultData.totalShares -= shares;

        if (staker.shares == 0 && shares > 0) {
            vaultCount[account]--;
        }

        access.getClearingService().deposit(account, amount - fee, asset);
        access.getClearingService().withdraw(vault, amount, asset);
    }

    /// @inheritdoc IVaultManager
    function convertToShares(address vault, uint256 assets) public view virtual returns (uint256) {
        int256 totalAssets = getTotalAssets(vault);
        uint256 totalShares = getTotalShares(vault);

        if (totalAssets < 0) {
            revert Errors.Vault_NegativeBalance();
        }
        return assets.mulDiv(totalShares + 1, totalAssets.toUint256() + 1);
    }

    /// @inheritdoc IVaultManager
    function convertToAssets(address vault, uint256 shares) public view virtual returns (uint256) {
        int256 totalAssets = getTotalAssets(vault);
        uint256 totalShares = getTotalShares(vault);

        if (totalAssets < 0) {
            return 0;
        }
        return shares.mulDiv(totalAssets.toUint256() + 1, totalShares + 1);
    }

    /// @inheritdoc IVaultManager
    function getTotalAssets(address vault) public view returns (int256) {
        return access.getExchange().balanceOf(vault, asset);
    }

    /// @inheritdoc IVaultManager
    function getTotalShares(address vault) public view returns (uint256) {
        return _vaults[vault].totalShares;
    }

    function getStakerData(address vault, address account) public view returns (StakerData memory) {
        return _stakers[vault][account];
    }

    function getVaultData(address vault) public view returns (VaultData memory) {
        return _vaults[vault];
    }

    /// @inheritdoc IVaultManager
    function getVaultConfig(address vault) public view returns (VaultConfig memory) {
        return _vaultConfig[vault];
    }

    /// @inheritdoc IVaultManager
    function isRegistered(address vault) public view override returns (bool) {
        return _vaultConfig[vault].isRegistered;
    }

    /// @dev Assert that the account is a main account
    function _assertMainAccount(address account) private view {
        IExchange.AccountType accountType = access.getExchange().getAccountType(account);
        if (accountType != IExchange.AccountType.Main) {
            revert Errors.Exchange_InvalidAccountType(account);
        }
    }

    /// @dev If the total assets of a vault are negative, staker will need to cover the loss first
    function _coverVaultLoss(address vault, address account, uint256 amount) private returns (uint256) {
        int256 totalAssets = getTotalAssets(vault);
        if (totalAssets >= 0) {
            return amount;
        }

        uint256 coverAmount = access.getExchange().coverLoss(vault, account, asset);
        if (amount < coverAmount) {
            revert Errors.Vault_CoverLoss_InsufficientAmount(vault, account, coverAmount, amount);
        }

        return amount - coverAmount;
    }
}

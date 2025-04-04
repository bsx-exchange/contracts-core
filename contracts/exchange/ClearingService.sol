// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

import {Access} from "./access/Access.sol";
import {IClearingService} from "./interfaces/IClearingService.sol";
import {IExchange} from "./interfaces/IExchange.sol";
import {ISpot} from "./interfaces/ISpot.sol";
import {ISwap} from "./interfaces/ISwap.sol";
import {Errors} from "./lib/Errors.sol";
import {MathHelper} from "./lib/MathHelper.sol";
import {BSX_TOKEN, PRICE_SCALE, UNIVERSAL_SIG_VALIDATOR, USDC_TOKEN, ZERO_NONCE} from "./share/Constants.sol";

/// @title Clearinghouse contract
/// @notice Manage insurance fund and spot balance
/// @dev This contract is upgradeable
contract ClearingService is IClearingService, Initializable {
    using MathHelper for uint256;
    using SafeERC20 for IERC20;
    using SafeCast for int256;
    using SafeCast for uint256;
    using SignedMath for int256;

    Access public access;
    InsuranceFund private _insuranceFund;
    mapping(address underlyingToken => address yieldToken) public yieldAssets;
    mapping(address account => mapping(address vault => VaultShare shares)) public vaultShares;

    bytes32 public constant SWAP_TYPEHASH = keccak256(
        "Swap(address account,address assetIn,uint256 amountIn,address assetOut,uint256 minAmountOut,uint256 nonce)"
    );

    // function initialize(address _access) public initializer {
    //     if (_access == address(0)) {
    //         revert Errors.ZeroAddress();
    //     }
    //     access = Access(_access);
    // }

    function _checkRole(bytes32 role, address account) internal view {
        if (!access.hasRole(role, account)) {
            revert IAccessControl.AccessControlUnauthorizedAccount(account, role);
        }
    }

    modifier onlyRole(bytes32 role) {
        _checkRole(role, msg.sender);
        _;
    }

    modifier onlySequencer() {
        if (
            msg.sender != address(access.getExchange()) && msg.sender != address(access.getOrderBook())
                && msg.sender != address(access.getVaultManager())
        ) {
            revert Errors.Unauthorized();
        }
        _;
    }

    modifier internalCall() {
        if (msg.sender != address(this)) {
            revert Errors.ClearingService_InternalCall();
        }
        _;
    }

    /// @inheritdoc IClearingService
    function addYieldAsset(address token, address yieldAsset) external onlyRole(access.GENERAL_ROLE()) {
        if (!access.getExchange().isSupportedToken(token)) {
            revert Errors.Exchange_TokenNotSupported(token);
        }
        if (yieldAsset == address(0)) {
            revert Errors.ZeroAddress();
        }

        if (yieldAssets[token] != address(0)) {
            revert Errors.ClearingService_YieldAsset_AlreadyExists(token, yieldAsset);
        }

        if (IERC4626(yieldAsset).asset() != token) {
            revert Errors.ClearingService_YieldAsset_AssetMismatch(token, yieldAsset);
        }
        yieldAssets[token] = yieldAsset;

        emit AddYieldAsset(token, yieldAsset);
    }

    /// @inheritdoc IClearingService
    function earnYieldAsset(address account, address assetIn, uint256 amountIn) external onlySequencer {
        address assetOut = yieldAssets[assetIn];
        if (assetOut == address(0)) {
            revert Errors.ZeroAddress();
        }
        uint256 amountOut = this.innerSwapYieldAsset(account, assetIn, amountIn, assetOut, 0, SwapType.DepositVault);
        emit SwapAssets(
            account,
            ZERO_NONCE,
            assetIn,
            amountIn,
            assetOut,
            amountOut,
            address(0),
            0,
            SwapType.EarnYieldAsset,
            ActionStatus.Success
        );
    }

    /// @inheritdoc IClearingService
    function swapYieldAssetPermit(ISwap.SwapParams calldata params) external onlySequencer {
        address account = params.account;
        address assetIn = params.assetIn;
        uint256 amountIn = params.amountIn;
        address assetOut = params.assetOut;
        uint256 minAmountOut = params.minAmountOut;
        uint256 nonce = params.nonce;

        SwapType swapType;
        if (yieldAssets[assetIn] == assetOut) {
            swapType = SwapType.DepositVault;
        } else if (yieldAssets[assetOut] == assetIn) {
            swapType = SwapType.RedeemVault;
        } else {
            revert Errors.ClearingService_InvalidSwap(assetIn, assetOut);
        }

        // check signature
        IExchange exchange = access.getExchange();
        bytes32 swapCollateralHash = exchange.hashTypedDataV4(
            keccak256(abi.encode(SWAP_TYPEHASH, account, assetIn, amountIn, assetOut, minAmountOut, nonce))
        );
        if (!UNIVERSAL_SIG_VALIDATOR.isValidSig(account, swapCollateralHash, params.signature)) {
            emit SwapAssets(
                account, nonce, assetIn, amountIn, assetOut, 0, address(0), 0, swapType, ActionStatus.Failure
            );
            return;
        }

        try this.innerSwapYieldAsset(account, assetIn, amountIn, assetOut, minAmountOut, swapType) returns (
            uint256 amountOut
        ) {
            emit SwapAssets(
                account, nonce, assetIn, amountIn, assetOut, amountOut, address(0), 0, swapType, ActionStatus.Success
            );
        } catch {
            emit SwapAssets(
                account, nonce, assetIn, amountIn, assetOut, 0, address(0), 0, swapType, ActionStatus.Failure
            );
        }
    }

    /// @inheritdoc IClearingService
    function liquidateYieldAssetIfNecessary(address account, address token) external onlySequencer {
        address vault = yieldAssets[token];
        if (vault == address(0)) return;

        uint256 userShares = vaultShares[account][vault].shares;
        if (userShares == 0) return;

        int256 balance = access.getSpotEngine().getBalance(token, account);
        if (balance >= 0) return;

        uint256 loss = balance.abs();
        uint256 maxWithdrawAmount = _maxWithdrawFromVault(vault, token, account);
        uint256 minAmountOut = Math.min(loss, maxWithdrawAmount);
        uint256 amountIn = _previewWithdrawVault(vault, token, minAmountOut);

        try this.innerSwapYieldAsset(account, vault, amountIn, token, minAmountOut, SwapType.RedeemVault) returns (
            uint256 amountOut
        ) {
            emit SwapAssets(
                account,
                ZERO_NONCE,
                vault,
                amountIn,
                token,
                amountOut,
                address(0),
                0,
                SwapType.LiquidateYieldAsset,
                ActionStatus.Success
            );
        } catch {
            emit SwapAssets(
                account,
                ZERO_NONCE,
                vault,
                amountIn,
                token,
                0,
                address(0),
                0,
                SwapType.LiquidateYieldAsset,
                ActionStatus.Failure
            );
        }
    }

    /// @dev Handles asset swaps between collateral and yield-bearing vault assets.
    /// It is called internally by `swapYieldAsset` and `liquidateYieldAssetIfNecessary`.
    /// This function is wrapped in a try/catch to prevent the entire transaction from reverting.
    function innerSwapYieldAsset(
        address account,
        address assetIn,
        uint256 amountIn,
        address assetOut,
        uint256 minAmountOut,
        SwapType swapType
    ) external internalCall returns (uint256 amountOut) {
        address vault;
        address token;

        if (swapType == SwapType.DepositVault) {
            token = assetIn;
            vault = assetOut;
        } else if (swapType == SwapType.RedeemVault) {
            vault = assetIn;
            token = assetOut;
        } else {
            revert Errors.ClearingService_InvalidSwapType();
        }

        int256 balanceIn = access.getSpotEngine().getBalance(assetIn, account);
        if (balanceIn < amountIn.toInt256()) {
            revert Errors.ClearingService_InsufficientBalance(account, assetIn, balanceIn, amountIn);
        }

        amountOut = _callToErc4626Vault(vault, token, amountIn, swapType);
        if (amountOut == 0 || amountOut < minAmountOut) {
            revert Errors.ClearingService_SwapYieldAsset_AmountOutTooLittle();
        }

        _withdraw(account, amountIn, assetIn);
        _deposit(account, amountOut, assetOut);

        VaultShare storage data = vaultShares[account][vault];
        if (swapType == SwapType.DepositVault) {
            uint256 prevShares = data.shares;
            uint256 prevPrice = data.avgPrice;
            uint256 sharesOut = amountOut;
            uint256 currentPrice = Math.mulDiv(amountIn, PRICE_SCALE, sharesOut);
            data.avgPrice = (prevShares * prevPrice + sharesOut * currentPrice) / (prevShares + sharesOut);
            data.shares += sharesOut;
        } else {
            data.shares -= amountIn;
        }
    }

    /// @inheritdoc IClearingService
    function deposit(address account, uint256 amount, address token) external onlySequencer {
        _deposit(account, amount, token);
    }

    /// @inheritdoc IClearingService
    function withdraw(address account, uint256 amount, address token) external onlySequencer {
        _withdraw(account, amount, token);
    }

    /// @inheritdoc IClearingService
    function transfer(address from, address to, int256 amount, address token) external onlySequencer {
        ISpot spotEngine = access.getSpotEngine();
        // withdraw `amount` from `from` account
        spotEngine.updateBalance(from, token, -amount);
        // deposit `amount` to `to` account
        spotEngine.updateBalance(to, token, amount);
    }

    /// @inheritdoc IClearingService
    function collectLiquidationFee(address account, uint64 nonce, uint256 amount, bool isFeeInBSX)
        external
        onlySequencer
    {
        if (isFeeInBSX) {
            _insuranceFund.inBSX += amount;
        } else {
            _insuranceFund.inUSDC += amount;
        }
        emit CollectLiquidationFee(account, nonce, amount, isFeeInBSX, _insuranceFund);
    }

    /// @inheritdoc IClearingService
    function depositInsuranceFund(address token, uint256 amount) external onlySequencer {
        if (amount == 0) {
            revert Errors.ClearingService_ZeroAmount();
        }

        if (token == USDC_TOKEN) {
            _insuranceFund.inUSDC += amount;
        } else if (token == BSX_TOKEN) {
            _insuranceFund.inBSX += amount;
        } else {
            revert Errors.ClearingService_InvalidToken(token);
        }
    }

    /// @inheritdoc IClearingService
    function withdrawInsuranceFund(address token, uint256 amount) external onlySequencer {
        if (amount == 0) {
            revert Errors.ClearingService_ZeroAmount();
        }
        if (token == USDC_TOKEN) {
            _insuranceFund.inUSDC -= amount;
        } else if (token == BSX_TOKEN) {
            _insuranceFund.inBSX -= amount;
        } else {
            revert Errors.ClearingService_InvalidToken(token);
        }
    }

    /// @inheritdoc IClearingService
    function coverLossWithInsuranceFund(address account, uint256 amount) external onlySequencer {
        ISpot spotEngine = ISpot(access.getSpotEngine());

        address collateralToken = USDC_TOKEN;
        int256 balance = spotEngine.getBalance(collateralToken, account);
        if (balance >= 0) {
            revert Errors.ClearingService_NoLoss(account, balance);
        }

        uint256 insuranceFundInUSDC = _insuranceFund.inUSDC;
        if (amount > insuranceFundInUSDC) {
            revert Errors.ClearingService_InsufficientFund(amount, insuranceFundInUSDC);
        }
        _insuranceFund.inUSDC -= amount;

        spotEngine.updateBalance(account, collateralToken, amount.toInt256());
    }

    /// @inheritdoc IClearingService
    function getInsuranceFundBalance() external view returns (InsuranceFund memory) {
        return _insuranceFund;
    }

    /// @dev Increase spot balance of an account and total balance
    function _deposit(address account, uint256 amount, address token) internal {
        ISpot spotEngine = access.getSpotEngine();
        int256 _amount = amount.toInt256();
        spotEngine.updateBalance(account, token, _amount);
        spotEngine.updateTotalBalance(token, _amount);
    }

    /// @dev Decrease spot balance of an account and total balance
    function _withdraw(address account, uint256 amount, address token) internal {
        ISpot spotEngine = access.getSpotEngine();
        int256 _amount = -amount.toInt256();
        spotEngine.updateBalance(account, token, _amount);
        spotEngine.updateTotalBalance(token, _amount);
    }

    /// @dev Executes ERC4626 vault action: Deposit, Redeem
    /// @param vault ERC4626 vault address
    /// @param token Underlying token of the vault
    /// @param amountIn Amount of token to deposit, redeem (in 18 decimals)
    /// @param swapType Type of swap: DepositVault, RedeemVault
    /// @return amountOut Amount of token received from the vault (in 18 decimals)
    function _callToErc4626Vault(address vault, address token, uint256 amountIn, SwapType swapType)
        private
        returns (uint256 amountOut)
    {
        if (token != IERC4626(vault).asset()) {
            revert Errors.ClearingService_YieldAsset_AssetMismatch(token, vault);
        }
        address tokenOut;

        if (swapType == SwapType.DepositVault) {
            uint256 assets = amountIn.convertFromScale(token);
            access.getExchange().requestToken(token, assets);
            IERC20(token).forceApprove(vault, assets);

            tokenOut = vault;
            amountOut = IERC4626(vault).deposit(assets, address(this));
        } else if (swapType == SwapType.RedeemVault) {
            uint256 shares = amountIn.convertFromScale(vault);

            tokenOut = token;
            amountOut = IERC4626(vault).redeem(shares, address(access.getExchange()), address(this));
        }
        return amountOut.convertToScale(tokenOut);
    }

    /// @dev Calculate output shares when withdrawing from a vault
    function _previewWithdrawVault(address vault, address token, uint256 scaledAssets) private view returns (uint256) {
        uint256 assets = scaledAssets.convertFromScale(token);
        uint256 shares = IERC4626(vault).previewWithdraw(assets);
        return shares.convertToScale(vault);
    }

    /// @dev Calculate the maximum amount of an account can withdraw from a vault
    function _maxWithdrawFromVault(address vault, address token, address account) private view returns (uint256) {
        uint256 scaledShares = vaultShares[account][vault].shares;
        uint256 shares = scaledShares.convertFromScale(vault);
        uint256 maxWithdraw = IERC4626(vault).convertToAssets(shares);
        return maxWithdraw.convertToScale(token);
    }
}

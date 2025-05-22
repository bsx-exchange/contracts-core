// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IClearingService} from "../../interfaces/IClearingService.sol";
import {IExchange, ILiquidation} from "../../interfaces/IExchange.sol";
import {IOrderBook} from "../../interfaces/IOrderBook.sol";
import {ISpot} from "../../interfaces/ISpot.sol";
import {IUniversalRouter} from "../../interfaces/external/IUniversalRouter.sol";
import {Errors} from "../../lib/Errors.sol";
import {MathHelper} from "../../lib/MathHelper.sol";
import {Percentage} from "../../lib/Percentage.sol";
import {MAX_LIQUIDATION_FEE_RATE} from "../../share/Constants.sol";
import {MultiTxStatus, TxStatus} from "../../share/Enums.sol";
import {GenericLogic} from "./GenericLogic.sol";

library LiquidationLogic {
    using EnumerableSet for EnumerableSet.AddressSet;
    using MathHelper for uint256;
    using Percentage for uint128;
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /// @notice Performs batch liquidation for multiple accounts
    /// @dev Emits the `LiquidateAccount()` event for each account liquidation
    /// @param isLiquidationNonceUsed The state of liquidation nonce used
    /// @param exchange The exchange instance
    /// @param params The array of liquidation params for each account
    function liquidateCollateralBatch(
        mapping(address account => mapping(uint256 liquidationNonce => bool liquidated)) storage isLiquidationNonceUsed,
        IExchange exchange,
        ILiquidation.LiquidationParams[] calldata params
    ) external {
        for (uint256 i = 0; i < params.length; i++) {
            address account = params[i].account;
            uint256 nonce = params[i].nonce;
            uint16 feePips = params[i].feePips;

            if (params[i].executions.length == 0) {
                revert Errors.Exchange_Liquidation_EmptyExecution();
            }
            if (feePips > MAX_LIQUIDATION_FEE_RATE) {
                revert Errors.Exchange_Liquidation_ExceededMaxLiquidationFeePips(feePips);
            }
            if (isLiquidationNonceUsed[account][nonce]) {
                revert Errors.Exchange_Liquidation_NonceUsed(account, nonce);
            }
            isLiquidationNonceUsed[account][nonce] = true;

            try exchange.innerLiquidation(params[i]) returns (MultiTxStatus status) {
                // mark nonce as used
                emit ILiquidation.LiquidateAccount(account, nonce, status);
            } catch {
                emit ILiquidation.LiquidateAccount(account, nonce, MultiTxStatus.Failure);
            }
        }
    }

    struct LiquidationEngines {
        IOrderBook orderbook;
        IClearingService clearingService;
        ISpot spotEngine;
        IUniversalRouter universalRouter;
    }

    /// @notice Liquidates multiple collateral assets for an account
    /// @dev Emits the `LiquidateCollateral()` event for each collateral liquidation
    /// @param supportedTokens The state of supported tokens
    /// @param engines The additional engines needed for liquidation
    /// @param params The liquidation params
    /// @return status The result of all collateral liquidations
    function executeLiquidation(
        EnumerableSet.AddressSet storage supportedTokens,
        LiquidationEngines calldata engines,
        ILiquidation.LiquidationParams calldata params
    ) external returns (MultiTxStatus status) {
        address account = params.account;
        address underlyingAsset = engines.orderbook.getCollateralToken();
        uint256 execLen = params.executions.length;
        uint256 countFailure = 0;
        for (uint256 i = 0; i < execLen; i++) {
            ILiquidation.ExecutionParams calldata exec = params.executions[i];
            address liquidationAsset = exec.liquidationAsset;

            if (!supportedTokens.contains(liquidationAsset) || liquidationAsset == underlyingAsset) {
                revert Errors.Exchange_Liquidation_InvalidAsset(liquidationAsset);
            }

            // approve tokenIn
            int256 balanceInX18 = engines.spotEngine.getBalance(liquidationAsset, account);
            if (balanceInX18 <= 0) {
                revert Errors.Exchange_Liquidation_InvalidBalance(account, liquidationAsset, balanceInX18);
            }
            uint256 balanceIn = balanceInX18.toUint256().convertFromScale(liquidationAsset);
            IERC20(liquidationAsset).forceApprove(address(engines.universalRouter), balanceIn);

            // cache tokenIn balance before swap
            uint256 totalTokenInBefore = IERC20(liquidationAsset).balanceOf(address(this));

            // cache tokenOut balance before swap
            uint256 totalTokenOutBefore = IERC20(underlyingAsset).balanceOf(address(this));

            // execute swap
            GenericLogic.checkUniversalRouterCommands(exec.commands);
            try engines.universalRouter.execute(exec.commands, exec.inputs) {
                // calculate amountIn and check if it exceeds tokenIn balance
                uint256 totalTokenInAfter = IERC20(liquidationAsset).balanceOf(address(this));
                uint256 amountIn = totalTokenInBefore - totalTokenInAfter;
                uint256 amountInX18 = amountIn.convertToScale(liquidationAsset);
                if (amountIn > balanceIn) {
                    revert Errors.Exchange_Liquidation_ExceededBalance(
                        account, liquidationAsset, balanceInX18, amountInX18
                    );
                }
                // withdraw tokenIn
                engines.clearingService.withdraw(account, amountInX18, liquidationAsset);

                // calculate amountOut
                uint256 totalTokenOutAfter = IERC20(underlyingAsset).balanceOf(address(this));
                uint256 amountOut = totalTokenOutAfter - totalTokenOutBefore;
                uint256 amountOutX18 = amountOut.convertToScale(underlyingAsset);

                uint256 feeX18 = amountOutX18.toUint128().calculatePercentage(params.feePips);
                uint256 netAmountOutX18 = amountOutX18 - feeX18;

                // deposit tokenOut
                engines.clearingService.depositInsuranceFund(underlyingAsset, feeX18);
                engines.clearingService.deposit(account, netAmountOutX18, underlyingAsset);

                emit ILiquidation.LiquidateCollateral(
                    account, params.nonce, liquidationAsset, TxStatus.Success, amountInX18, netAmountOutX18, feeX18
                );
            } catch {
                countFailure += 1;
                emit ILiquidation.LiquidateCollateral(
                    account, params.nonce, liquidationAsset, TxStatus.Failure, 0, 0, 0
                );
            }

            // disapprove tokenIn
            IERC20(liquidationAsset).forceApprove(address(engines.universalRouter), 0);
        }

        if (countFailure == 0) {
            status = MultiTxStatus.Success;
        } else if (countFailure == execLen) {
            status = MultiTxStatus.Failure;
        } else {
            status = MultiTxStatus.Partial;
        }
    }
}

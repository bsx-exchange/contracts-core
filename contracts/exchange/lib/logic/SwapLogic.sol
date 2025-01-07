// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {Exchange} from "../../Exchange.sol";
import {IClearingService} from "../../interfaces/IClearingService.sol";
import {ISpot} from "../../interfaces/ISpot.sol";
import {ISwap} from "../../interfaces/ISwap.sol";
import {IUniversalRouter} from "../../interfaces/external/IUniversalRouter.sol";
import {Errors} from "../../lib/Errors.sol";
import {MathHelper} from "../../lib/MathHelper.sol";
import {Percentage} from "../../lib/Percentage.sol";
import {MAX_SWAP_FEE_RATE, UNIVERSAL_SIG_VALIDATOR} from "../../share/Constants.sol";
import {GenericLogic} from "./GenericLogic.sol";

library SwapLogic {
    using EnumerableSet for EnumerableSet.AddressSet;
    using MathHelper for uint256;
    using Percentage for uint128;
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    bytes32 public constant SWAP_TYPEHASH = keccak256(
        "Swap(address account,address assetIn,uint256 amountIn,address assetOut,uint256 minAmountOut,uint256 nonce)"
    );

    /// @notice Performs batch collateral swaps for multiple accounts using permit
    /// @dev Emits the `SwapCollateral()` event for each collateral swap
    /// Only reverts if nonce is used, otherwise emits the `SwapCollateral()` event with status
    /// @param exchange The exchange instance
    /// @param params The array of swap params for each swap
    function swapCollateralBatch(Exchange exchange, ISwap.SwapParams[] calldata params) external {
        for (uint256 i = 0; i < params.length; i++) {
            if (exchange.isSwapNonceUsed(params[i].account, params[i].nonce)) {
                revert Errors.Exchange_Swap_NonceUsed(params[i].account, params[i].nonce);
            }

            try exchange.innerSwapWithPermit(params[i]) returns (uint256 amountOutX18) {
                emit ISwap.SwapCollateral(
                    params[i].account,
                    params[i].nonce,
                    params[i].assetIn,
                    params[i].amountIn,
                    params[i].assetOut,
                    amountOutX18,
                    params[i].assetIn,
                    params[i].feeAmount,
                    ISwap.SwapCollateralStatus.Success
                );
            } catch {
                emit ISwap.SwapCollateral(
                    params[i].account,
                    params[i].nonce,
                    params[i].assetIn,
                    params[i].amountIn,
                    params[i].assetOut,
                    0,
                    params[i].assetIn,
                    0,
                    ISwap.SwapCollateralStatus.Failure
                );
            }
        }
    }

    struct SwapEngines {
        IClearingService clearingService;
        ISpot spotEngine;
        IUniversalRouter universalRouter;
    }

    /// @notice Swaps between two collaterals
    /// @param collectedFees The state of collected fees
    /// @param engines The additional engines needed for the swap
    /// @param params The swap parameters
    /// @return amountOutX18 The scaled amount out of the swap (in 18 decimals)
    function executeSwap(
        mapping(address => mapping(uint256 => bool)) storage isSwapNonceUsed,
        mapping(address token => uint256 collectedFee) storage collectedFees,
        Exchange exchange,
        SwapEngines calldata engines,
        ISwap.SwapParams calldata params
    ) external returns (uint256 amountOutX18) {
        // check signature
        bytes32 swapCollateralHash = exchange.hashTypedDataV4(
            keccak256(
                abi.encode(
                    SWAP_TYPEHASH,
                    params.account,
                    params.assetIn,
                    params.amountIn,
                    params.assetOut,
                    params.minAmountOut,
                    params.nonce
                )
            )
        );
        if (!UNIVERSAL_SIG_VALIDATOR.isValidSig(params.account, swapCollateralHash, params.signature)) {
            revert Errors.Exchange_InvalidSignature(params.account);
        }
        isSwapNonceUsed[params.account][params.nonce] = true;

        // check asset
        if (!exchange.isSupportedToken(params.assetIn) || !exchange.isSupportedToken(params.assetOut)) {
            revert Errors.Exchange_Swap_InvalidAsset();
        }

        if (params.assetIn == params.assetOut) {
            revert Errors.Exchange_Swap_SameAsset();
        }

        // check amountIn
        int256 balanceInX18 = exchange.balanceOf(params.account, params.assetIn);
        if (balanceInX18 <= 0 || balanceInX18.toUint256() < params.amountIn) {
            revert Errors.Exchange_Swap_ExceededBalance(params.account, params.assetIn, params.amountIn, balanceInX18);
        }

        // check feeAmount not exceed 1% of amountIn
        uint256 maxFeeAmount = params.amountIn.toUint128().calculatePercentage(MAX_SWAP_FEE_RATE);
        if (params.feeAmount > maxFeeAmount) {
            revert Errors.Exchange_Swap_ExceededMaxFee(params.feeAmount, maxFeeAmount);
        }

        uint256 swapAmountInX18 = params.amountIn - params.feeAmount;
        uint256 requestSwapAmountIn = swapAmountInX18.convertFromScale(params.assetIn);
        if (requestSwapAmountIn == 0) revert Errors.Exchange_ZeroAmount();

        // cache tokenIn, tokenOut balance before swap
        uint256 totalTokenInBefore = IERC20(params.assetIn).balanceOf(address(this));
        uint256 totalTokenOutBefore = IERC20(params.assetOut).balanceOf(address(this));

        // collect fee
        collectedFees[params.assetIn] += params.feeAmount;

        // approve tokenIn
        IERC20(params.assetIn).forceApprove(address(engines.universalRouter), requestSwapAmountIn);

        // swap assetIn for assetOut
        GenericLogic.checkUniversalRouterCommands(params.commands);
        engines.universalRouter.execute(params.commands, params.inputs);

        // check amountIn
        uint256 totalTokenInAfter = IERC20(params.assetIn).balanceOf(address(this));
        uint256 swappedAmountIn = totalTokenInBefore - totalTokenInAfter;
        if (requestSwapAmountIn != swappedAmountIn) {
            revert Errors.Exchange_Swap_AmountInMismatch(swappedAmountIn, requestSwapAmountIn);
        }

        // withdraw tokenIn
        engines.clearingService.withdraw(params.account, params.amountIn, params.assetIn);

        // check amountOut
        uint256 totalTokenOutAfter = IERC20(params.assetOut).balanceOf(address(this));
        uint256 amountOut = totalTokenOutAfter - totalTokenOutBefore;
        amountOutX18 = amountOut.convertToScale(params.assetOut);
        if (amountOutX18 < params.minAmountOut) {
            revert Errors.Exchange_Swap_AmountOutTooLittle(amountOutX18, params.minAmountOut);
        }

        // deposit tokenOut
        engines.clearingService.deposit(params.account, amountOutX18, params.assetOut);

        // disapprove tokenIn
        IERC20(params.assetIn).forceApprove(address(engines.universalRouter), 0);
    }
}

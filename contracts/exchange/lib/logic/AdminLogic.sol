// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IClearingService} from "../../interfaces/IClearingService.sol";
import {IExchange} from "../../interfaces/IExchange.sol";
import {IOrderBook} from "../../interfaces/IOrderBook.sol";
import {Errors} from "../../lib/Errors.sol";
import {MathHelper} from "../../lib/MathHelper.sol";
import {BSX_TOKEN, NATIVE_ETH, ZERO_ADDRESS} from "../../share/Constants.sol";

library AdminLogic {
    using EnumerableSet for EnumerableSet.AddressSet;
    using MathHelper for int128;
    using MathHelper for uint256;
    using SafeERC20 for IERC20;

    function addSupportedToken(
        IClearingService clearingService,
        EnumerableSet.AddressSet storage supportedTokens,
        address token
    ) external {
        if (token == ZERO_ADDRESS) {
            revert Errors.ZeroAddress();
        }

        for (uint256 i = 0; i < supportedTokens.length(); ++i) {
            address supportedToken = supportedTokens.at(i);
            address yieldAsset = clearingService.yieldAssets(supportedToken);
            if (yieldAsset == token) {
                revert Errors.Exchange_TokenIsYieldAsset(yieldAsset);
            }
        }

        bool success = supportedTokens.add(token);
        if (!success) {
            revert Errors.Exchange_TokenAlreadySupported(token);
        }
        emit IExchange.SupportedTokenAdded(token);
    }

    function removeSupportedToken(EnumerableSet.AddressSet storage supportedTokens, address token) external {
        bool success = supportedTokens.remove(token);
        if (!success) {
            revert Errors.Exchange_TokenNotSupported(token);
        }
        emit IExchange.SupportedTokenRemoved(token);
    }

    function claimTradingFees(IOrderBook orderbook, address caller, address feeRecipient) external {
        IOrderBook.FeeCollection memory tradingFees = orderbook.claimTradingFees();

        address usdc = orderbook.getCollateralToken();
        uint256 usdcAmount = tradingFees.inUSDC.safeUInt256();
        IERC20(usdc).safeTransfer(feeRecipient, usdcAmount.convertFromScale(usdc));

        uint256 bsxAmount = tradingFees.inBSX.safeUInt256();
        IERC20(BSX_TOKEN).safeTransfer(feeRecipient, bsxAmount.convertFromScale(BSX_TOKEN));

        emit IExchange.ClaimTradingFees(caller, tradingFees);
    }

    function claimSequencerFees(
        mapping(address => uint256) storage collectedFee,
        IExchange exchange,
        IOrderBook orderbook,
        address caller,
        address feeRecipient
    ) external {
        address underlyingAsset = orderbook.getCollateralToken();
        IOrderBook.FeeCollection memory sequencerFees = orderbook.claimSequencerFees();

        address[] memory supportedTokens = exchange.getSupportedTokenList();
        for (uint256 i = 0; i < supportedTokens.length; ++i) {
            address token = supportedTokens[i];
            if (token == NATIVE_ETH) {
                continue;
            }

            uint256 totalFees = collectedFee[token];
            if (token == underlyingAsset) {
                totalFees += sequencerFees.inUSDC.safeUInt256();
            } else if (token == BSX_TOKEN) {
                totalFees += sequencerFees.inBSX.safeUInt256();
            }
            collectedFee[token] = 0;

            uint256 amountToTransfer = totalFees.convertFromScale(token);
            IERC20(token).safeTransfer(feeRecipient, amountToTransfer);
            emit IExchange.ClaimSequencerFees(caller, token, totalFees);
        }
    }
}

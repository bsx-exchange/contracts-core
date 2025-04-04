// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IExchange} from "../../interfaces/IExchange.sol";
import {IOrderBook} from "../../interfaces/IOrderBook.sol";

import {MathHelper} from "../../lib/MathHelper.sol";
import {BSX_TOKEN, NATIVE_ETH} from "../../share/Constants.sol";

library AdminLogic {
    using MathHelper for int128;
    using MathHelper for uint256;
    using SafeERC20 for IERC20;

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

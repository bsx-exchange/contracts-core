// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IBSX1000x} from "../../../1000x/interfaces/IBSX1000x.sol";
import {IClearingService} from "../../interfaces/IClearingService.sol";
import {IExchange} from "../../interfaces/IExchange.sol";
import {ISpot} from "../../interfaces/ISpot.sol";
import {IERC3009Minimal} from "../../interfaces/external/IERC3009Minimal.sol";
import {IWETH9} from "../../interfaces/external/IWETH9.sol";
import {Errors} from "../../lib/Errors.sol";
import {MathHelper} from "../../lib/MathHelper.sol";
import {NATIVE_ETH, WETH9} from "../../share/Constants.sol";

library BalanceLogic {
    using SafeERC20 for IERC20;
    using MathHelper for uint128;
    using MathHelper for uint256;
    using MathHelper for int256;

    struct BalanceEngine {
        IClearingService clearingService;
        ISpot spot;
    }

    /// @notice Deposits token to spot account
    function deposit(BalanceEngine calldata engine, address recipient, address token, uint256 amount) external {
        if (amount == 0) revert Errors.Exchange_ZeroAmount();

        if (token == NATIVE_ETH) {
            token = WETH9;
            if (msg.value != amount) revert Errors.Exchange_InvalidEthAmount();
            IWETH9(token).deposit{value: amount}();
        } else {
            (uint256 roundDownAmount, uint256 amountToTransfer) = amount.roundDownAndConvertFromScale(token);
            if (roundDownAmount == 0 || amountToTransfer == 0) revert Errors.Exchange_ZeroAmount();
            amount = roundDownAmount.safeUInt128();
            IERC20(token).safeTransferFrom(msg.sender, address(this), amountToTransfer);
        }

        engine.clearingService.deposit(recipient, amount, token, engine.spot);
        emit IExchange.Deposit(token, recipient, amount, 0);
    }

    /// @notice Deposits collateral token with authorization
    /// @dev Supports only tokens compliant with the ERC-3009 standard.
    function depositWithAuthorization(
        BalanceEngine calldata engine,
        address depositor,
        address token,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        (uint256 roundDownAmount, uint256 amountToTransfer) = amount.roundDownAndConvertFromScale(token);
        if (roundDownAmount == 0 || amountToTransfer == 0) revert Errors.Exchange_ZeroAmount();

        IERC3009Minimal(token).receiveWithAuthorization(
            depositor, address(this), amountToTransfer, validAfter, validBefore, nonce, signature
        );

        engine.clearingService.deposit(depositor, roundDownAmount, token, engine.spot);
        emit IExchange.Deposit(token, depositor, roundDownAmount, 0);
    }

    /// @notice Withdraws collateral token
    function withdraw(
        mapping(address => uint256) storage _collectedFee,
        BalanceEngine calldata engine,
        IExchange.Withdraw calldata data
    ) external {
        address mappedToken = data.token == NATIVE_ETH ? WETH9 : data.token;
        uint128 maxWithdrawalFee = _getMaxWithdrawalFee(mappedToken);
        if (data.withdrawalSequencerFee > maxWithdrawalFee) {
            revert Errors.Exchange_ExceededMaxWithdrawFee(data.withdrawalSequencerFee, maxWithdrawalFee);
        }

        int256 currentBalance = engine.spot.getBalance(mappedToken, data.sender);
        if (currentBalance.safeInt128() < data.amount.safeInt128()) {
            emit IExchange.WithdrawFailed(data.sender, data.nonce, data.amount, currentBalance);
            return;
        }

        engine.clearingService.withdraw(data.sender, data.amount, mappedToken, engine.spot);
        _collectedFee[mappedToken] += data.withdrawalSequencerFee;

        uint256 netAmount = data.amount - data.withdrawalSequencerFee;
        if (data.token == NATIVE_ETH) {
            IWETH9(WETH9).withdraw(netAmount);
            Address.sendValue(payable(data.sender), netAmount);
        } else {
            uint256 amountToTransfer = netAmount.convertFromScale(data.token);
            IERC20(data.token).safeTransfer(data.sender, amountToTransfer);
        }
        emit IExchange.WithdrawSucceeded(
            data.token, data.sender, data.nonce, data.amount, 0, data.withdrawalSequencerFee
        );
    }

    function transferToBSX1000(
        BalanceEngine calldata engine,
        IBSX1000x bsx1000,
        address account,
        address token,
        uint256 amount
    ) external returns (uint256 newBalance) {
        IERC20 collateralBSX1000 = bsx1000.collateralToken();
        if (token != address(collateralBSX1000)) {
            revert Errors.Exchange_TransferToBSX1000_InvalidToken(token, address(collateralBSX1000));
        }
        uint256 amountToTransfer = amount.convertFromScale(token);
        if (amountToTransfer == 0) {
            revert Errors.Exchange_ZeroAmount();
        }

        int256 currentBalance = engine.spot.getBalance(token, account);
        if (currentBalance < amount.safeInt256()) {
            revert Errors.Exchange_TransferToBSX1000_InsufficientBalance(account, currentBalance, amount);
        }
        engine.clearingService.withdraw(account, amount, token, engine.spot);

        IERC20(token).forceApprove(address(bsx1000), amountToTransfer);
        bsx1000.deposit(account, amount);

        newBalance = currentBalance.safeUInt256() - amount;
    }

    /// @dev Returns the maximum withdrawal fee for a token
    function _getMaxWithdrawalFee(address token) internal pure returns (uint128) {
        if (token == WETH9) {
            return 0.001 ether;
        } else {
            return 1e18;
        }
    }
}

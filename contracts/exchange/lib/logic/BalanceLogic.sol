// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

import {IBSX1000x} from "../../../1000x/interfaces/IBSX1000x.sol";
import {IClearingService} from "../../interfaces/IClearingService.sol";
import {IExchange} from "../../interfaces/IExchange.sol";
import {ISpot} from "../../interfaces/ISpot.sol";
import {IERC3009Minimal} from "../../interfaces/external/IERC3009Minimal.sol";
import {IWETH9} from "../../interfaces/external/IWETH9.sol";
import {Errors} from "../../lib/Errors.sol";
import {MathHelper} from "../../lib/MathHelper.sol";
import {NATIVE_ETH, UNIVERSAL_SIG_VALIDATOR, WETH9} from "../../share/Constants.sol";

library BalanceLogic {
    using SafeERC20 for IERC20;
    using MathHelper for uint128;
    using MathHelper for uint256;
    using MathHelper for int256;

    struct BalanceEngine {
        IClearingService clearingService;
        ISpot spot;
    }

    bytes32 public constant TRANSFER_TO_BSX1000_TYPEHASH =
        keccak256("TransferToBSX1000(address account,address token,uint256 amount,uint256 nonce)");
    bytes32 public constant TRANSFER_TYPEHASH =
        keccak256("Transfer(address from,address to,address token,uint256 amount,uint256 nonce)");
    bytes32 public constant WITHDRAW_TYPEHASH =
        keccak256("Withdraw(address sender,address token,uint128 amount,uint64 nonce)");

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

        engine.clearingService.deposit(recipient, amount, token);
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

        engine.clearingService.deposit(depositor, roundDownAmount, token);
        emit IExchange.Deposit(token, depositor, roundDownAmount, 0);
    }

    /// @notice Withdraws collateral token
    function withdraw(
        mapping(address => IExchange.Account) storage accounts,
        mapping(address => uint256) storage collectedFees,
        IExchange exchange,
        BalanceEngine calldata engine,
        IExchange.Withdraw calldata data
    ) external {
        _assertMainAccount(accounts, data.sender);

        bytes32 digest = exchange.hashTypedDataV4(
            keccak256(abi.encode(WITHDRAW_TYPEHASH, data.sender, data.token, data.amount, data.nonce))
        );

        // only EOA can withdraw ETH
        bool isValidSignature = data.token == NATIVE_ETH
            ? ECDSA.recover(digest, data.signature) == data.sender
            : UNIVERSAL_SIG_VALIDATOR.isValidSig(data.sender, digest, data.signature);

        if (!isValidSignature) {
            revert Errors.Exchange_InvalidSignature(data.sender);
        }

        address mappedToken = data.token == NATIVE_ETH ? WETH9 : data.token;
        uint128 maxWithdrawalFee = _getMaxWithdrawalFee(mappedToken);
        if (data.withdrawalSequencerFee > maxWithdrawalFee) {
            revert Errors.Exchange_ExceededMaxWithdrawFee(data.withdrawalSequencerFee, maxWithdrawalFee);
        }

        int256 currentBalance = engine.spot.getBalance(mappedToken, data.sender);
        if (currentBalance.safeInt128() < data.amount.safeInt128()) {
            revert Errors.Exchange_AccountInsufficientBalance(data.sender, mappedToken, currentBalance, data.amount);
        }

        engine.clearingService.withdraw(data.sender, data.amount, mappedToken);
        collectedFees[mappedToken] += data.withdrawalSequencerFee;

        uint256 netAmount = data.amount - data.withdrawalSequencerFee;
        if (data.token == NATIVE_ETH) {
            IWETH9(WETH9).withdraw(netAmount);
            Address.sendValue(payable(data.sender), netAmount);
        } else {
            uint256 amountToTransfer = netAmount.convertFromScale(data.token);
            IERC20(data.token).safeTransfer(data.sender, amountToTransfer);
        }
    }

    /// @notice Transfers token between 2 accounts in the exchange, allowing:
    /// - main -> main
    /// - sub -> sub (same main)
    /// - sub -> main
    /// - main -> sub
    function transfer(
        IExchange exchange,
        mapping(address => IExchange.Account) storage accounts,
        BalanceEngine calldata engine,
        address signer,
        IExchange.TransferParams calldata params
    ) external {
        address token = params.token;
        address from = params.from;
        address to = params.to;
        uint256 nonce = params.nonce;
        int256 amount = params.amount.safeInt256();

        IClearingService.VaultShare memory vaultShare = engine.clearingService.getVaultShare(from, token);
        if (vaultShare.shares > 0) {
            revert Errors.Exchange_Transfer_YieldAsset(token);
        }

        bool isValid = _validateTransfer(accounts, from, to);
        if (!isValid) {
            revert Errors.Exchange_Transfer_NotAllowed(from, to);
        }

        int256 fromBalance = engine.spot.getBalance(token, from);
        if (fromBalance < amount) {
            revert Errors.Exchange_Transfer_InsufficientBalance(from, token, fromBalance, amount.safeUInt256());
        }

        bytes32 digest =
            exchange.hashTypedDataV4(keccak256(abi.encode(TRANSFER_TYPEHASH, from, to, token, amount, nonce)));
        if (!UNIVERSAL_SIG_VALIDATOR.isValidSig(signer, digest, params.signature)) {
            revert Errors.Exchange_InvalidSignature(signer);
        }

        engine.clearingService.transfer(from, to, amount, token);
    }

    function transferToBSX1000(
        mapping(address => IExchange.Account) storage accounts,
        IExchange exchange,
        IBSX1000x bsx1000,
        BalanceEngine calldata engine,
        IExchange.TransferToBSX1000Params calldata params
    ) external returns (uint256 newBalance) {
        _assertMainAccount(accounts, params.account);

        bytes32 digest = exchange.hashTypedDataV4(
            keccak256(
                abi.encode(TRANSFER_TO_BSX1000_TYPEHASH, params.account, params.token, params.amount, params.nonce)
            )
        );
        if (!UNIVERSAL_SIG_VALIDATOR.isValidSig(params.account, digest, params.signature)) {
            revert Errors.Exchange_InvalidSignature(params.account);
        }

        IERC20 collateralBSX1000 = bsx1000.collateralToken();
        if (params.token != address(collateralBSX1000)) {
            revert Errors.Exchange_TransferToBSX1000_InvalidToken(params.token, address(collateralBSX1000));
        }
        uint256 amountToTransfer = params.amount.convertFromScale(params.token);
        if (amountToTransfer == 0) {
            revert Errors.Exchange_ZeroAmount();
        }

        int256 currentBalance = engine.spot.getBalance(params.token, params.account);
        if (currentBalance < params.amount.safeInt256()) {
            revert Errors.Exchange_TransferToBSX1000_InsufficientBalance(params.account, currentBalance, params.amount);
        }
        engine.clearingService.withdraw(params.account, params.amount, params.token);

        IERC20(params.token).forceApprove(address(bsx1000), amountToTransfer);
        bsx1000.deposit(params.account, params.amount);

        newBalance = currentBalance.safeUInt256() - params.amount;
    }

    function coverLoss(BalanceEngine calldata engine, address account, address payer, address token)
        external
        returns (uint256 coverAmount)
    {
        int256 loss = engine.spot.getBalance(token, account);
        if (loss >= 0) {
            revert Errors.Exchange_AccountNoLoss(account, token);
        }
        coverAmount = SignedMath.abs(loss);
        int256 payerBalance = engine.spot.getBalance(token, payer);
        if (payerBalance < coverAmount.safeInt256()) {
            revert Errors.Exchange_AccountInsufficientBalance(payer, token, payerBalance, coverAmount);
        }

        engine.clearingService.transfer(payer, account, coverAmount.safeInt256(), token);

        emit IExchange.CoverLoss(account, payer, token, coverAmount);
    }

    /// @dev Asserts that the account is a main account
    function _assertMainAccount(mapping(address => IExchange.Account) storage accounts, address account) private view {
        if (accounts[account].accountType != IExchange.AccountType.Main) {
            revert Errors.Exchange_InvalidAccountType(account);
        }
    }

    /// @dev Returns the maximum withdrawal fee for a token
    function _getMaxWithdrawalFee(address token) internal pure returns (uint128) {
        if (token == WETH9) {
            return 0.001 ether;
        } else {
            return 1e18;
        }
    }

    /// @dev Validates whether the accounts involved in a transfer are valid.
    function _validateTransfer(mapping(address => IExchange.Account) storage accounts, address from, address to)
        private
        view
        returns (bool)
    {
        if (from == to) {
            return false;
        }

        if (
            accounts[from].accountType == IExchange.AccountType.Vault
                || accounts[to].accountType == IExchange.AccountType.Vault
        ) {
            return false;
        }

        if (
            accounts[from].state != IExchange.AccountState.Active || accounts[to].state != IExchange.AccountState.Active
        ) {
            return false;
        }

        // main -> main or sub -> sub
        if (accounts[from].main == accounts[to].main) {
            return true;
        }

        // sub -> main
        if (accounts[from].accountType == IExchange.AccountType.Subaccount) {
            return accounts[from].main == to;
        }

        // main -> sub
        if (accounts[to].accountType == IExchange.AccountType.Subaccount) {
            return accounts[to].main == from;
        }

        return false;
    }
}

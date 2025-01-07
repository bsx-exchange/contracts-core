// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IBSX1000x} from "../1000x/interfaces/IBSX1000x.sol";
import {ExchangeStorage} from "./ExchangeStorage.sol";
import {IExchange, ILiquidation, ISwap} from "./interfaces/IExchange.sol";
import {Errors} from "./lib/Errors.sol";
import {MathHelper} from "./lib/MathHelper.sol";
import {BalanceLogic} from "./lib/logic/BalanceLogic.sol";
import {GenericLogic} from "./lib/logic/GenericLogic.sol";
import {LiquidationLogic} from "./lib/logic/LiquidationLogic.sol";
import {OrderLogic} from "./lib/logic/OrderLogic.sol";
import {SwapLogic} from "./lib/logic/SwapLogic.sol";
import {NATIVE_ETH, UNIVERSAL_SIG_VALIDATOR} from "./share/Constants.sol";

/// @title Exchange contract
/// @notice This contract is entry point of the exchange
/// @dev This contract is upgradeable
contract Exchange is Initializable, EIP712Upgradeable, ExchangeStorage, IExchange {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;
    using MathHelper for uint128;
    using MathHelper for uint256;
    using MathHelper for int256;

    bytes32 public constant REGISTER_TYPEHASH = keccak256("Register(address key,string message,uint64 nonce)");
    bytes32 public constant SIGN_KEY_TYPEHASH = keccak256("SignKey(address account)");

    function _checkRole(bytes32 role, address account) internal view {
        if (!access.hasRole(role, account)) {
            revert IAccessControl.AccessControlUnauthorizedAccount(account, role);
        }
    }

    modifier internalCall() {
        if (msg.sender != address(this)) {
            revert Errors.Exchange_InternalCall();
        }
        _;
    }

    modifier onlyRole(bytes32 role) {
        _checkRole(role, msg.sender);
        _;
    }

    modifier supportedToken(address token) {
        if (!supportedTokens.contains(token)) {
            revert Errors.Exchange_TokenNotSupported(token);
        }
        _;
    }

    modifier enabledDeposit() {
        if (!canDeposit) {
            revert Errors.Exchange_DisabledDeposit();
        }
        _;
    }

    modifier enabledWithdraw() {
        if (!canWithdraw) {
            revert Errors.Exchange_DisabledWithdraw();
        }
        _;
    }

    receive() external payable {}

    /// @inheritdoc IExchange
    function addSupportedToken(address token) external onlyRole(access.GENERAL_ROLE()) {
        bool success = supportedTokens.add(token);
        if (!success) {
            revert Errors.Exchange_TokenAlreadySupported(token);
        }
        emit SupportedTokenAdded(token);
    }

    /// @inheritdoc IExchange
    function removeSupportedToken(address token) external onlyRole(access.GENERAL_ROLE()) {
        bool success = supportedTokens.remove(token);
        if (!success) {
            revert Errors.Exchange_TokenNotSupported(token);
        }
        emit SupportedTokenRemoved(token);
    }

    /// @inheritdoc IExchange
    function depositRaw(address recipient, address token, uint128 rawAmount) external payable supportedToken(token) {
        uint256 amount = token == NATIVE_ETH ? rawAmount : rawAmount.convertToScale(token);
        deposit(recipient, token, amount.safeUInt128());
    }

    /// @inheritdoc IExchange
    function deposit(address token, uint128 amount) external payable {
        deposit(msg.sender, token, amount);
    }

    /// @inheritdoc IExchange
    function deposit(address recipient, address token, uint128 amount)
        public
        payable
        enabledDeposit
        supportedToken(token)
    {
        BalanceLogic.deposit(BalanceLogic.BalanceEngine(clearingService, spotEngine), recipient, token, amount);
    }

    /// @inheritdoc IExchange
    function depositWithAuthorization(
        address token,
        address depositor,
        uint128 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external enabledDeposit supportedToken(token) {
        BalanceLogic.depositWithAuthorization(
            BalanceLogic.BalanceEngine(clearingService, spotEngine),
            depositor,
            token,
            amount,
            validAfter,
            validBefore,
            nonce,
            signature
        );
    }

    /// @inheritdoc IExchange
    function depositInsuranceFund(uint256 amount) external onlyRole(access.GENERAL_ROLE()) {
        address token = book.getCollateralToken();
        (uint256 roundDownAmount, uint256 amountToTransfer) = amount.roundDownAndConvertFromScale(token);
        if (roundDownAmount == 0 || amountToTransfer == 0) revert Errors.Exchange_ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amountToTransfer);
        clearingService.depositInsuranceFund(roundDownAmount);

        uint256 insuranceFundBalance = clearingService.getInsuranceFundBalance();
        emit DepositInsuranceFund(roundDownAmount, insuranceFundBalance);
    }

    /// @inheritdoc IExchange
    function withdrawInsuranceFund(uint256 amount) external onlyRole(access.GENERAL_ROLE()) {
        address token = book.getCollateralToken();
        uint256 amountToTransfer = amount.convertFromScale(token);
        if (amount == 0 || amountToTransfer == 0) revert Errors.Exchange_ZeroAmount();

        IERC20(token).safeTransfer(msg.sender, amountToTransfer);
        clearingService.withdrawInsuranceFundEmergency(amount);

        uint256 insuranceFundBalance = clearingService.getInsuranceFundBalance();
        emit WithdrawInsuranceFund(amount, insuranceFundBalance);
    }

    /// @inheritdoc IExchange
    function claimTradingFees() external onlyRole(access.GENERAL_ROLE()) {
        address token = book.getCollateralToken();
        uint256 totalFee = book.claimTradingFees().safeUInt256();
        uint256 amountToTransfer = totalFee.convertFromScale(token);
        IERC20(token).safeTransfer(feeRecipientAddress, amountToTransfer);
        emit ClaimTradingFees(msg.sender, totalFee);
    }

    /// @inheritdoc IExchange
    function claimSequencerFees() external onlyRole(access.GENERAL_ROLE()) {
        address underlyingAsset = book.getCollateralToken();

        for (uint256 i = 0; i < supportedTokens.length(); ++i) {
            address token = supportedTokens.at(i);
            if (token == NATIVE_ETH) {
                continue;
            }

            uint256 totalFee = _collectedFee[token];
            if (token == underlyingAsset) {
                totalFee += book.claimSequencerFees().safeUInt256();
            }
            _collectedFee[token] = 0;

            uint256 amountToTransfer = totalFee.convertFromScale(token);
            IERC20(token).safeTransfer(feeRecipientAddress, amountToTransfer);
            emit ClaimSequencerFees(msg.sender, token, totalFee);
        }
    }

    /// @inheritdoc IExchange
    function processBatch(bytes[] calldata operations) external onlyRole(access.BATCH_OPERATOR_ROLE()) {
        if (pauseBatchProcess) {
            revert Errors.Exchange_PausedProcessBatch();
        }

        uint256 length = operations.length;
        for (uint128 i = 0; i < length; ++i) {
            bytes calldata operation = operations[i];
            _handleOperation(operation);
        }
    }

    /// @inheritdoc ILiquidation
    function liquidateCollateralBatch(LiquidationParams[] calldata params)
        external
        onlyRole(access.COLLATERAL_OPERATOR_ROLE())
    {
        LiquidationLogic.liquidateCollateralBatch(isLiquidationNonceUsed, this, params);
    }

    /// @inheritdoc ILiquidation
    function innerLiquidation(LiquidationParams calldata params)
        external
        internalCall
        returns (AccountLiquidationStatus status)
    {
        return LiquidationLogic.executeLiquidation(
            supportedTokens,
            LiquidationLogic.LiquidationEngines({
                orderbook: book,
                clearingService: clearingService,
                spotEngine: spotEngine,
                universalRouter: universalRouter
            }),
            params
        );
    }

    /// @inheritdoc ISwap
    function swapCollateralBatch(SwapParams[] calldata params) external onlyRole(access.COLLATERAL_OPERATOR_ROLE()) {
        SwapLogic.swapCollateralBatch(this, params);
    }

    /// @inheritdoc ISwap
    function innerSwapWithPermit(SwapParams calldata params) external internalCall returns (uint256 amountOutX18) {
        return SwapLogic.executeSwap(
            isSwapNonceUsed,
            _collectedFee,
            this,
            SwapLogic.SwapEngines({
                clearingService: clearingService,
                spotEngine: spotEngine,
                universalRouter: universalRouter
            }),
            params
        );
    }

    /// @inheritdoc IExchange
    function updateFeeRecipientAddress(address _feeRecipientAddress) external onlyRole(access.GENERAL_ROLE()) {
        if (_feeRecipientAddress == address(0)) {
            revert Errors.ZeroAddress();
        }
        feeRecipientAddress = _feeRecipientAddress;
    }

    function registerSigningWallet(
        address account,
        address signer,
        string memory message,
        uint64 nonce,
        bytes memory walletSignature,
        bytes memory signerSignature
    ) external {
        _addSigningWallet(account, signer, message, nonce, walletSignature, signerSignature);
    }

    /// @inheritdoc IExchange
    function unregisterSigningWallet(address account, address signer)
        external
        onlyRole(access.SIGNER_OPERATOR_ROLE())
    {
        _signingWallets[account][signer] = false;
    }

    /// @inheritdoc IExchange
    function setPauseBatchProcess(bool _pauseBatchProcess) external onlyRole(access.GENERAL_ROLE()) {
        pauseBatchProcess = _pauseBatchProcess;
    }

    /// @inheritdoc IExchange
    function setCanDeposit(bool _canDeposit) external onlyRole(access.GENERAL_ROLE()) {
        canDeposit = _canDeposit;
    }

    /// @inheritdoc IExchange
    function setCanWithdraw(bool _canWithdraw) external onlyRole(access.GENERAL_ROLE()) {
        canWithdraw = _canWithdraw;
    }

    /// @inheritdoc IExchange
    function getInsuranceFundBalance() external view returns (uint256) {
        return clearingService.getInsuranceFundBalance();
    }

    /// @inheritdoc IExchange
    function getTradingFees() external view returns (int128) {
        return book.getTradingFees();
    }

    /// @inheritdoc IExchange
    function getSequencerFees(address token) external view returns (uint256) {
        address underlyingAsset = book.getCollateralToken();
        uint256 fees = _collectedFee[token];
        if (token == underlyingAsset) {
            fees += book.getSequencerFees().safeUInt256();
        }

        return fees;
    }

    /// @inheritdoc IExchange
    function hashTypedDataV4(bytes32 structHash) external view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }

    /// @inheritdoc IExchange
    function balanceOf(address user, address token) public view returns (int256) {
        int256 balance = spotEngine.getBalance(token, user);
        return balance;
    }

    /// @inheritdoc IExchange
    function getSupportedTokenList() public view returns (address[] memory tokenList) {
        uint256 length = supportedTokens.length();
        tokenList = new address[](length);
        for (uint256 index = 0; index < length; index++) {
            tokenList[index] = supportedTokens.at(index);
        }
    }

    /// @inheritdoc IExchange
    function isSigningWallet(address sender, address signer) public view returns (bool) {
        return _signingWallets[sender][signer];
    }

    /// @inheritdoc IExchange
    function isSupportedToken(address token) external view returns (bool) {
        return supportedTokens.contains(token);
    }

    /// @dev Handles a operation. Will revert if operation type is invalid.
    /// @param data Transaction data to handle
    /// The first byte is operation type
    /// The next 4 bytes is transaction ID
    /// The rest is transaction data
    // solhint-disable code-complexity
    function _handleOperation(bytes calldata data) internal {
        //     1 byte is operation type
        //next 4 bytes is transaction ID
        OperationType operationType = OperationType(uint8(data[0]));
        uint32 transactionId = uint32(bytes4(data[1:5]));
        if (transactionId != executedTransactionCounter) {
            revert Errors.Exchange_InvalidTransactionId(transactionId, executedTransactionCounter);
        }
        executedTransactionCounter++;
        if (operationType == OperationType.MatchOrders) {
            _matchOrders(data);
        } else if (operationType == OperationType.MatchLiquidationOrders) {
            _matchLiquidationOrders(data);
        } else if (operationType == OperationType.UpdateFundingRate) {
            (uint8 productIndex, int128 priceDiff, uint128 lastFundingRateUpdateSequenceNumber) =
                abi.decode(data[5:], (uint8, int128, uint128));
            if (lastFundingRateUpdate >= lastFundingRateUpdateSequenceNumber) {
                revert Errors.Exchange_InvalidFundingRateSequenceNumber(
                    lastFundingRateUpdateSequenceNumber, lastFundingRateUpdate
                );
            }
            int256 cumulativeFunding = perpEngine.updateFundingRate(productIndex, priceDiff);
            lastFundingRateUpdate = lastFundingRateUpdateSequenceNumber;
            emit UpdateFundingRate(productIndex, priceDiff, cumulativeFunding);
        } else if (operationType == OperationType.CoverLossByInsuranceFund) {
            (address account, uint256 amount) = abi.decode(data[5:], (address, uint256));
            clearingService.coverLossWithInsuranceFund(account, amount);
        } else if (operationType == OperationType.AddSigningWallet) {
            AddSigningWallet memory txs = abi.decode(data[5:], (AddSigningWallet));
            _addSigningWallet(txs.sender, txs.signer, txs.message, txs.nonce, txs.walletSignature, txs.signerSignature);
        } else if (operationType == OperationType.TransferToBSX1000) {
            TransferToBSX1000Params memory transferData = abi.decode(data[5:], (TransferToBSX1000Params));
            _transferToBSX1000(transferData);
        } else if (operationType == OperationType.Withdraw) {
            Withdraw memory withdrawData = abi.decode(data[5:], (Withdraw));
            _withdraw(withdrawData);
        } else {
            revert Errors.Exchange_InvalidOperationType();
        }
    }

    /// @dev Handles matching normal orders
    function _matchOrders(bytes calldata data) internal {
        OrderLogic.matchOrders(this, OrderLogic.OrderEngine(book, spotEngine), data);
    }

    /// @dev Handles matching liquidation orders
    function _matchLiquidationOrders(bytes calldata data) internal {
        OrderLogic.matchLiquidationOrders(this, OrderLogic.OrderEngine(book, spotEngine), data);
    }

    /// @dev Handles a withdraw
    function _withdraw(Withdraw memory data) internal enabledWithdraw {
        BalanceLogic.withdraw(
            isWithdrawNonceUsed, _collectedFee, this, BalanceLogic.BalanceEngine(clearingService, spotEngine), data
        );
    }

    function _transferToBSX1000(TransferToBSX1000Params memory data) internal {
        if (isTransferToBSX1000NonceUsed[data.account][data.nonce]) {
            revert Errors.Exchange_TransferToBSX1000_NonceUsed(data.account, data.nonce);
        }
        isTransferToBSX1000NonceUsed[data.account][data.nonce] = true;

        try this.innerTransferToBSX1000(data) returns (uint256 balance) {
            emit TransferToBSX1000(
                data.token, data.account, data.nonce, data.amount, balance, TransferToBSX1000Status.Success
            );
        } catch {
            emit TransferToBSX1000(
                data.token, data.account, data.nonce, data.amount, 0, TransferToBSX1000Status.Failure
            );
        }
    }

    function innerTransferToBSX1000(TransferToBSX1000Params memory params)
        external
        internalCall
        returns (uint256 balance)
    {
        return BalanceLogic.transferToBSX1000(
            this, IBSX1000x(access.getBsx1000()), BalanceLogic.BalanceEngine(clearingService, spotEngine), params
        );
    }

    /// @dev Validates and authorizes a signer to sign on behalf of a sender.
    /// Supports adding a signing wallet for both EOA and smart contract.
    /// Smart contract signature validation follows ERC1271 standards.
    /// @param sender Sender address
    /// @param signer Signer address
    /// @param authorizedMsg Message is signed by the sender
    /// @param nonce Unique nonce for each signing wallet, check by `usedNonces`
    /// @param senderSignature Signature of the sender, can be EOA or contract wallet
    /// @param signerSignature Signature of the signer, must be EOA
    function _addSigningWallet(
        address sender,
        address signer,
        string memory authorizedMsg,
        uint64 nonce,
        bytes memory senderSignature,
        bytes memory signerSignature
    ) internal {
        if (isRegisterSignerNonceUsed[sender][nonce]) {
            revert Errors.Exchange_AddSigningWallet_UsedNonce(sender, nonce);
        }

        // verify signature of sender
        bytes32 registerHash = _hashTypedDataV4(
            keccak256(abi.encode(REGISTER_TYPEHASH, signer, keccak256(abi.encodePacked(authorizedMsg)), nonce))
        );
        if (!UNIVERSAL_SIG_VALIDATOR.isValidSig(sender, registerHash, senderSignature)) {
            revert Errors.Exchange_InvalidSignature(sender);
        }

        // verify signature of authorized signer
        bytes32 signKeyHash = _hashTypedDataV4(keccak256(abi.encode(SIGN_KEY_TYPEHASH, sender)));
        GenericLogic.verifySignature(signer, signKeyHash, signerSignature);

        _signingWallets[sender][signer] = true;
        isRegisterSignerNonceUsed[sender][nonce] = true;

        emit RegisterSigner(sender, signer, nonce);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {Access} from "./access/Access.sol";
import {IClearingService} from "./interfaces/IClearingService.sol";
import {IExchange} from "./interfaces/IExchange.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {IPerp} from "./interfaces/IPerp.sol";
import {ISpot} from "./interfaces/ISpot.sol";
import {IERC20Extend} from "./interfaces/external/IERC20Extend.sol";
import {IERC3009Minimal} from "./interfaces/external/IERC3009Minimal.sol";
import {LibOrder} from "./lib/LibOrder.sol";
import {MAX_WITHDRAWAL_FEE, MIN_WITHDRAW_AMOUNT, NAME, VERSION} from "./share/Constants.sol";
import {OrderSide} from "./share/Enums.sol";
import {
    ADD_TOKEN_FAILED,
    INVALID_ADDRESS,
    INVALID_AMOUNT,
    INVALID_FUNDING_RATE_UPDATE,
    INVALID_OPERATION_TYPE,
    INVALID_PRODUCT_ID,
    INVALID_SEQUENCER_FEES,
    INVALID_SIGNATURE,
    INVALID_SIGNING_NONCE,
    INVALID_TRANSACTION_ID,
    INVALID_WITHDRAW_NONCE,
    NOT_ADMIN_GENERAL,
    NOT_ENABLED,
    NOT_LIQUIDATION_ORDER,
    NOT_SIGNING_WALLET,
    PAUSE_BATCH_PROCESS,
    REMOVE_TOKEN_FAILED,
    TOKEN_NOT_SUPPORTED
} from "./share/RevertReason.sol";

/// @title Exchange contract
/// @notice This contract is entry point of the exchange
/// @dev This contract is upgradeable
contract Exchange is Initializable, EIP712Upgradeable, IExchange {
    using EnumerableSet for EnumerableSet.AddressSet;
    using LibOrder for LibOrder.Order;
    using SafeERC20 for IERC20Extend;

    IClearingService public clearingService;
    ISpot public spotEngine;
    IPerp public perpEngine;
    IOrderBook public book;
    Access public accessContract;

    EnumerableSet.AddressSet private supportedTokens;
    mapping(address account => mapping(address signer => bool isAuthorized)) private _signingWallets;
    mapping(uint256 requestId => WithdrawalInfo info) private _withdrawalInfo; // deprecated
    mapping(address account => mapping(uint64 signingWalletsNonce => bool used)) public usedNonces;

    uint256 private _withdrawalRequestIDCounter; // deprecated
    uint256 private _forceWithdrawalGracePeriodSecond; // deprecated
    uint256 private _lastResetBlockNumber; // deprecated
    int256 private _sequencerFee;
    EnumerableSet.AddressSet private _userWallets; // deprecated
    uint256 public lastFundingRateUpdate;
    uint32 public executedTransactionCounter;
    address public feeRecipientAddress;
    bool private _isTwoPhaseWithdrawEnabled; // deprecated
    bool public canDeposit;
    bool public canWithdraw;
    bool public pauseBatchProcess;
    mapping(address account => mapping(uint64 nonce => bool isSuccess)) public isWithdrawSuccess;
    mapping(address account => bool isRequesting) private _isRequestingTwoPhaseWithdraw; // deprecated

    bytes32 public constant SIGNING_WALLET_SIGNATURE = keccak256("Register(address key,string message,uint64 nonce)");
    bytes32 public constant SIGNING_KEY_SIGNATURE = keccak256("SignKey(address account)");
    bytes32 public constant WITHDRAW_SIGNATURE =
        keccak256("Withdraw(address sender,address token,uint128 amount,uint64 nonce)");
    bytes32 public constant ORDER_SIGNATURE =
        keccak256("Order(address sender,uint128 size,uint128 price,uint64 nonce,uint8 productIndex,uint8 orderSide)");

    function initialize(
        address _access,
        address _clearingService,
        address _spotEngine,
        address _perpEngine,
        address _book,
        address _feeRecipientAddress
    ) external initializer {
        __EIP712_init(NAME, VERSION);
        if (
            _access == address(0) || _clearingService == address(0) || _spotEngine == address(0)
                || _perpEngine == address(0) || _book == address(0)
        ) {
            revert(INVALID_ADDRESS);
        }

        accessContract = Access(_access);
        clearingService = IClearingService(_clearingService);
        spotEngine = ISpot(_spotEngine);
        perpEngine = IPerp(_perpEngine);
        book = IOrderBook(_book);

        executedTransactionCounter = 0;
        feeRecipientAddress = _feeRecipientAddress;
        canDeposit = true;
        canWithdraw = true;
        pauseBatchProcess = false;
    }

    function _onlyGeneralAdmin() internal view {
        if (!accessContract.hasRole(accessContract.ADMIN_GENERAL_ROLE(), msg.sender)) {
            revert(NOT_ADMIN_GENERAL);
        }
    }

    modifier onlyGeneralAdmin() {
        _onlyGeneralAdmin();
        _;
    }

    modifier supportedToken(address token) {
        if (!supportedTokens.contains(token)) {
            revert(TOKEN_NOT_SUPPORTED);
        }
        _;
    }

    ///@inheritdoc IExchange
    function addSupportedToken(address token) external onlyGeneralAdmin {
        bool success = supportedTokens.add(token);
        if (!success) {
            revert(ADD_TOKEN_FAILED);
        }
        emit SupportedTokenAdded(token);
    }

    ///@inheritdoc IExchange
    function removeSupportedToken(address token) external onlyGeneralAdmin {
        bool success = supportedTokens.remove(token);
        if (!success) {
            revert(REMOVE_TOKEN_FAILED);
        }
        emit SupportedTokenRemoved(token);
    }

    ///@inheritdoc IExchange
    function deposit(address tokenAddress, uint128 amount) external supportedToken(tokenAddress) {
        if (!canDeposit) {
            revert(NOT_ENABLED);
        }
        if (amount == 0) revert(INVALID_AMOUNT);
        IERC20Extend token = IERC20Extend(tokenAddress);
        uint256 amountToTransfer = _convertToRawAmount(tokenAddress, amount);
        token.safeTransferFrom(msg.sender, address(this), amountToTransfer);
        clearingService.deposit(msg.sender, amount, tokenAddress, spotEngine);
        int256 currentBalance = spotEngine.getBalance(tokenAddress, msg.sender);
        emit Deposit(tokenAddress, msg.sender, amount, uint256(currentBalance));
    }

    ///@inheritdoc IExchange
    function depositRaw(
        address recipient,
        address tokenAddress,
        uint128 rawAmount
    ) external supportedToken(tokenAddress) {
        if (!canDeposit) {
            revert(NOT_ENABLED);
        }
        if (rawAmount == 0) revert(INVALID_AMOUNT);
        IERC20Extend token = IERC20Extend(tokenAddress);
        token.safeTransferFrom(msg.sender, address(this), rawAmount);

        uint256 scaledAmount = (rawAmount * 10 ** 18) / 10 ** token.decimals();
        clearingService.deposit(recipient, scaledAmount, tokenAddress, spotEngine);
        int256 currentBalance = spotEngine.getBalance(tokenAddress, recipient);
        emit Deposit(tokenAddress, recipient, scaledAmount, uint256(currentBalance));
    }

    //// @inheritdoc IExchange
    function depositWithAuthorization(
        address tokenAddress,
        address depositor,
        uint128 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external onlyGeneralAdmin supportedToken(tokenAddress) {
        if (!canDeposit) {
            revert(NOT_ENABLED);
        }

        if (amount == 0) revert(INVALID_AMOUNT);
        uint256 amountToTransfer = _convertToRawAmount(tokenAddress, amount);
        IERC3009Minimal(tokenAddress).receiveWithAuthorization(
            depositor, address(this), amountToTransfer, validAfter, validBefore, nonce, signature
        );
        clearingService.deposit(depositor, amount, tokenAddress, spotEngine);
        int256 currentBalance = spotEngine.getBalance(tokenAddress, depositor);
        emit Deposit(tokenAddress, depositor, amount, uint256(currentBalance));
    }

    /// @inheritdoc IExchange
    function depositInsuranceFund(address token, uint256 amount) external onlyGeneralAdmin {
        if (token != book.getCollateralToken()) {
            revert(TOKEN_NOT_SUPPORTED);
        }
        IERC20Extend product = IERC20Extend(token);
        uint256 amountToTransfer = _convertToRawAmount(token, uint128(amount));
        product.safeTransferFrom(msg.sender, address(this), amountToTransfer);
        clearingService.depositInsuranceFund(amount);
        emit DepositInsurance(token, amount);
    }

    /// @inheritdoc IExchange
    function withdrawInsuranceFund(address token, uint256 amount) external onlyGeneralAdmin {
        if (token != book.getCollateralToken()) {
            revert(TOKEN_NOT_SUPPORTED);
        }
        IERC20Extend product = IERC20Extend(token);
        uint256 amountToTransfer = _convertToRawAmount(token, uint128(amount));
        product.safeTransfer(msg.sender, amountToTransfer);
        clearingService.withdrawInsuranceFundEmergency(amount);
        emit WithdrawInsurance(token, amount);
    }

    /// @inheritdoc IExchange
    function claimTradingFees() external onlyGeneralAdmin {
        address token = book.getCollateralToken();
        int256 totalFee = book.claimTradingFees();
        IERC20Extend tokenExtend = IERC20Extend(token);
        uint256 amountToTransfer = _convertToRawAmount(token, uint128(uint256(totalFee)));
        tokenExtend.safeTransfer(feeRecipientAddress, uint256(amountToTransfer));
        emit ClaimTradingFees(msg.sender, uint256(totalFee));
    }

    /// @inheritdoc IExchange
    function claimSequencerFees() external onlyGeneralAdmin {
        address token = book.getCollateralToken();
        int256 totalFee = _sequencerFee;
        _sequencerFee = 0;
        totalFee += book.claimSequencerFees();
        IERC20Extend tokenExtend = IERC20Extend(token);
        uint256 amountToTransfer = _convertToRawAmount(token, uint128(uint256(totalFee)));
        tokenExtend.safeTransfer(feeRecipientAddress, uint256(amountToTransfer));
        emit ClaimSequencerFees(msg.sender, uint256(totalFee));
    }

    ///@inheritdoc IExchange
    function processBatch(bytes[] calldata operations) external onlyGeneralAdmin {
        if (pauseBatchProcess) {
            revert(PAUSE_BATCH_PROCESS);
        }

        uint256 length = operations.length;
        for (uint128 i = 0; i < length; ++i) {
            bytes calldata operation = operations[i];
            _handleOperation(operation);
        }
    }

    ///@inheritdoc IExchange
    function updateFeeRecipientAddress(address _feeRecipientAddress) external onlyGeneralAdmin {
        if (_feeRecipientAddress == address(0)) {
            revert(INVALID_ADDRESS);
        }
        feeRecipientAddress = _feeRecipientAddress;
    }

    /// @inheritdoc IExchange
    function unregisterSigningWallet(address account, address signer) external onlyGeneralAdmin {
        _signingWallets[account][signer] = false;
    }

    /// @inheritdoc IExchange
    function setPauseBatchProcess(bool _pauseBatchProcess) external onlyGeneralAdmin {
        pauseBatchProcess = _pauseBatchProcess;
    }

    /// @inheritdoc IExchange
    function setCanDeposit(bool _canDeposit) external onlyGeneralAdmin {
        canDeposit = _canDeposit;
    }

    /// @inheritdoc IExchange
    function setCanWithdraw(bool _canWithdraw) external onlyGeneralAdmin {
        canWithdraw = _canWithdraw;
    }

    /// @inheritdoc IExchange
    function getBalanceInsuranceFund() external view returns (uint256) {
        return clearingService.getInsuranceFund();
    }

    /// @inheritdoc IExchange
    function getTradingFees() external view returns (int128) {
        return book.getTradingFees();
    }

    /// @inheritdoc IExchange
    function getSequencerFees() external view returns (int256) {
        return _sequencerFee + book.getSequencerFees();
    }

    /// @inheritdoc IExchange
    function balanceOf(address user, address token) public view returns (int256) {
        int256 balance = spotEngine.getBalance(token, user);
        return balance;
    }

    /// @inheritdoc IExchange
    function getSupportedTokenList() public view returns (address[] memory) {
        uint8 length = uint8(supportedTokens.length());
        address[] memory tokenList = new address[](length);
        for (uint256 index = 0; index < length; index++) {
            tokenList[index] = supportedTokens.at(index);
        }
        return tokenList;
    }

    /// @inheritdoc IExchange
    function isSigningWallet(address sender, address signer) public view returns (bool) {
        return _signingWallets[sender][signer];
    }

    /// @inheritdoc IExchange
    function isSupportedToken(address token) external view returns (bool) {
        return supportedTokens.contains(token);
    }

    // solhint-disable code-complexity
    /// @dev Handles a operation. Will revert if operation type is invalid.
    function _handleOperation(bytes calldata data) internal {
        //     1 byte is operation type
        //next 4 bytes is transaction ID
        OperationType operationType = OperationType(uint8(data[0]));
        uint32 transactionId = uint32(bytes4(abi.encodePacked(data[1:5])));
        if (transactionId != executedTransactionCounter) {
            revert(INVALID_TRANSACTION_ID);
        }
        executedTransactionCounter++;
        if (operationType == OperationType.MatchLiquidationOrders) {
            LibOrder.SignedOrder memory maker;
            LibOrder.SignedOrder memory taker;
            IOrderBook.Fee memory matchFee;
            IOrderBook.OrderHash memory digest;

            // 165 bytes for an order
            (maker.order, maker.signature, maker.signer, maker.isLiquidation, matchFee.maker) =
                _parseDataToOrder(data[5:169]);
            digest.maker = _getOrderDigest(maker.order);

            // 165 bytes for an order
            (taker.order, taker.signature, taker.signer, taker.isLiquidation, matchFee.taker) =
                _parseDataToOrder(data[169:333]);
            uint128 takerSequencerFee = uint128(bytes16(data[333:349])); //16 bytes for takerSequencerFee
            digest.taker = _getOrderDigest(taker.order);

            if (!taker.isLiquidation) {
                revert(NOT_LIQUIDATION_ORDER);
            }
            _verifySignature(maker.signer, digest.maker, maker.signature);
            if (!isSigningWallet(maker.order.sender, maker.signer)) {
                revert(NOT_SIGNING_WALLET);
            }

            if (maker.order.productIndex != taker.order.productIndex) {
                revert(INVALID_PRODUCT_ID);
            }

            book.matchOrders(maker, taker, digest, maker.order.productIndex, takerSequencerFee, matchFee);
        } else if (operationType == OperationType.MatchOrders) {
            LibOrder.SignedOrder memory maker;
            LibOrder.SignedOrder memory taker;
            IOrderBook.Fee memory matchFee;
            IOrderBook.OrderHash memory digest;

            // 165 bytes for an order
            (maker.order, maker.signature, maker.signer, maker.isLiquidation, matchFee.maker) =
                _parseDataToOrder(data[5:169]);
            digest.maker = _getOrderDigest(maker.order);
            _verifySignature(maker.signer, digest.maker, maker.signature);
            if (!isSigningWallet(maker.order.sender, maker.signer)) {
                revert(NOT_SIGNING_WALLET);
            }
            // 165 bytes for an order
            (taker.order, taker.signature, taker.signer, taker.isLiquidation, matchFee.taker) =
                _parseDataToOrder(data[169:333]);
            uint128 takerSequencerFee = uint128(bytes16(data[333:349])); //16 bytes for takerSequencerFee
            digest.taker = _getOrderDigest(taker.order);
            _verifySignature(taker.signer, digest.taker, taker.signature);
            if (!isSigningWallet(taker.order.sender, taker.signer)) {
                revert(NOT_SIGNING_WALLET);
            }

            if (maker.order.productIndex != taker.order.productIndex) {
                revert(INVALID_PRODUCT_ID);
            }

            book.matchOrders(maker, taker, digest, maker.order.productIndex, takerSequencerFee, matchFee);
        } else if (operationType == OperationType.UpdateFundingRate) {
            UpdateFundingRate memory txs = abi.decode(data[5:], (UpdateFundingRate));
            if (lastFundingRateUpdate >= txs.lastFundingRateUpdateSequenceNumber) {
                revert(INVALID_FUNDING_RATE_UPDATE);
            }
            int256 cumulativeFunding = perpEngine.updateFundingRate(txs.productIndex, txs.priceDiff);
            lastFundingRateUpdate = txs.lastFundingRateUpdateSequenceNumber;
            emit FundingRate(txs.productIndex, txs.priceDiff, cumulativeFunding, transactionId);
        } else if (operationType == OperationType.CoverLossByInsuranceFund) {
            CoverLossByInsuranceFund memory txs = abi.decode(data[5:], (CoverLossByInsuranceFund));
            clearingService.insuranceCoverLost(txs.account, txs.amount, spotEngine, txs.token);
        } else if (operationType == OperationType.AddSigningWallet) {
            AddSigningWallet memory txs = abi.decode(data[5:], (AddSigningWallet));
            _addSigningWallet(txs.sender, txs.signer, txs.message, txs.nonce, txs.walletSignature, txs.signerSignature);
            emit SigningWallet(txs.sender, txs.signer, transactionId);
        } else if (operationType == OperationType.Withdraw) {
            Withdraw memory txs = abi.decode(data[5:], (Withdraw));
            if (!canWithdraw) {
                revert(NOT_ENABLED);
            }
            if (txs.withdrawalSequencerFee > MAX_WITHDRAWAL_FEE) {
                revert(INVALID_SEQUENCER_FEES);
            }
            bytes32 digest = _hashTypedDataV4(
                keccak256(abi.encode(WITHDRAW_SIGNATURE, txs.sender, txs.token, txs.amount, txs.nonce))
            );
            _verifySignature(txs.sender, digest, txs.signature);
            _verifyWithdrawNonce(txs.sender, txs.nonce);
            int256 currentBalance = balanceOf(txs.sender, txs.token);
            if (txs.amount < MIN_WITHDRAW_AMOUNT || currentBalance < int256(int128(txs.amount))) {
                isWithdrawSuccess[txs.sender][txs.nonce] = false;
                emit WithdrawRejected(txs.sender, txs.nonce, txs.amount, currentBalance);
            } else {
                clearingService.withdraw(txs.sender, txs.amount, txs.token, spotEngine);
                IERC20Extend product = IERC20Extend(txs.token);
                uint256 amountToTransfer = _convertToRawAmount(txs.token, txs.amount - txs.withdrawalSequencerFee);
                _sequencerFee += int256(int128(txs.withdrawalSequencerFee));
                product.safeTransfer(txs.sender, amountToTransfer);
                int256 afterBalance = balanceOf(txs.sender, txs.token);
                isWithdrawSuccess[txs.sender][txs.nonce] = true;
                emit WithdrawInfo(
                    txs.token, txs.sender, txs.amount, uint256(afterBalance), txs.nonce, txs.withdrawalSequencerFee
                );
            }
        } else {
            revert(INVALID_OPERATION_TYPE);
        }
    }

    /// @dev Parse encoded data to order
    function _parseDataToOrder(bytes calldata data)
        internal
        pure
        returns (LibOrder.Order memory, bytes memory signature, address signer, bool isLiquidation, int128 matchFee)
    {
        //Fisrt 20 bytes is sender
        //next  16 bytes is size
        //next  16 bytes is price
        //next  8 bytes is nonce
        //next  1 byte is product index
        //next  1 byte is order side
        //next  65 bytes is signature
        //next  20 bytes is signer
        //next  1 byte is isLiquidation
        //next  16 bytes is match fee
        //sum 164
        LibOrder.Order memory order;
        order.sender = address(bytes20(data[0:20]));
        order.size = uint128(bytes16(data[20:36]));
        order.price = uint128(bytes16(data[36:52]));
        order.nonce = uint64(bytes8(data[52:60]));
        order.productIndex = uint8(data[60]);
        order.orderSide = OrderSide(uint8(data[61]));
        signature = data[62:127];
        signer = address(bytes20(data[127:147]));
        isLiquidation = uint8(data[147]) == 1;
        matchFee = int128(uint128(bytes16(data[148:164])));

        return (order, signature, signer, isLiquidation, matchFee);
    }

    /// @dev Hash an order using EIP712
    function _getOrderDigest(LibOrder.Order memory order) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ORDER_SIGNATURE,
                    order.sender,
                    order.size,
                    order.price,
                    order.nonce,
                    order.productIndex,
                    order.orderSide
                )
            )
        );
    }

    /// @dev Convert a standard amount (18 decimals) to a normal amount (token decimals)
    function _convertToRawAmount(address token, uint128 amount) internal view returns (uint128) {
        IERC20Extend product = IERC20Extend(token);
        uint256 rawAmount = (amount * 10 ** product.decimals()) / 1e18;
        return uint128(rawAmount);
    }

    /// @dev Validate and authorize a signer to sign on behalf of a sender
    /// @param sender Sender address
    /// @param signer Signer address
    /// @param message Message to sign
    /// @param nonce Unique nonce for each signing wallet, check by `usedNonces`
    /// @param walletSignature Signature of the sender
    /// @param signerSignature Signature of the signer
    function _addSigningWallet(
        address sender,
        address signer,
        string memory message,
        uint64 nonce,
        bytes memory walletSignature,
        bytes memory signerSignature
    ) internal {
        bytes32 digestSigningWallet = _hashTypedDataV4(
            keccak256(abi.encode(SIGNING_WALLET_SIGNATURE, signer, keccak256(abi.encodePacked(message)), nonce))
        );
        bytes32 digestSigningKey = _hashTypedDataV4(keccak256(abi.encode(SIGNING_KEY_SIGNATURE, sender)));
        _verifySigningNonce(sender, nonce); //verify nonce
        _verifySignature(sender, digestSigningWallet, walletSignature); //verify register signature
        _verifySignature(signer, digestSigningKey, signerSignature); //verify signing key signature
        _signingWallets[sender][signer] = true;
        usedNonces[sender][nonce] = true;
    }

    /// @dev Validates a signature
    function _verifySignature(address signer, bytes32 digest, bytes memory signature) internal pure {
        if (ECDSA.recover(digest, signature) != signer) {
            revert(INVALID_SIGNATURE);
        }
    }

    /// @dev Checks if a nonce is used for adding a signing wallet, revert if nonce is used
    function _verifySigningNonce(address sender, uint64 nonce) internal view {
        if (usedNonces[sender][nonce]) {
            revert(INVALID_SIGNING_NONCE);
        }
    }

    /// @dev Checks if a nonce is used for withdraw, revert if nonce is used
    function _verifyWithdrawNonce(address sender, uint64 nonce) internal view {
        if (isWithdrawSuccess[sender][nonce]) {
            revert(INVALID_WITHDRAW_NONCE);
        }
    }
}

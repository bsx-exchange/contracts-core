// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {Perp} from "./Perp.sol";
import {Spot} from "./Spot.sol";
import {Access} from "./access/Access.sol";
import {IClearingService} from "./interfaces/IClearingService.sol";
import {IExchange} from "./interfaces/IExchange.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {IPerp} from "./interfaces/IPerp.sol";
import {ISpot} from "./interfaces/ISpot.sol";
import {IERC20Extend} from "./interfaces/external/IERC20Extend.sol";
import {IERC3009Minimal} from "./interfaces/external/IERC3009Minimal.sol";
import {Errors} from "./lib/Errors.sol";
import {LibOrder} from "./lib/LibOrder.sol";
import {Percentage} from "./lib/Percentage.sol";
import {MAX_REBATE_RATE, MAX_WITHDRAWAL_FEE, MIN_WITHDRAW_AMOUNT, NAME, VERSION} from "./share/Constants.sol";
import {OrderSide} from "./share/Enums.sol";

/// @title Exchange contract
/// @notice This contract is entry point of the exchange
/// @dev This contract is upgradeable
// solhint-disable max-states-count
contract Exchange is IExchange, Initializable, EIP712Upgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using LibOrder for LibOrder.Order;
    using SafeERC20 for IERC20Extend;
    using Percentage for uint128;

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

    bytes32 public constant REGISTER_TYPEHASH = keccak256("Register(address key,string message,uint64 nonce)");
    bytes32 public constant SIGN_KEY_TYPEHASH = keccak256("SignKey(address account)");
    bytes32 public constant WITHDRAW_TYPEHASH =
        keccak256("Withdraw(address sender,address token,uint128 amount,uint64 nonce)");
    bytes32 public constant ORDER_TYPEHASH =
        keccak256("Order(address sender,uint128 size,uint128 price,uint64 nonce,uint8 productIndex,uint8 orderSide)");

    function initialize(
        address _access,
        address _clearingService,
        address _spotEngine,
        address _perpEngine,
        address _book,
        address _feeRecipient
    ) external initializer {
        __EIP712_init(NAME, VERSION);
        if (
            _access == address(0) || _clearingService == address(0) || _spotEngine == address(0)
                || _perpEngine == address(0) || _book == address(0)
        ) {
            revert Errors.ZeroAddress();
        }

        accessContract = Access(_access);
        clearingService = IClearingService(_clearingService);
        spotEngine = ISpot(_spotEngine);
        perpEngine = IPerp(_perpEngine);
        book = IOrderBook(_book);

        executedTransactionCounter = 0;
        feeRecipientAddress = _feeRecipient;
        canDeposit = true;
        canWithdraw = true;
        pauseBatchProcess = false;
    }

    function _onlyGeneralAdmin() internal view {
        if (!accessContract.hasRole(accessContract.ADMIN_GENERAL_ROLE(), msg.sender)) {
            revert Errors.Unauthorized();
        }
    }

    modifier onlyGeneralAdmin() {
        _onlyGeneralAdmin();
        _;
    }

    modifier supportedToken(address token) {
        if (!supportedTokens.contains(token)) {
            revert Errors.Exchange_TokenNotSupported(token);
        }
        _;
    }

    ///@inheritdoc IExchange
    function addSupportedToken(address token) external onlyGeneralAdmin {
        bool success = supportedTokens.add(token);
        if (!success) {
            revert Errors.Exchange_TokenAlreadySupported(token);
        }
        emit SupportedTokenAdded(token);
    }

    ///@inheritdoc IExchange
    function removeSupportedToken(address token) external onlyGeneralAdmin {
        bool success = supportedTokens.remove(token);
        if (!success) {
            revert Errors.Exchange_TokenNotSupported(token);
        }
        emit SupportedTokenRemoved(token);
    }

    ///@inheritdoc IExchange
    function deposit(address tokenAddress, uint128 amount) external supportedToken(tokenAddress) {
        if (!canDeposit) {
            revert Errors.Exchange_DisabledDeposit();
        }
        if (amount == 0) revert Errors.Exchange_ZeroAmount();
        IERC20Extend token = IERC20Extend(tokenAddress);
        uint256 amountToTransfer = _convertToRawAmount(tokenAddress, amount);
        token.safeTransferFrom(msg.sender, address(this), amountToTransfer);
        clearingService.deposit(msg.sender, amount, tokenAddress, spotEngine);
        int256 currentBalance = spotEngine.getBalance(tokenAddress, msg.sender);
        emit Deposit(tokenAddress, msg.sender, amount, uint256(currentBalance));
    }

    ///@inheritdoc IExchange
    function deposit(address recipient, address tokenAddress, uint128 amount) external supportedToken(tokenAddress) {
        if (!canDeposit) {
            revert Errors.Exchange_DisabledDeposit();
        }
        if (amount == 0) revert Errors.Exchange_ZeroAmount();
        IERC20Extend token = IERC20Extend(tokenAddress);
        uint256 amountToTransfer = _convertToRawAmount(tokenAddress, amount);
        token.safeTransferFrom(msg.sender, address(this), amountToTransfer);
        clearingService.deposit(recipient, amount, tokenAddress, spotEngine);
        int256 currentBalance = spotEngine.getBalance(tokenAddress, recipient);
        emit Deposit(tokenAddress, recipient, amount, uint256(currentBalance));
    }

    ///@inheritdoc IExchange
    function depositRaw(
        address recipient,
        address tokenAddress,
        uint128 rawAmount
    ) external supportedToken(tokenAddress) {
        if (!canDeposit) {
            revert Errors.Exchange_DisabledDeposit();
        }
        if (rawAmount == 0) revert Errors.Exchange_ZeroAmount();
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
            revert Errors.Exchange_DisabledDeposit();
        }

        if (amount == 0) revert Errors.Exchange_ZeroAmount();
        uint256 amountToTransfer = _convertToRawAmount(tokenAddress, amount);
        IERC3009Minimal(tokenAddress).receiveWithAuthorization(
            depositor, address(this), amountToTransfer, validAfter, validBefore, nonce, signature
        );
        clearingService.deposit(depositor, amount, tokenAddress, spotEngine);
        int256 currentBalance = spotEngine.getBalance(tokenAddress, depositor);
        emit Deposit(tokenAddress, depositor, amount, uint256(currentBalance));
    }

    /// @inheritdoc IExchange
    function depositInsuranceFund(uint256 amount) external onlyGeneralAdmin {
        address token = book.getCollateralToken();

        uint256 amountToTransfer = _convertToRawAmount(token, uint128(amount));
        IERC20Extend(token).safeTransferFrom(msg.sender, address(this), amountToTransfer);
        clearingService.depositInsuranceFund(amount);

        uint256 insuranceFund = clearingService.getInsuranceFund();
        emit DepositInsuranceFund(amount, insuranceFund);
    }

    /// @inheritdoc IExchange
    function withdrawInsuranceFund(uint256 amount) external onlyGeneralAdmin {
        address token = book.getCollateralToken();

        uint256 amountToTransfer = _convertToRawAmount(token, uint128(amount));
        IERC20Extend(token).safeTransfer(msg.sender, amountToTransfer);
        clearingService.withdrawInsuranceFundEmergency(amount);

        uint256 insuranceFund = clearingService.getInsuranceFund();
        emit WithdrawInsuranceFund(amount, insuranceFund);
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
            revert Errors.Exchange_PausedProcessBatch();
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
                revert Errors.Exchange_NotLiquidatedOrder(transactionId);
            }
            if (maker.isLiquidation) {
                revert Errors.Exchange_MakerLiquidatedOrder(transactionId);
            }

            _verifySignature(maker.signer, digest.maker, maker.signature);
            if (!isSigningWallet(maker.order.sender, maker.signer)) {
                revert Errors.Exchange_UnauthorizedSigner(maker.order.sender, maker.signer);
            }

            if (maker.order.productIndex != taker.order.productIndex) {
                revert Errors.Exchange_ProductIdMismatch();
            }

            // 20 bytes is makerReferrer
            // 2 bytes is makerReferrerRebateRate
            // 20 bytes is takerReferrer
            // 2 bytes is takerReferrerRebateRate
            if (data.length > 349) {
                (address makerReferrer, uint16 makerReferrerRebateRate) = _parseReferralData(data[349:371]);
                matchFee.referralRebate += _rebateReferrer(matchFee.maker, makerReferrer, makerReferrerRebateRate);

                (address takerReferrer, uint16 takerReferrerRebateRate) = _parseReferralData(data[371:393]);
                matchFee.referralRebate += _rebateReferrer(matchFee.taker, takerReferrer, takerReferrerRebateRate);
            }
            matchFee.maker = _rebateMaker(maker.order.sender, matchFee.maker);

            // 16 bytes is liquidation fee
            if (data.length > 393) {
                uint128 liquidationFee = uint128(bytes16(data[393:409])); //16 bytes for liquidation fee
                matchFee.liquidationPenalty = liquidationFee;
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
                revert Errors.Exchange_UnauthorizedSigner(maker.order.sender, maker.signer);
            }
            // 165 bytes for an order
            (taker.order, taker.signature, taker.signer, taker.isLiquidation, matchFee.taker) =
                _parseDataToOrder(data[169:333]);
            uint128 takerSequencerFee = uint128(bytes16(data[333:349])); //16 bytes for takerSequencerFee
            digest.taker = _getOrderDigest(taker.order);

            if (taker.isLiquidation || maker.isLiquidation) {
                revert Errors.Exchange_LiquidatedOrder(transactionId);
            }

            _verifySignature(taker.signer, digest.taker, taker.signature);
            if (!isSigningWallet(taker.order.sender, taker.signer)) {
                revert Errors.Exchange_UnauthorizedSigner(taker.order.sender, taker.signer);
            }

            if (maker.order.productIndex != taker.order.productIndex) {
                revert Errors.Exchange_ProductIdMismatch();
            }

            // 20 bytes is makerReferrer
            // 2 bytes is makerReferrerRebateRate
            // 20 bytes is takerReferrer
            // 2 bytes is takerReferrerRebateRate
            if (data.length > 349) {
                (address makerReferrer, uint16 makerReferrerRebateRate) = _parseReferralData(data[349:371]);
                matchFee.referralRebate += _rebateReferrer(matchFee.maker, makerReferrer, makerReferrerRebateRate);

                (address takerReferrer, uint16 takerReferrerRebateRate) = _parseReferralData(data[371:393]);
                matchFee.referralRebate += _rebateReferrer(matchFee.taker, takerReferrer, takerReferrerRebateRate);
            }
            matchFee.maker = _rebateMaker(maker.order.sender, matchFee.maker);

            book.matchOrders(maker, taker, digest, maker.order.productIndex, takerSequencerFee, matchFee);
        } else if (operationType == OperationType.UpdateFundingRate) {
            UpdateFundingRate memory txs = abi.decode(data[5:], (UpdateFundingRate));
            if (lastFundingRateUpdate >= txs.lastFundingRateUpdateSequenceNumber) {
                revert Errors.Exchange_InvalidFundingRateSequenceNumber(
                    txs.lastFundingRateUpdateSequenceNumber, lastFundingRateUpdate
                );
            }
            int256 cumulativeFunding = perpEngine.updateFundingRate(txs.productIndex, txs.priceDiff);
            lastFundingRateUpdate = txs.lastFundingRateUpdateSequenceNumber;
            emit FundingRate(txs.productIndex, txs.priceDiff, cumulativeFunding, transactionId);
        } else if (operationType == OperationType.CoverLossByInsuranceFund) {
            address account = abi.decode(data[5:], (address));
            clearingService.coverLossWithInsuranceFund(spotEngine, book.getCollateralToken(), account);
        } else if (operationType == OperationType.AddSigningWallet) {
            AddSigningWallet memory txs = abi.decode(data[5:], (AddSigningWallet));
            _addSigningWallet(txs.sender, txs.signer, txs.message, txs.nonce, txs.walletSignature, txs.signerSignature);
            emit SigningWallet(txs.sender, txs.signer, transactionId);
        } else if (operationType == OperationType.Withdraw) {
            Withdraw memory txs = abi.decode(data[5:], (Withdraw));
            if (!canWithdraw) {
                revert Errors.Exchange_DisabledWithdraw();
            }
            if (txs.withdrawalSequencerFee > MAX_WITHDRAWAL_FEE) {
                revert Errors.Exchange_ExceededMaxWithdrawFee(txs.withdrawalSequencerFee, MAX_WITHDRAWAL_FEE);
            }
            bytes32 digest =
                _hashTypedDataV4(keccak256(abi.encode(WITHDRAW_TYPEHASH, txs.sender, txs.token, txs.amount, txs.nonce)));
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
            revert Errors.Exchange_InvalidOperationType();
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
                    ORDER_TYPEHASH,
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
        _verifySigningNonce(sender, nonce);

        // verify signature of sender
        bytes32 registerHash = _hashTypedDataV4(
            keccak256(abi.encode(REGISTER_TYPEHASH, signer, keccak256(abi.encodePacked(authorizedMsg)), nonce))
        );
        if (!SignatureChecker.isValidSignatureNow(sender, registerHash, senderSignature)) {
            revert Errors.Exchange_InvalidSignature(sender);
        }

        // verify signature of authorized signer
        bytes32 signKeyHash = _hashTypedDataV4(keccak256(abi.encode(SIGN_KEY_TYPEHASH, sender)));
        _verifySignature(signer, signKeyHash, signerSignature);

        _signingWallets[sender][signer] = true;
        usedNonces[sender][nonce] = true;

        emit RegisterSigningWallet(sender, signer, nonce);
    }

    /// @dev Validates a signature
    function _verifySignature(address signer, bytes32 digest, bytes memory signature) internal pure {
        address recoveredSigner = ECDSA.recover(digest, signature);
        if (recoveredSigner != signer) {
            revert Errors.Exchange_InvalidSignerSignature(recoveredSigner, signer);
        }
    }

    /// @dev Checks if a nonce is used for adding a signing wallet, revert if nonce is used
    function _verifySigningNonce(address sender, uint64 nonce) internal view {
        if (usedNonces[sender][nonce]) {
            revert Errors.Exchange_AddSigningWallet_UsedNonce(sender, nonce);
        }
    }

    /// @dev Checks if a nonce is used for withdraw, revert if nonce is used
    function _verifyWithdrawNonce(address sender, uint64 nonce) internal view {
        if (isWithdrawSuccess[sender][nonce]) {
            revert Errors.Exchange_Withdraw_NonceUsed(sender, nonce);
        }
    }

    /// @dev Parses referral data from encoded data
    /// @param data Encoded data
    function _parseReferralData(bytes calldata data)
        internal
        pure
        returns (address referrer, uint16 referrerRebateRate)
    {
        // 20 bytes is referrer
        // 2 bytes is referrer rebate rate
        referrer = address(bytes20(data[0:20]));
        referrerRebateRate = uint16(bytes2(data[20:22]));
    }

    /// @dev Calculate the fee and rebate for an order
    function _rebateReferrer(int128 fee, address referrer, uint16 rebateRate) internal returns (uint128 rebate) {
        if (referrer == address(0) || rebateRate == 0 || fee <= 0) {
            return 0;
        }

        if (rebateRate > MAX_REBATE_RATE) {
            revert Errors.Exchange_ExceededMaxRebateRate(rebateRate, MAX_REBATE_RATE);
        }

        rebate = uint128(fee).calculatePercentage(rebateRate);

        ISpot.AccountDelta[] memory productDeltas = new ISpot.AccountDelta[](1);
        productDeltas[0] = ISpot.AccountDelta(book.getCollateralToken(), referrer, int128(rebate));
        spotEngine.modifyAccount(productDeltas);

        emit RebateReferrer(referrer, rebate);
    }

    /// @dev Rebate maker if the fee is defined as negative
    function _rebateMaker(address maker, int128 fee) internal returns (int128) {
        if (fee >= 0) {
            return fee;
        }

        int128 rebate = -fee;
        ISpot.AccountDelta[] memory productDeltas = new ISpot.AccountDelta[](1);
        productDeltas[0] = ISpot.AccountDelta(book.getCollateralToken(), maker, rebate);
        spotEngine.modifyAccount(productDeltas);

        emit RebateMaker(maker, uint128(rebate));

        return 0;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                DEVELOPMENT ONLY
    //////////////////////////////////////////////////////////////////////////*/
    function depositTestToken(
        address user,
        address tokenAddress,
        uint256 amount
    ) external supportedToken(tokenAddress) onlyGeneralAdmin {
        _depositTestToken(user, tokenAddress, amount);
    }

    function depositTestTokenBatch(
        address[] memory users,
        address tokenAddress,
        uint256 amount
    ) external supportedToken(tokenAddress) onlyGeneralAdmin {
        for (uint256 index = 0; index < users.length; ++index) {
            _depositTestToken(users[index], tokenAddress, amount);
        }
    }

    function _depositTestToken(address user, address tokenAddress, uint256 amount) private {
        require(amount > 0, "Exchange: Zero amount");
        require(canDeposit, "Exchange: Disabled deposit");

        clearingService.deposit(user, amount, tokenAddress, spotEngine);
        int256 currentBalance = spotEngine.getBalance(tokenAddress, user);

        _userWallets.add(user); // store user wallet

        emit Deposit(tokenAddress, user, amount, uint256(currentBalance));
    }

    function resetAccounts(
        address[] calldata users,
        address spotToken,
        uint256 totalProducts
    ) external onlyGeneralAdmin {
        uint8[] memory productIds = new uint8[](totalProducts);
        for (uint8 i = 0; i < totalProducts; ++i) {
            productIds[i] = i + 1;
        }

        uint256 length = users.length;
        for (uint256 index = 0; index < length; ++index) {
            address user = users[index];
            Spot(address(spotEngine)).resetBalance(user, spotToken);
            Perp(address(perpEngine)).resetBalance(productIds, user);
            _userWallets.remove(user);
        }
    }

    function resetMarketInfo(uint256 totalProducts) external onlyGeneralAdmin {
        uint8[] memory productIds = new uint8[](totalProducts);
        for (uint8 i = 0; i < totalProducts; ++i) {
            productIds[i] = i + 1;
        }

        Perp(address(perpEngine)).resetFundingRate(productIds);
        executedTransactionCounter = 0;
        lastFundingRateUpdate = 0;
        _lastResetBlockNumber = block.number;
    }

    function getUserWallets() external view returns (address[] memory) {
        uint128 length = uint128(_userWallets.length());
        address[] memory userWalletList = new address[](length);
        for (uint256 index = 0; index < length; ++index) {
            userWalletList[index] = _userWallets.at(index);
        }
        return userWalletList;
    }

    function lastResetBlockNumber() external view returns (uint256) {
        return _lastResetBlockNumber;
    }
}

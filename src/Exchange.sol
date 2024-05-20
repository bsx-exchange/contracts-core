// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {Access} from "./Access.sol";
import {Gateway} from "./abstracts/Gateway.sol";
import {IClearinghouse} from "./interfaces/IClearinghouse.sol";
import {IExchange} from "./interfaces/IExchange.sol";
import {IExchangeEvents} from "./interfaces/IExchangeEvents.sol";
import {IOrderbook} from "./interfaces/IOrderbook.sol";
import {IPerpEngine} from "./interfaces/IPerpEngine.sol";
import {ISpotEngine} from "./interfaces/ISpotEngine.sol";
import {IERC20Extend} from "./interfaces/external/IERC20Extend.sol";
import {IERC3009Minimal} from "./interfaces/external/IERC3009Minimal.sol";
import {Errors} from "./libraries/Errors.sol";
import {Math} from "./libraries/Math.sol";
import {OperationType, OrderSide} from "./types/DataTypes.sol";

/// @title Exchange contract
/// @notice This contract is entry point of the exchange
/// @dev This contract is upgradeable
// solhint-disable max-states-count
contract Exchange is Gateway, IExchange, IExchangeEvents, Initializable, EIP712Upgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20Extend;
    using Math for uint256;

    IClearinghouse public clearinghouse;
    ISpotEngine public spotEngine;
    IPerpEngine public perpEngine;
    IOrderbook public orderbook;
    Access public access;

    EnumerableSet.AddressSet private _supportedTokens;

    mapping(address account => mapping(address signer => bool isAuthorized)) public authorizedSigners;
    mapping(uint256 requestId => WithdrawalInfo withdrawalInfo) private _withdrawalInfo; // deprecated
    mapping(address account => mapping(uint64 nonce => bool used)) public authorizedSignerNonces;

    uint256 private _withdrawalRequestIDCounter; // deprecated
    uint256 private _forceWithdrawalGracePeriodSecond; // deprecated
    uint256 private _lastResetBlockNumber; // deprecated
    uint256 private _collectedSequencerFees;
    EnumerableSet.AddressSet private _userWallets; // deprecated

    uint256 public lastFundingRateId;
    uint32 public executedTransactionCounter;
    address public feeRecipient;
    bool private _isTwoPhaseWithdrawEnabled; // deprecated
    bool public canDeposit;
    bool public canWithdraw;
    bool public pausedBatchProcess;

    mapping(address account => mapping(uint64 nonce => bool isSuccess)) public withdrawNonces;
    mapping(address account => bool isRequestingWithdraw) private isRequestingTwoPhaseWithdraw; // deprecated

    string public constant NAME = "BSX Mainnet";
    string public constant VERSION = "1";

    uint128 public constant MAX_WITHDRAW_FEE = 10 ** 18;
    uint128 public constant MIN_WITHDRAW_AMOUNT = 10 ** 18;

    bytes32 public constant AUTHORIZE_SIGNER_TYPEHASH = keccak256("Register(address key,string message,uint64 nonce)");
    bytes32 public constant SIGNING_KEY_TYPEHASH = keccak256("SignKey(address account)");
    bytes32 public constant WITHDRAW_TYPEHASH =
        keccak256("Withdraw(address sender,address token,uint128 amount,uint64 nonce)");
    bytes32 public constant ORDER_TYPEHASH =
        keccak256("Order(address sender,uint128 size,uint128 price,uint64 nonce,uint8 productIndex,uint8 orderSide)");

    function initialize(
        address _access,
        address _clearinghouse,
        address _spotEngine,
        address _perpEngine,
        address _orderbook,
        address _feeRecipient
    ) external initializer {
        __EIP712_init(NAME, VERSION);

        if (
            _access == address(0) || _clearinghouse == address(0) || _spotEngine == address(0)
                || _perpEngine == address(0) || _orderbook == address(0) || _feeRecipient == address(0)
        ) {
            revert Errors.ZeroAddress();
        }

        access = Access(_access);
        clearinghouse = IClearinghouse(_clearinghouse);
        spotEngine = ISpotEngine(_spotEngine);
        perpEngine = IPerpEngine(_perpEngine);
        orderbook = IOrderbook(_orderbook);
        executedTransactionCounter = 0;
        feeRecipient = _feeRecipient;
        canDeposit = true;
        canWithdraw = true;
        pausedBatchProcess = false;

        _withdrawalRequestIDCounter = 0;
        _forceWithdrawalGracePeriodSecond = 60 * 60;
        _isTwoPhaseWithdrawEnabled = false;
    }

    modifier supportedToken(address token) {
        if (!_supportedTokens.contains(token)) {
            revert Errors.Exchange_TokenNotSupported(token);
        }
        _;
    }

    modifier whenNotPaused() {
        if (pausedBatchProcess) {
            revert Errors.Exchange_PausedProcessBatch();
        }
        _;
    }

    modifier whenDepositEnabled() {
        if (!canDeposit) {
            revert Errors.Exchange_DisabledDeposit();
        }
        _;
    }

    /// @inheritdoc IExchange
    function addSupportedToken(address token) external override authorized {
        bool success = _supportedTokens.add(token);
        if (!success) {
            revert Errors.Exchange_TokenAlreadySupported(token);
        }
        emit AddSupportedToken(token);
    }

    /// @inheritdoc IExchange
    function removeSupportedToken(address token) external override authorized {
        bool success = _supportedTokens.remove(token);
        if (!success) {
            revert Errors.Exchange_TokenNotSupported(token);
        }
        emit RemoveSupportedToken(token);
    }

    ///@inheritdoc IExchange
    function deposit(address token, uint128 amount) external override whenDepositEnabled supportedToken(token) {
        address recipient = msg.sender;
        address payer = msg.sender;
        _deposit(payer, recipient, token, amount);
    }

    ///@inheritdoc IExchange
    function deposit(
        address recipient,
        address token,
        uint128 amount
    ) external override whenDepositEnabled supportedToken(token) {
        address payer = msg.sender;
        _deposit(payer, recipient, token, amount);
    }

    ///@inheritdoc IExchange
    function depositRaw(
        address recipient,
        address token,
        uint256 rawAmount
    ) external override whenDepositEnabled supportedToken(token) {
        address payer = msg.sender;
        uint256 amount = rawAmount.convertTo18D(IERC20Extend(token).decimals());
        _deposit(payer, recipient, token, uint128(amount));
    }

    //// @inheritdoc IExchange
    function depositWithAuthorization(
        address token,
        address depositor,
        uint128 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external override whenDepositEnabled supportedToken(token) {
        if (amount == 0) revert Errors.ZeroAmount();

        uint8 tokenDecimals = IERC20Extend(token).decimals();
        uint256 rawAmount = uint256(amount).convertFrom18D(tokenDecimals);
        IERC3009Minimal(token).receiveWithAuthorization(
            depositor, address(this), rawAmount, validAfter, validBefore, nonce, signature
        );

        clearinghouse.deposit(depositor, token, amount);
        int256 currentBalance = spotEngine.getBalance(depositor, token);

        emit Deposit(depositor, token, amount, currentBalance);
    }

    /// @inheritdoc IExchange
    function processBatch(bytes[] calldata operations) external authorized whenNotPaused {
        uint256 length = operations.length;
        for (uint128 i = 0; i < length; ++i) {
            bytes calldata op = operations[i];
            _handleOperation(op);
        }
    }

    /// @inheritdoc IExchange
    function claimCollectedTradingFees() external authorized {
        address token = orderbook.getCollateralToken();
        uint256 collectedFee = orderbook.claimCollectedTradingFees();
        _transfer18D(token, feeRecipient, collectedFee);
        emit ClaimCollectedTradingFees(msg.sender, collectedFee);
    }

    /// @inheritdoc IExchange
    function claimCollectedSequencerFees() external authorized {
        address token = orderbook.getCollateralToken();
        uint256 collectedFee = _collectedSequencerFees + orderbook.claimCollectedSequencerFees();

        _collectedSequencerFees = 0; // reset sequencer fee
        _transfer18D(token, feeRecipient, collectedFee);

        emit ClaimCollectedSequencerFees(msg.sender, uint256(collectedFee));
    }

    /// @inheritdoc IExchange
    function depositInsuranceFund(uint256 amount) external authorized {
        address collateralToken = orderbook.getCollateralToken();
        address from = msg.sender;
        address to = address(this);
        _transferFrom18D(collateralToken, from, to, amount);
        clearinghouse.depositInsuranceFund(amount);
        emit DepositInsuranceFund(amount);
    }

    /// @inheritdoc IExchange
    function withdrawInsuranceFund(uint256 amount) external authorized {
        address collateralToken = orderbook.getCollateralToken();
        address to = msg.sender;
        _transfer18D(collateralToken, to, amount);
        clearinghouse.withdrawInsuranceFund(amount);
        emit WithdrawInsuranceFund(amount);
    }

    /// @inheritdoc IExchange
    function updateFeeRecipient(address _feeRecipient) external authorized {
        if (_feeRecipient == address(0)) {
            revert Errors.ZeroAddress();
        }
        feeRecipient = _feeRecipient;
    }

    ///@inheritdoc IExchange
    function pauseProcessBatch() external override authorized {
        pausedBatchProcess = true;
    }

    ///@inheritdoc IExchange
    function unpauseProcessBatch() external override authorized {
        pausedBatchProcess = false;
    }

    /// @inheritdoc IExchange
    function enableWithdraw() external authorized {
        canWithdraw = true;
    }

    /// @inheritdoc IExchange
    function disableWithdraw() external authorized {
        canWithdraw = false;
    }

    /// @inheritdoc IExchange
    function enableDeposit() external authorized {
        canDeposit = true;
    }

    /// @inheritdoc IExchange
    function disableDeposit() external authorized {
        canDeposit = false;
    }

    /// @inheritdoc IExchange
    function getCollectedSequencerFees() external view returns (uint256) {
        return _collectedSequencerFees + orderbook.getCollectedSequencerFees();
    }

    /// @inheritdoc IExchange
    function getSupportedTokenList() public view override returns (address[] memory) {
        uint8 length = uint8(_supportedTokens.length());
        address[] memory tokenList = new address[](length);
        for (uint256 index = 0; index < length; index++) {
            tokenList[index] = _supportedTokens.at(index);
        }
        return tokenList;
    }

    /// @inheritdoc IExchange
    function isSupportedToken(address token) external view override returns (bool) {
        return _supportedTokens.contains(token);
    }

    /// @inheritdoc Gateway
    function _isAuthorized(address caller) internal view override returns (bool) {
        return access.hasRole(access.GENERAL_ADMIN_ROLE(), caller);
    }

    function _deposit(address payer, address recipient, address token, uint128 amount) private {
        if (amount == 0) revert Errors.ZeroAmount();

        _transferFrom18D(token, payer, address(this), amount);

        clearinghouse.deposit(recipient, token, amount);
        int256 currentBalance = spotEngine.getBalance(recipient, token);

        emit Deposit(recipient, token, amount, currentBalance);
    }

    function _transfer18D(address token, address to, uint256 amount) private {
        uint8 tokenDecimals = IERC20Extend(token).decimals();
        uint256 rawAmount = amount.convertFrom18D(tokenDecimals);
        IERC20Extend(token).safeTransfer(to, rawAmount);
    }

    function _transferFrom18D(address token, address from, address to, uint256 amount) private {
        uint8 tokenDecimals = IERC20Extend(token).decimals();
        uint256 rawAmount = amount.convertFrom18D(tokenDecimals);
        IERC20Extend(token).safeTransferFrom(from, to, rawAmount);
    }

    // solhint-disable code-complexity
    function _handleOperation(bytes calldata data) private {
        // 1 byte is operation type
        // 4 bytes is transaction ID
        OperationType operationType = OperationType(uint8(data[0]));
        uint32 transactionId = uint32(bytes4(data[1:5]));
        if (transactionId != executedTransactionCounter) {
            revert Errors.Exchange_InvalidTransactionId(transactionId, executedTransactionCounter);
        }
        executedTransactionCounter += 1;

        if (operationType == OperationType.AuthorizeSigner) {
            (
                address account,
                address signer,
                string memory message,
                uint64 nonce,
                bytes memory accountSignature,
                bytes memory signerSignature
            ) = abi.decode(data[5:], (address, address, string, uint64, bytes, bytes));

            _validateSignature(
                account,
                _hashTypedDataV4(
                    keccak256(
                        abi.encode(AUTHORIZE_SIGNER_TYPEHASH, signer, keccak256(abi.encodePacked(message)), nonce)
                    )
                ),
                accountSignature
            );
            _validateSignature(
                signer, _hashTypedDataV4(keccak256(abi.encode(SIGNING_KEY_TYPEHASH, account))), signerSignature
            );

            if (authorizedSignerNonces[account][nonce]) {
                revert Errors.Exchange_AuthorizeSigner_UsedNonce(account, nonce);
            }
            authorizedSignerNonces[account][nonce] = true;
            authorizedSigners[account][signer] = true;

            emit AuthorizeSigner(account, signer, transactionId);
        } else if (operationType == OperationType.MatchOrders) {
            bool isLiquidated = false;
            uint8 productId;
            IOrderbook.Fee memory fee;
            IOrderbook.Order memory maker;
            IOrderbook.Order memory taker;

            // avoid "stack too deep"
            {
                uint8 makerProductId;
                bool makerIsLiquidated;
                uint8 takerProductId;
                bool takerIsLiquidated;

                // Encoded order following `_validateAndParseOrder` function
                // 165 bytes for each order
                (makerProductId, maker, makerIsLiquidated, fee.maker) = _validateAndParseOrder(data[5:169]);
                (takerProductId, taker, takerIsLiquidated, fee.taker) = _validateAndParseOrder(data[169:333]);

                if (makerIsLiquidated || takerIsLiquidated) {
                    revert Errors.Exchange_LiquidatedOrder();
                }

                if (makerProductId != takerProductId) {
                    revert Errors.Exchange_ProductIdMismatch();
                }
                productId = makerProductId;
            }

            // 16 bytes for sequencerFee
            uint128 sequencerFee = uint128(bytes16(data[333:349]));
            fee.sequencer = sequencerFee;

            orderbook.matchOrders(productId, maker, taker, fee, isLiquidated);
        } else if (operationType == OperationType.MatchLiquidatedOrders) {
            bool isLiquidated = true;
            uint8 productId;
            IOrderbook.Fee memory fee;
            IOrderbook.Order memory maker;
            IOrderbook.Order memory taker;

            {
                uint8 makerProductId;
                bool makerIsLiquidated;
                uint8 takerProductId;
                bool takerIsLiquidated;

                // Encoded order following `_validateAndParseOrder` function
                // 165 bytes for each order
                (makerProductId, maker, makerIsLiquidated, fee.maker) = _validateAndParseOrder(data[5:169]);
                (takerProductId, taker, takerIsLiquidated, fee.taker) = _validateAndParseOrder(data[169:333]);

                if (makerIsLiquidated) {
                    revert Errors.Exchange_LiquidatedOrder();
                }
                if (takerIsLiquidated != isLiquidated) {
                    revert Errors.Exchange_NotLiquidatedOrder();
                }

                if (makerProductId != takerProductId) {
                    revert Errors.Exchange_ProductIdMismatch();
                }
                productId = makerProductId;
            }

            // 16 bytes for sequencerFee
            uint128 sequencerFee = uint128(bytes16(data[333:349]));
            fee.sequencer = sequencerFee;

            orderbook.matchOrders(productId, maker, taker, fee, isLiquidated);
        } else if (operationType == OperationType.CumulateFundingRate) {
            (uint8 productId, int128 premiumRate, uint256 fundingRateId) =
                abi.decode(data[5:], (uint8, int128, uint256));
            if (fundingRateId <= lastFundingRateId) {
                revert Errors.Exchange_InvalidFundingRateId(fundingRateId, lastFundingRateId);
            }
            lastFundingRateId = fundingRateId;
            int256 cumulativeFundingRate = perpEngine.cumulateFundingRate(productId, premiumRate);

            emit CumulateFundingRate(productId, premiumRate, cumulativeFundingRate, transactionId);
        } else if (operationType == OperationType.CoverLossWithInsuranceFund) {
            (address account, address token) = abi.decode(data[5:], (address, address));
            clearinghouse.coverLossWithInsuranceFund(account, token);
        } else if (operationType == OperationType.Withdraw) {
            (address account, address token, uint128 amount, uint64 nonce, bytes memory signature, uint128 withdrawFee)
            = abi.decode(data[5:], (address, address, uint128, uint64, bytes, uint128));
            if (!canWithdraw) {
                revert Errors.Exchange_DisabledWithdraw();
            }

            if (withdrawFee > MAX_WITHDRAW_FEE) {
                revert Errors.Exchange_ExceededMaxWithdrawFee();
            }
            bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(WITHDRAW_TYPEHASH, account, token, amount, nonce)));
            _validateSignature(account, digest, signature);

            if (withdrawNonces[account][nonce]) {
                revert Errors.Exchange_Withdraw_UsedNonce(account, nonce);
            }
            withdrawNonces[account][nonce] = true;

            int256 balance = spotEngine.getBalance(account, token);
            if (amount < MIN_WITHDRAW_AMOUNT || balance < int256(int128(amount))) {
                emit WithdrawRejected(account, token, amount, balance);
            } else {
                clearinghouse.withdraw(account, token, amount);

                // collect sequencer fee
                _collectedSequencerFees += uint256(withdrawFee);
                uint128 netAmount = amount - withdrawFee;

                uint8 tokenDecimals = IERC20Extend(token).decimals();
                uint256 rawAmount = uint256(netAmount).convertFrom18D(tokenDecimals);
                IERC20Extend(token).safeTransfer(account, rawAmount);

                balance = spotEngine.getBalance(account, token);
                emit Withdraw(account, token, amount, withdrawFee, balance);
            }
        } else {
            revert Errors.Exchange_InvalidOperation();
        }
    }

    function _validateAndParseOrder(bytes calldata data)
        private
        view
        returns (uint8 productId, IOrderbook.Order memory order, bool isLiquidated, uint128 tradingFee)
    {
        // Data size is 165 bytes, following structure:
        // 20-byte : sender
        // 16-byte : size
        // 16-byte : price
        //  8-byte : nonce
        //  1-byte : productId
        //  1-byte : orderSide
        // 65-byte : signature
        // 20-byte : signer
        //  1-byte : isLiquidated
        // 16-byte : tradingFee
        order.account = address(bytes20(data[0:20]));
        order.size = uint128(bytes16(data[20:36]));
        order.price = uint128(bytes16(data[36:52]));
        order.nonce = uint64(bytes8(data[52:60]));
        productId = uint8(data[60]);
        order.orderSide = OrderSide(uint8(data[61]));

        bytes memory signature = data[62:127];
        address signer = address(bytes20(data[127:147]));

        isLiquidated = uint8(data[147]) == 1;
        tradingFee = uint128(bytes16(data[148:164]));

        order.orderHash = _hashOrder(productId, order);
        if (!isLiquidated) {
            _validateSigner(order.account, signer);
            _validateSignature(signer, order.orderHash, signature);
        }
    }

    function _hashOrder(uint8 productId, IOrderbook.Order memory order) private view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH, order.account, order.size, order.price, order.nonce, productId, order.orderSide
                )
            )
        );
    }

    function _validateSigner(address account, address signer) private view {
        if (!authorizedSigners[account][signer]) {
            revert Errors.Exchange_UnauthorizedSigner(account, signer);
        }
    }

    function _validateSignature(address signer, bytes32 digest, bytes memory signature) private pure {
        address recoveredSigner = ECDSA.recover(digest, signature);
        if (recoveredSigner != signer) {
            revert Errors.Exchange_InvalidSigner(recoveredSigner, signer);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IBSX1000x} from "../1000x/interfaces/IBSX1000x.sol";
import {ExchangeStorage} from "./ExchangeStorage.sol";
import {IExchange, ILiquidation, ISwap} from "./interfaces/IExchange.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {ISpot} from "./interfaces/ISpot.sol";
import {Errors} from "./lib/Errors.sol";
import {LibOrder} from "./lib/LibOrder.sol";
import {MathHelper} from "./lib/MathHelper.sol";
import {Percentage} from "./lib/Percentage.sol";
import {BalanceLogic} from "./lib/logic/BalanceLogic.sol";
import {LiquidationLogic} from "./lib/logic/LiquidationLogic.sol";
import {SwapLogic} from "./lib/logic/SwapLogic.sol";
import {MAX_REBATE_RATE, NATIVE_ETH, UNIVERSAL_SIG_VALIDATOR} from "./share/Constants.sol";
import {OrderSide} from "./share/Enums.sol";

/// @title Exchange contract
/// @notice This contract is entry point of the exchange
/// @dev This contract is upgradeable
contract Exchange is Initializable, EIP712Upgradeable, ExchangeStorage, IExchange {
    using EnumerableSet for EnumerableSet.AddressSet;
    using LibOrder for LibOrder.Order;
    using SafeERC20 for IERC20;
    using Percentage for uint128;
    using MathHelper for uint128;
    using MathHelper for uint256;
    using MathHelper for int128;
    using MathHelper for int256;

    bytes32 public constant REGISTER_TYPEHASH = keccak256("Register(address key,string message,uint64 nonce)");
    bytes32 public constant SIGN_KEY_TYPEHASH = keccak256("SignKey(address account)");
    bytes32 public constant SWAP_TYPEHASH = keccak256(
        "Swap(address account,address assetIn,uint256 amountIn,address assetOut,uint256 minAmountOut,uint256 nonce)"
    );
    bytes32 public constant WITHDRAW_TYPEHASH =
        keccak256("Withdraw(address sender,address token,uint128 amount,uint64 nonce)");
    bytes32 public constant TRANSFER_TO_BSX1000_TYPEHASH =
        keccak256("TransferToBSX1000(address account,address token,uint256 amount,uint256 nonce)");
    bytes32 public constant ORDER_TYPEHASH =
        keccak256("Order(address sender,uint128 size,uint128 price,uint64 nonce,uint8 productIndex,uint8 orderSide)");

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
        // check signature
        bytes32 swapCollateralHash = _hashTypedDataV4(
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

        return SwapLogic.executeSwap(
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
    function balanceOf(address user, address token) public view returns (int256) {
        int256 balance = spotEngine.getBalance(token, user);
        return balance;
    }

    /// @inheritdoc IExchange
    function getSupportedTokenList() public view returns (address[] memory tokenList) {
        uint8 length = uint8(supportedTokens.length());
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

    /// @dev Handles a withdraw
    function _withdraw(Withdraw memory data) internal {
        if (!canWithdraw) {
            revert Errors.Exchange_DisabledWithdraw();
        }
        if (isWithdrawNonceUsed[data.sender][data.nonce]) {
            revert Errors.Exchange_Withdraw_NonceUsed(data.sender, data.nonce);
        }
        isWithdrawNonceUsed[data.sender][data.nonce] = true;

        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(WITHDRAW_TYPEHASH, data.sender, data.token, data.amount, data.nonce)));

        // only EOA can withdraw ETH
        bool isValidSignature = data.token == NATIVE_ETH
            ? ECDSA.recover(digest, data.signature) == data.sender
            : UNIVERSAL_SIG_VALIDATOR.isValidSig(data.sender, digest, data.signature);

        if (!isValidSignature) {
            emit WithdrawFailed(data.sender, data.nonce, 0, 0);
            return;
        }

        BalanceLogic.withdraw(_collectedFee, BalanceLogic.BalanceEngine(clearingService, spotEngine), data);
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

    function innerTransferToBSX1000(TransferToBSX1000Params memory data)
        external
        internalCall
        returns (uint256 balance)
    {
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(TRANSFER_TO_BSX1000_TYPEHASH, data.account, data.token, data.amount, data.nonce))
        );
        if (!UNIVERSAL_SIG_VALIDATOR.isValidSig(data.account, digest, data.signature)) {
            revert Errors.Exchange_InvalidSignature(data.account);
        }

        return BalanceLogic.transferToBSX1000(
            BalanceLogic.BalanceEngine(clearingService, spotEngine),
            IBSX1000x(access.getBsx1000()),
            data.account,
            data.token,
            data.amount
        );
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
        if (!UNIVERSAL_SIG_VALIDATOR.isValidSig(sender, registerHash, senderSignature)) {
            revert Errors.Exchange_InvalidSignature(sender);
        }

        // verify signature of authorized signer
        bytes32 signKeyHash = _hashTypedDataV4(keccak256(abi.encode(SIGN_KEY_TYPEHASH, sender)));
        _verifySignature(signer, signKeyHash, signerSignature);

        _signingWallets[sender][signer] = true;
        isRegisterSignerNonceUsed[sender][nonce] = true;

        emit RegisterSigner(sender, signer, nonce);
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
        if (isRegisterSignerNonceUsed[sender][nonce]) {
            revert Errors.Exchange_AddSigningWallet_UsedNonce(sender, nonce);
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

        rebate = fee.safeUInt128().calculatePercentage(rebateRate);

        ISpot.AccountDelta[] memory productDeltas = new ISpot.AccountDelta[](1);
        productDeltas[0] = ISpot.AccountDelta(book.getCollateralToken(), referrer, rebate.safeInt128());
        spotEngine.modifyAccount(productDeltas);

        emit RebateReferrer(referrer, rebate);
    }

    /// @dev Rebate maker if the fee is defined as negative
    /// @return Maker fee after rebate
    function _rebateMaker(address maker, int128 fee) internal returns (int128) {
        if (fee >= 0) {
            return fee;
        }

        uint128 rebate = fee.abs();
        ISpot.AccountDelta[] memory productDeltas = new ISpot.AccountDelta[](1);
        productDeltas[0] = ISpot.AccountDelta(book.getCollateralToken(), maker, rebate.safeInt128());
        spotEngine.modifyAccount(productDeltas);

        emit RebateMaker(maker, rebate);

        return 0;
    }
}

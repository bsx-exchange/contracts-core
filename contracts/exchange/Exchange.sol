// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "./interfaces/IERC20Extend.sol";
import "./interfaces/IERC3009.sol";
import "./lib/MathHelper.sol";
import "./interfaces/IExchange.sol";
import "./share/Constants.sol";
import "./share/Enums.sol";
import "./access/Access.sol";
import "./interfaces/IClearingService.sol";
import "./interfaces/ISpot.sol";
import "./interfaces/IPerp.sol";
import "./lib/LibOrder.sol";
import "./interfaces/IOrderBook.sol";
import "./share/RevertReason.sol";

/**
 * @title Exchange contract
 * @author BSX
 * @notice This contract is entry point of the system.
 * It is responsible for:
 * - Deposit token to the system
 * - Withdraw token from the system
 * - Match orders
 * - Deposit insurance fund
 * - Update funding rate
 * - Assert open interest
 * - Cover loss by insurance fund
 * - Emergency withdraw
 * - Add/remove supported token
 * - Get supported token list
 * - Add signing wallet
 * - Check if a signer is a signing wallet of a sender
 * - Submit transactions
 * @dev This contract is upgradeable
 */
contract Exchange is
    Initializable,
    OwnableUpgradeable,
    EIP712Upgradeable,
    ReentrancyGuardUpgradeable,
    IExchange
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using LibOrder for LibOrder.Order;
    using SafeERC20 for IERC20Extend;

    IClearingService public clearingService;
    ISpot public spotEngine;
    IPerp public perpEngine;
    IOrderBook public book;
    Access accessContract;

    EnumerableSet.AddressSet supportedTokens;
    //mapping sender => signer => bool
    mapping(address => mapping(address => bool)) public signingWallets;
    //mapping requestID => WithdrawalInfo
    mapping(uint256 => WithdrawalInfo) public withdrawalInfo;
    //mapping sender => nonce => bool for add siging wallet
    mapping(address => mapping(uint64 => bool)) public usedNonces;

    uint256 public withdrawalRequestIDCounter;
    uint256 public forceWithdrawalGracePeriodSecond;
    uint256 public lastResetBlockNumber;
    int256 sequencerFee;
    EnumerableSet.AddressSet userWallets;
    uint256 public lastFundingRateUpdate;
    uint32 public executedTransactionCounter;
    address public feeRecipientAddress;
    bool public isTwoPhaseWithdrawEnabled;
    bool public canDeposit;
    bool public canWithdraw;
    bool public pauseBatchProcess;
    //mapping sender => nonce => bool for withdraw
    mapping(address => mapping(uint64 => bool)) public isWithdrawSuccess;
    //mapping sender => bool
    mapping(address => bool) public isRequestingTwoPhaseWithdraw;

    bytes32 constant SIGNING_WALLET_SIGNATURE =
        keccak256("Register(address key,string message,uint64 nonce)");
    bytes32 constant SIGNING_KEY_SIGNATURE =
        keccak256("SignKey(address account)");
    bytes32 constant WITHDRAW_SIGNATURE =
        keccak256(
            "Withdraw(address sender,address token,uint128 amount,uint64 nonce)"
        );
    bytes32 public constant ORDER_SIGNATURE =
        keccak256(
            "Order(address sender,uint128 size,uint128 price,uint64 nonce,uint8 productIndex,uint8 orderSide)"
        );

    receive() external payable {}

    modifier supportedToken(address token) {
        if (!supportedTokens.contains(token)) {
            revert(TOKEN_NOT_SUPPORTED);
        }
        _;
    }

    function _onlyGeneralAdmin() internal view {
        if (
            !accessContract.hasRole(
                accessContract.ADMIN_GENERAL_ROLE(),
                msg.sender
            )
        ) {
            revert(NOT_ADMIN_GENERAL);
        }
    }

    modifier onlyGeneralAdmin() {
        _onlyGeneralAdmin();
        _;
    }

    modifier isTwoPhaseWithdraw() {
        if (!isTwoPhaseWithdrawEnabled) {
            revert(NOT_ENABLED);
        }
        _;
    }

    function initialize(
        address _access,
        address _clearingService,
        address _spotEngine,
        address _perpEngine,
        address _book
    ) external initializer {
        __Ownable_init(msg.sender);
        __EIP712_init(NAME, VERSION);
        __ReentrancyGuard_init();
        if (
            _access == address(0) ||
            _clearingService == address(0) ||
            _spotEngine == address(0) ||
            _perpEngine == address(0) ||
            _book == address(0)
        ) {
            revert(INVALID_ADDRESS);
        }

        accessContract = Access(_access);
        clearingService = IClearingService(_clearingService);
        spotEngine = ISpot(_spotEngine);
        perpEngine = IPerp(_perpEngine);
        book = IOrderBook(_book);

        withdrawalRequestIDCounter = 0;
        isTwoPhaseWithdrawEnabled = false;
        executedTransactionCounter = 0;
        forceWithdrawalGracePeriodSecond = 60 * 60;
        feeRecipientAddress = CLAIM_FEE_RECIPIENT;
        canDeposit = true;
        canWithdraw = true;
        pauseBatchProcess = false;
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
    function getSupportedTokenList() public view returns (address[] memory) {
        uint8 length = uint8(supportedTokens.length());
        address[] memory tokenList = new address[](length);
        for (uint256 index = 0; index < length; index++) {
            tokenList[index] = supportedTokens.at(index);
        }
        return tokenList;
    }

    ///@inheritdoc IExchange
    function isSupportedToken(address token) external view returns (bool) {
        return supportedTokens.contains(token);
    }

    /**
     * @dev This function set two phase withdraw state.
     * @param _isTwoPhaseWithdrawEnabled state of 2 phase withdraw
     */
    function setTwoPhaseWithdraw(
        bool _isTwoPhaseWithdrawEnabled
    ) external onlyGeneralAdmin {
        isTwoPhaseWithdrawEnabled = _isTwoPhaseWithdrawEnabled;
    }

    function scaleNumberHelper(
        address token,
        uint128 amount
    ) internal view returns (uint128) {
        IERC20Extend product = IERC20Extend(token);
        uint256 amountToTransfer = (amount * 10 ** product.decimals()) / 1e18;
        return uint128(amountToTransfer);
    }

    ///@inheritdoc IExchange
    function deposit(
        address tokenAddress,
        uint128 amount
    ) external supportedToken(tokenAddress) {
        if (!canDeposit) {
            revert(NOT_ENABLED);
        }
        if (amount == 0) revert(INVALID_AMOUNT);
        IERC20Extend token = IERC20Extend(tokenAddress);
        uint256 amountToTransfer = scaleNumberHelper(tokenAddress, amount);
        token.safeTransferFrom(msg.sender, address(this), amountToTransfer);
        clearingService.deposit(msg.sender, amount, tokenAddress, spotEngine);
        int256 currentBalance = spotEngine.getBalance(tokenAddress, msg.sender);
        emit Deposit(tokenAddress, msg.sender, amount, uint256(currentBalance));
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
        uint256 amountToTransfer = scaleNumberHelper(tokenAddress, amount);
        IERC3009(tokenAddress).receiveWithAuthorization(
            depositor,
            address(this),
            amountToTransfer,
            validAfter,
            validBefore,
            nonce,
            signature
        );
        clearingService.deposit(depositor, amount, tokenAddress, spotEngine);
        int256 currentBalance = spotEngine.getBalance(tokenAddress, depositor);
        emit Deposit(tokenAddress, depositor, amount, uint256(currentBalance));
    }

    // function depositCrossChainSwap(
    //     address user,
    //     address tokenAddress,
    //     uint128 amount
    // ) external supportedToken(tokenAddress) {
    //     if (!canDeposit) {
    //         revert(NOT_ENABLED);
    //     }
    //     if (amount == 0) revert(INVALID_AMOUNT);
    //     IERC20Extend token = IERC20Extend(tokenAddress);
    //     //squid router contract will transfer token to this contract with 6 decimals
    //     uint256 scaledAmount = (amount * 1e18) / 10 ** token.decimals();
    //     token.safeTransferFrom(msg.sender, address(this), amount);
    //     clearingService.deposit(user, scaledAmount, tokenAddress, spotEngine);
    //     int256 currentBalance = spotEngine.getBalance(tokenAddress, user);
    //     emit Deposit(tokenAddress, user, amount, uint256(currentBalance));
    //     emit CrossChainDeposit(user, tokenAddress, amount);
    // }

    /**
     * @dev This function check if a signer is a signing wallet of a sender.
     * @param sender Sender address
     * @param signer Signer addresss
     */
    function isSigningWallet(
        address sender,
        address signer
    ) public view returns (bool) {
        return signingWallets[sender][signer];
    }

    /**
     * @dev This function disable a signing wallet.
     * @param sender Sender address
     * @param signer Signer addresss
     */
    function unregisterSigningWallet(
        address sender,
        address signer
    ) external onlyGeneralAdmin {
        signingWallets[sender][signer] = false;
    }

    /**
     * @dev This internal function verify signature of a signer. Revert if signature is invalid.
     * @param signer Signer address
     * @param digest Digest of the message
     * @param signature Signature of the message
     */
    function _verifySignature(
        address signer,
        bytes32 digest,
        bytes memory signature
    ) internal pure {
        if (ECDSA.recover(digest, signature) != signer) {
            revert(INVALID_SIGNATURE);
        }
    }

    /**
     * @dev This internal function verify nonce of a sender for add signing wallet. Revert if nonce is invalid.
     * @param sender Sender address
     * @param nonce Nonce of the sender
     */
    function _verifySigningNonce(address sender, uint64 nonce) internal view {
        if (usedNonces[sender][nonce]) {
            revert(INVALID_SIGNING_NONCE);
        }
    }

    /**
     * @dev This internal function verify nonce of a sender for withdraw. Revert if nonce is invalid.
     * @param sender Sender address
     * @param nonce Nonce of the sender
     */
    function _verifyWithdrawNonce(address sender, uint64 nonce) internal view {
        if (isWithdrawSuccess[sender][nonce]) {
            revert(INVALID_WITHDRAW_NONCE);
        }
    }

    ///@inheritdoc IExchange
    function processBatch(
        bytes[] calldata operations
    ) external onlyGeneralAdmin {
        uint256 length = operations.length;
        for (uint128 i = 0; i < length; ++i) {
            bytes calldata operation = operations[i];
            handleOperation(operation);
        }
    }

    /**
     * @dev This function handle a operation. Will revert if operation type is invalid.
     * Will change to internal after testing.
     * @param data Transaction data to handle
     * The first byte is operation type
     * The next 4 bytes is transaction ID
     * The rest is transaction data
     */
    function handleOperation(bytes calldata data) internal {
        require(!pauseBatchProcess, PAUSE_BATCH_PROCESS);
        //     1 byte is operation type
        //next 4 bytes is transaction ID
        OperationType operationType = OperationType(uint8(data[0]));
        uint32 transactionId = uint32(bytes4(abi.encodePacked(data[1:5])));
        if (transactionId != executedTransactionCounter) {
            revert(INVALID_TRANSACTION_ID);
        }
        executedTransactionCounter++;
        if (operationType == OperationType.MatchLiquidationOrders) {
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
            LibOrder.SignedOrder memory maker;
            LibOrder.SignedOrder memory taker;
            IOrderBook.Fee memory matchFee;
            IOrderBook.OrderHash memory digest;
            (
                maker.order,
                maker.signature,
                maker.signer,
                maker.isLiquidation,
                matchFee.maker
            ) = parseDataToOrder(data[5:169]);
            digest.maker = getOrderDigest(maker.order);

            (
                taker.order,
                taker.signature,
                taker.signer,
                taker.isLiquidation,
                matchFee.taker
            ) = parseDataToOrder(data[169:333]);
            uint128 takerSequencerFee = uint128(bytes16(data[333:349])); //16 bytes for takerSequencerFee
            digest.taker = getOrderDigest(taker.order);
            if (!taker.isLiquidation) {
                revert(NOT_LIQUIDATION_ORDER);
            }
            _verifySignature(maker.signer, digest.maker, maker.signature);
            if (!isSigningWallet(maker.order.sender, maker.signer)) {
                revert(NOT_SIGNING_WALLET);
            }

            require(
                maker.order.productIndex == taker.order.productIndex,
                INVALID_PRODUCT_ID
            );
            book.matchOrders(
                maker,
                taker,
                digest,
                maker.order.productIndex,
                takerSequencerFee,
                matchFee
            );
        } else if (operationType == OperationType.MatchOrders) {
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
            LibOrder.SignedOrder memory maker;
            LibOrder.SignedOrder memory taker;
            IOrderBook.Fee memory matchFee;
            IOrderBook.OrderHash memory digest;
            (
                maker.order,
                maker.signature,
                maker.signer,
                maker.isLiquidation,
                matchFee.maker
            ) = parseDataToOrder(data[5:169]);
            digest.maker = getOrderDigest(maker.order);
            _verifySignature(maker.signer, digest.maker, maker.signature);
            if (!isSigningWallet(maker.order.sender, maker.signer)) {
                revert(NOT_SIGNING_WALLET);
            }
            (
                taker.order,
                taker.signature,
                taker.signer,
                taker.isLiquidation,
                matchFee.taker
            ) = parseDataToOrder(data[169:333]);
            uint128 takerSequencerFee = uint128(bytes16(data[333:349])); //16 bytes for takerSequencerFee
            digest.taker = getOrderDigest(taker.order);
            _verifySignature(taker.signer, digest.taker, taker.signature);
            if (!isSigningWallet(taker.order.sender, taker.signer)) {
                revert(NOT_SIGNING_WALLET);
            }
            require(
                maker.order.productIndex == taker.order.productIndex,
                INVALID_PRODUCT_ID
            );
            book.matchOrders(
                maker,
                taker,
                digest,
                maker.order.productIndex,
                takerSequencerFee,
                matchFee
            );
        } else if (operationType == OperationType.UpdateFundingRate) {
            UpdateFundingRate memory txs = abi.decode(
                data[5:],
                (UpdateFundingRate)
            );
            if (
                lastFundingRateUpdate >= txs.lastFundingRateUpdateSequenceNumber
            ) {
                revert(INVALID_FUNDING_RATE_UPDATE);
            }
            int256 cumulativeFunding = perpEngine.updateFundingRate(
                txs.productIndex,
                txs.priceDiff
            );
            lastFundingRateUpdate = txs.lastFundingRateUpdateSequenceNumber;
            emit FundingRate(
                txs.productIndex,
                txs.priceDiff,
                cumulativeFunding,
                transactionId
            );
        } else if (operationType == OperationType.AssertOpenInterest) {
            AssertOpenInterest memory txs = abi.decode(
                data[5:],
                (AssertOpenInterest)
            );
            perpEngine.assertOpenInterest(txs.pairs);
        } else if (operationType == OperationType.CoverLossByInsuranceFund) {
            CoverLossByInsuranceFund memory txs = abi.decode(
                data[5:],
                (CoverLossByInsuranceFund)
            );
            clearingService.insuranceCoverLost(
                txs.account,
                txs.amount,
                spotEngine,
                txs.token
            );
        } else if (operationType == OperationType.AddSigningWallet) {
            AddSigningWallet memory txs = abi.decode(
                data[5:],
                (AddSigningWallet)
            );
            _addSigningWallet(
                txs.sender,
                txs.signer,
                txs.message,
                txs.nonce,
                txs.walletSignature,
                txs.signerSignature
            );
            emit SigningWallet(txs.sender, txs.signer, transactionId);
        } else if (operationType == OperationType.Withdraw) {
            Withdraw memory txs = abi.decode(data[5:], (Withdraw));
            if (!canWithdraw) {
                revert(NOT_ENABLED);
            }
            if (
                0 > txs.withdrawalSequencerFee ||
                txs.withdrawalSequencerFee > MAX_WITHDRAWAL_FEE_RATE
            ) {
                revert(INVALID_SEQUENCER_FEES);
            }
            bytes32 digest = _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        WITHDRAW_SIGNATURE,
                        txs.sender,
                        txs.token,
                        txs.amount,
                        txs.nonce
                    )
                )
            );
            _verifySignature(txs.sender, digest, txs.signature);
            _verifyWithdrawNonce(txs.sender, txs.nonce);
            int256 currentBalance = balanceOf(txs.sender, txs.token);
            if (
                txs.amount < MIN_WITHDRAW_AMOUNT ||
                currentBalance < int256(int128(txs.amount))
            ) {
                isWithdrawSuccess[txs.sender][txs.nonce] = false;
                emit WithdrawRejected(
                    txs.sender,
                    txs.nonce,
                    txs.amount,
                    currentBalance
                );
            } else {
                clearingService.withdraw(
                    txs.sender,
                    txs.amount,
                    txs.token,
                    spotEngine
                );
                IERC20Extend product = IERC20Extend(txs.token);
                uint256 amountToTransfer = scaleNumberHelper(
                    txs.token,
                    txs.amount - txs.withdrawalSequencerFee
                );
                sequencerFee += int256(int128(txs.withdrawalSequencerFee));
                product.safeTransfer(txs.sender, amountToTransfer);
                int256 afterBalance = balanceOf(txs.sender, txs.token);
                isWithdrawSuccess[txs.sender][txs.nonce] = true;
                emit WithdrawInfo(
                    txs.token,
                    txs.sender,
                    txs.amount,
                    uint256(afterBalance),
                    txs.nonce,
                    txs.withdrawalSequencerFee
                );
            }
        } else {
            revert(INVALID_OPERATION_TYPE);
        }
    }

    ///@inheritdoc IExchange
    function getBalanceInsuranceFund() external view returns (uint256) {
        return clearingService.getInsuranceFund();
    }

    function _addSigningWallet(
        address sender,
        address signer,
        string memory message,
        uint64 nonce,
        bytes memory walletSignature,
        bytes memory signerSignature
    ) internal {
        bytes32 digestSigningWallet = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    SIGNING_WALLET_SIGNATURE,
                    signer,
                    keccak256(abi.encodePacked(message)),
                    nonce
                )
            )
        );
        bytes32 digestSigningKey = _hashTypedDataV4(
            keccak256(abi.encode(SIGNING_KEY_SIGNATURE, sender))
        );
        _verifySigningNonce(sender, nonce); //verify nonce
        _verifySignature(sender, digestSigningWallet, walletSignature); //verify register signature
        _verifySignature(signer, digestSigningKey, signerSignature); //verify signing key signature
        signingWallets[sender][signer] = true;
        usedNonces[sender][nonce] = true;
    }

    ///@inheritdoc IExchange
    function balanceOf(
        address user,
        address token
    ) public view returns (int256) {
        int256 balance = spotEngine.getBalance(token, user);
        return balance;
    }

    /**
     * @dev This function is used to get the digest of an order.
     */
    function getOrderDigest(
        LibOrder.Order memory order
    ) internal view returns (bytes32) {
        return
            _hashTypedDataV4(
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

    /**
     * @dev This function is used to parse encoded data to an order.
     * @param data Data to parse
     */
    function parseDataToOrder(
        bytes calldata data
    )
        internal
        pure
        returns (
            LibOrder.Order memory,
            bytes memory signature,
            address signer,
            bool isLiquidation,
            int128 matchFee
        )
    {
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

    ///@inheritdoc IExchange
    function emergencyWithdrawEther(
        uint256 amount
    ) external onlyGeneralAdmin nonReentrant {
        if (amount == 0) revert(INVALID_AMOUNT);
        if (amount >= address(this).balance) {
            revert(INSUFFICIENT_BALANCE);
        }

        payable(msg.sender).transfer(amount);
    }

    ///@inheritdoc IExchange
    function emergencyWithdrawToken(
        address token,
        uint128 amount
    ) external onlyGeneralAdmin {
        IERC20Extend product = IERC20Extend(token);
        uint256 tokenBalance = product.balanceOf(address(this)) *
            10 ** (STANDARDIZED_TOKEN_DECIMAL - product.decimals());
        uint128 exceedAmount18D = uint128(
            tokenBalance - spotEngine.getTotalBalance(token)
        );
        uint256 withdrawAmount = MathHelper.min(amount, exceedAmount18D);
        withdrawAmount = scaleNumberHelper(token, uint128(withdrawAmount));
        spotEngine.setTotalBalance(token, withdrawAmount, false);
        product.safeTransfer(msg.sender, withdrawAmount);
    }

    /**
     * @dev This function is used to claim trading fees.
     */
    function claimTradingFees() external onlyGeneralAdmin {
        address token = book.getCollateralToken();
        int256 totalFee = book.claimTradingFees();
        IERC20Extend tokenExtend = IERC20Extend(token);
        uint256 amountToTransfer = scaleNumberHelper(
            token,
            uint128(uint256(totalFee))
        );
        tokenExtend.safeTransfer(
            feeRecipientAddress,
            uint256(amountToTransfer)
        );
        emit ClaimTradingFees(msg.sender, uint256(totalFee));
    }

    /**
     * @dev This function is used to claim sequencer fees.
     */
    function claimSequencerFees() external onlyGeneralAdmin {
        address token = book.getCollateralToken();
        int256 totalFee = sequencerFee;
        sequencerFee = 0;
        totalFee += book.claimSequencerFees();
        IERC20Extend tokenExtend = IERC20Extend(token);
        uint256 amountToTransfer = scaleNumberHelper(
            token,
            uint128(uint256(totalFee))
        );
        tokenExtend.safeTransfer(
            feeRecipientAddress,
            uint256(amountToTransfer)
        );
        emit ClaimSequencerFees(msg.sender, uint256(totalFee));
    }

    /**
     * @dev This function is used to deposit insurance fund.
     */
    function depositInsuranceFund(
        address token,
        uint256 amount
    ) external onlyGeneralAdmin {
        IERC20Extend product = IERC20Extend(token);
        uint256 amountToTransfer = scaleNumberHelper(token, uint128(amount));
        product.safeTransferFrom(msg.sender, address(this), amountToTransfer);
        clearingService.depositInsuranceFund(amount);
        emit DepositInsurance(token, amount);
    }

    /**
     * @dev This function is used to withdraw insurance fund.
     */
    function withdrawInsuranceFund(
        address token,
        uint256 amount
    ) external onlyGeneralAdmin {
        IERC20Extend product = IERC20Extend(token);
        uint256 amountToTransfer = scaleNumberHelper(token, uint128(amount));
        product.safeTransfer(msg.sender, amountToTransfer);
        clearingService.withdrawInsuranceFundEmergency(amount);
        emit WithdrawInsurance(token, amount);
    }

    /**
     * @dev This function is used to pause batch process.
     */
    function setPauseBatchProcess(
        bool _pauseBatchProcess
    ) external onlyGeneralAdmin {
        pauseBatchProcess = _pauseBatchProcess;
    }

    /**
     * @dev This function is used to pause deposit.
     */
    function setCanDeposit(bool _canDeposit) external onlyGeneralAdmin {
        canDeposit = _canDeposit;
    }

    ///@inheritdoc IExchange
    function prepareForceWithdraw(
        address token,
        uint128 amount,
        address sender,
        uint64 nonce,
        bytes calldata signature,
        uint128 withdrawalSequencerFee
    ) external isTwoPhaseWithdraw returns (uint256 requestID) {
        if (!canWithdraw) {
            revert(NOT_ENABLED);
        }
        if (isRequestingTwoPhaseWithdraw[sender]) {
            revert(REQUESTING_TWO_PHASE_WITHDRAW_NOT_ALLOWED);
        }
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(WITHDRAW_SIGNATURE, sender, token, amount, nonce)
            )
        );
        _verifyWithdrawNonce(sender, nonce);
        _verifySignature(sender, digest, signature);
        int256 currentBalance = balanceOf(sender, token);
        if (amount == 0) revert(INVALID_AMOUNT);
        if (currentBalance < int256(int128(amount))) {
            revert(INSUFFICIENT_BALANCE);
        }
        withdrawalRequestIDCounter++;
        requestID = withdrawalRequestIDCounter;
        withdrawalInfo[requestID] = WithdrawalInfo({
            token: token,
            amount: amount - withdrawalSequencerFee,
            requestTime: block.timestamp,
            scaledAmount18D: 0,
            user: sender,
            approved: false,
            productIndex: 0,
            isWithdrawSuccess: false
        });
        sequencerFee += int256(int128(withdrawalSequencerFee));
        isRequestingTwoPhaseWithdraw[sender] = true;
    }

    ///@inheritdoc IExchange
    function checkForceWithdraw(
        uint256 requestID,
        bool approved
    ) external onlyGeneralAdmin isTwoPhaseWithdraw {
        WithdrawalInfo memory info = withdrawalInfo[requestID];
        if (
            block.timestamp - info.requestTime <=
            forceWithdrawalGracePeriodSecond
        ) {
            revert(WITHDRAWAL_NOT_APPROVED);
        }
        info.approved = approved;
        withdrawalInfo[requestID] = info;
    }

    ///@inheritdoc IExchange
    function commitForceWithdraw(
        uint256 requestID
    ) external isTwoPhaseWithdraw {
        WithdrawalInfo storage info = withdrawalInfo[requestID];
        if (info.isWithdrawSuccess) {
            revert(WITHDRAWAL_NOT_APPROVED);
        }
        if (!info.approved) revert(WITHDRAWAL_NOT_APPROVED);
        if (
            block.timestamp - info.requestTime <=
            forceWithdrawalGracePeriodSecond
        ) {
            revert(WITHDRAWAL_NOT_APPROVED);
        }
        if (info.user != msg.sender) revert(NOT_OWNER);
        clearingService.withdraw(
            info.user,
            info.amount,
            info.token,
            spotEngine
        );
        IERC20Extend product = IERC20Extend(info.token);
        uint256 amountToTransfer = scaleNumberHelper(
            info.token,
            uint128(info.amount)
        );
        product.safeTransfer(info.user, amountToTransfer);
        info.isWithdrawSuccess = true;
        withdrawalInfo[requestID] = info;
        isRequestingTwoPhaseWithdraw[info.user] = false;
    }

    ///@inheritdoc IExchange
    function updateForceWithdrawalTime(
        uint256 _forceWithdrawalGracePeriodSecond
    ) external onlyGeneralAdmin {
        forceWithdrawalGracePeriodSecond = _forceWithdrawalGracePeriodSecond;
    }

    ///@inheritdoc IExchange
    function updateFeeRecipientAddress(
        address _feeRecipientAddress
    ) external onlyGeneralAdmin {
        if (_feeRecipientAddress == address(0)) {
            revert(INVALID_ADDRESS);
        }
        feeRecipientAddress = _feeRecipientAddress;
    }

    function getTradingFees() external view returns (int128) {
        return book.getTradingFees();
    }

    function getSequencerFees() external view returns (int256) {
        return sequencerFee + book.getSequencerFees();
    }

    function setCanWithdraw(bool _canWithdraw) external onlyGeneralAdmin {
        canWithdraw = _canWithdraw;
    }
}

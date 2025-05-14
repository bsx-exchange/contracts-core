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
import {IClearingService} from "./interfaces/IClearingService.sol";
import {IExchange, ILiquidation, ISwap} from "./interfaces/IExchange.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {IVaultManager} from "./interfaces/IVaultManager.sol";
import {Errors} from "./lib/Errors.sol";
import {MathHelper} from "./lib/MathHelper.sol";

import {AccountLogic} from "./lib/logic/AccountLogic.sol";
import {AdminLogic} from "./lib/logic/AdminLogic.sol";
import {BalanceLogic} from "./lib/logic/BalanceLogic.sol";
import {LiquidationLogic} from "./lib/logic/LiquidationLogic.sol";
import {OrderLogic} from "./lib/logic/OrderLogic.sol";
import {SignerLogic} from "./lib/logic/SignerLogic.sol";
import {SwapLogic} from "./lib/logic/SwapLogic.sol";
import {BSX_TOKEN, NATIVE_ETH} from "./share/Constants.sol";

/// @title Exchange contract
/// @notice This contract is entry point of the exchange
/// @dev This contract is upgradeable
contract Exchange is Initializable, EIP712Upgradeable, ExchangeStorage, IExchange {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;
    using MathHelper for uint128;
    using MathHelper for uint256;
    using MathHelper for int256;
    using MathHelper for int128;

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

    modifier notVault(address account) {
        if (_accounts[account].accountType == AccountType.Vault) {
            revert Errors.Exchange_VaultAddress();
        }
        _;
    }

    modifier notSubaccount(address account) {
        if (_accounts[account].accountType == AccountType.Subaccount) {
            revert Errors.Exchange_Subaccount();
        }
        _;
    }

    receive() external payable {}

    /// @inheritdoc IExchange
    function addSupportedToken(address token) external onlyRole(access.GENERAL_ROLE()) {
        return AdminLogic.addSupportedToken(clearingService, supportedTokens, token);
    }

    /// @inheritdoc IExchange
    function removeSupportedToken(address token) external onlyRole(access.GENERAL_ROLE()) {
        return AdminLogic.removeSupportedToken(supportedTokens, token);
    }

    /// @inheritdoc IExchange
    function registerVault(address vault, address feeRecipient, uint256 profitShareBps, bytes calldata signature)
        external
        onlyRole(access.GENERAL_ROLE())
    {
        if (_accounts[vault].accountType != AccountType.Main) {
            revert Errors.Exchange_InvalidAccountType(vault);
        }
        _accounts[vault].accountType = AccountType.Vault;
        access.getVaultManager().registerVault(vault, feeRecipient, profitShareBps, signature);

        emit RegisterVault(vault, feeRecipient, profitShareBps);
    }

    /// @inheritdoc IExchange
    function depositRaw(address recipient, address token, uint128 rawAmount) external payable {
        uint256 amount = token == NATIVE_ETH ? rawAmount : rawAmount.convertToScale(token);
        _deposit(recipient, token, amount, false);
    }

    /// @inheritdoc IExchange
    function deposit(address token, uint128 amount) external payable {
        _deposit(msg.sender, token, amount, false);
    }

    /// @inheritdoc IExchange
    function deposit(address recipient, address token, uint128 amount) external payable {
        _deposit(recipient, token, amount, false);
    }

    /// @inheritdoc IExchange
    function depositAndEarn(address token, uint128 amount) external {
        _deposit(msg.sender, token, amount, true);
    }

    /// @inheritdoc IExchange
    function depositMaxApproved(address recipient, address token, bool earn) external {
        uint256 rawAmount = IERC20(token).allowance(msg.sender, address(this));
        uint256 amount = rawAmount.convertToScale(token);
        _deposit(recipient, token, amount, earn);
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
    ) external {
        _depositWithAuthorization(token, depositor, amount, validAfter, validBefore, nonce, signature, false);
    }

    /// @inheritdoc IExchange
    function depositAndEarnWithAuthorization(
        address token,
        address depositor,
        uint128 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external onlyRole(access.GENERAL_ROLE()) {
        _depositWithAuthorization(token, depositor, amount, validAfter, validBefore, nonce, signature, true);
    }

    /// @inheritdoc IExchange
    function depositInsuranceFund(address token, uint256 amount) external onlyRole(access.GENERAL_ROLE()) {
        (uint256 roundDownAmount, uint256 amountToTransfer) = amount.roundDownAndConvertFromScale(token);
        if (roundDownAmount == 0 || amountToTransfer == 0) revert Errors.Exchange_ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amountToTransfer);
        clearingService.depositInsuranceFund(token, roundDownAmount);

        IClearingService.InsuranceFund memory insuranceFundBalance = clearingService.getInsuranceFundBalance();
        emit DepositInsuranceFund(token, roundDownAmount, insuranceFundBalance);
    }

    /// @inheritdoc IExchange
    function withdrawInsuranceFund(address token, uint256 amount) external onlyRole(access.GENERAL_ROLE()) {
        uint256 amountToTransfer = amount.convertFromScale(token);
        if (amount == 0 || amountToTransfer == 0) revert Errors.Exchange_ZeroAmount();

        clearingService.withdrawInsuranceFund(token, amount);
        IERC20(token).safeTransfer(msg.sender, amountToTransfer);

        IClearingService.InsuranceFund memory insuranceFundBalance = clearingService.getInsuranceFundBalance();
        emit WithdrawInsuranceFund(token, amount, insuranceFundBalance);
    }

    /// @inheritdoc IExchange
    function claimTradingFees() external onlyRole(access.GENERAL_ROLE()) {
        return AdminLogic.claimTradingFees(book, msg.sender, feeRecipientAddress);
    }

    /// @inheritdoc IExchange
    function claimSequencerFees() external onlyRole(access.GENERAL_ROLE()) {
        return AdminLogic.claimSequencerFees(_collectedFee, this, book, msg.sender, feeRecipientAddress);
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
        return LiquidationLogic.liquidateCollateralBatch(isLiquidationNonceUsed, this, params);
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
        SwapLogic.swapCollateralBatch(isSwapNonceUsed, this, params);
    }

    /// @inheritdoc ISwap
    function innerSwapWithPermit(SwapParams calldata params)
        external
        internalCall
        notVault(params.account)
        returns (uint256 amountOutX18)
    {
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
    function requestToken(address token, uint256 amount) external {
        if (msg.sender != address(clearingService)) {
            revert Errors.Unauthorized();
        }
        IERC20(token).safeTransfer(address(clearingService), amount);
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
        _addSigningWallet(AddSigningWallet(account, signer, message, nonce, walletSignature, signerSignature));
    }

    /// @inheritdoc IExchange
    function createSubaccount(address main, address subaccount, bytes memory mainSignature, bytes memory subSignature)
        external
        onlyRole(access.GENERAL_ROLE())
    {
        return AccountLogic.createSubaccount(_accounts, access, this, main, subaccount, mainSignature, subSignature);
    }

    /// @inheritdoc IExchange
    function coverLoss(address account, address payer, address token) external override returns (uint256 coverAmount) {
        if (msg.sender != address(access.getVaultManager())) {
            revert Errors.Unauthorized();
        }
        return BalanceLogic.coverLoss(BalanceLogic.BalanceEngine(clearingService, spotEngine), account, payer, token);
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
    function getInsuranceFundBalance() external view returns (IClearingService.InsuranceFund memory) {
        return clearingService.getInsuranceFundBalance();
    }

    /// @inheritdoc IExchange
    function getTradingFees() external view returns (IOrderBook.FeeCollection memory) {
        return book.getTradingFees();
    }

    /// @inheritdoc IExchange
    function getSequencerFees(address token) external view returns (uint256 fees) {
        address underlyingAsset = book.getCollateralToken();
        fees = _collectedFee[token];
        if (token == underlyingAsset) {
            fees += book.getSequencerFees().inUSDC.safeUInt256();
        } else if (token == BSX_TOKEN) {
            fees += book.getSequencerFees().inBSX.safeUInt256();
        }
    }

    /// @inheritdoc IExchange
    function hashTypedDataV4(bytes32 structHash) external view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }

    /// @inheritdoc IExchange
    function accounts(address account) external view returns (Account memory) {
        return _accounts[account];
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
    function getAccountType(address account) external view returns (AccountType) {
        return _accounts[account].accountType;
    }

    /// @inheritdoc IExchange
    function getSubaccounts(address main) external view returns (address[] memory) {
        return _accounts[main].subaccounts;
    }

    /// @inheritdoc IExchange
    function isSigningWallet(address sender, address signer) public view returns (bool) {
        return _signingWallets[sender][signer];
    }

    /// @inheritdoc IExchange
    function isSupportedToken(address token) external view returns (bool) {
        return supportedTokens.contains(token);
    }

    /// @inheritdoc IExchange
    function isVault(address account) public view returns (bool) {
        return access.getVaultManager().isRegistered(account);
    }

    /// @inheritdoc IExchange
    function isStakeVaultNonceUsed(address account, uint256 nonce) public view returns (bool) {
        return access.getVaultManager().isStakeNonceUsed(account, nonce);
    }

    /// @inheritdoc IExchange
    function isUnstakeVaultNonceUsed(address account, uint256 nonce) public view returns (bool) {
        return access.getVaultManager().isUnstakeNonceUsed(account, nonce);
    }

    function isNonceUsed(address account, uint256 nonce) public view override returns (bool) {
        return _isNonceUsed[account][nonce];
    }

    /// @dev Internal function to deposit tokens into the exchange
    function _deposit(address recipient, address token, uint256 amount, bool earn)
        internal
        enabledDeposit
        supportedToken(token)
        notVault(recipient)
        notSubaccount(recipient)
    {
        BalanceLogic.deposit(BalanceLogic.BalanceEngine(clearingService, spotEngine), recipient, token, amount);
        if (earn) {
            clearingService.earnYieldAsset(recipient, token, amount);
        }
    }

    /// @dev Internal function to deposit tokens into the exchange with authorization
    function _depositWithAuthorization(
        address token,
        address depositor,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature,
        bool earn
    ) internal enabledDeposit supportedToken(token) notVault(depositor) notSubaccount(depositor) {
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
        if (earn) {
            clearingService.earnYieldAsset(depositor, token, amount);
        }
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
            _matchOrders(data[1:]);
        } else if (operationType == OperationType.MatchLiquidationOrders) {
            _matchLiquidationOrders(data[1:]);
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
            AddSigningWallet memory params = abi.decode(data[5:], (AddSigningWallet));
            _addSigningWallet(params);
        } else if (operationType == OperationType.RegisterSubaccountSigner) {
            RegisterSubaccountSignerParams memory params = abi.decode(data[5:], (RegisterSubaccountSignerParams));
            _registerSubaccountSigner(params);
        } else if (operationType == OperationType.TransferToBSX1000) {
            TransferToBSX1000Params memory transferData = abi.decode(data[5:], (TransferToBSX1000Params));
            _transferToBSX1000(transferData);
        } else if (operationType == OperationType.Withdraw) {
            Withdraw memory withdrawData = abi.decode(data[5:], (Withdraw));
            _withdraw(withdrawData);
        } else if (operationType == OperationType.StakeVault) {
            StakeVaultParams memory stakeVaultData = abi.decode(data[5:], (StakeVaultParams));
            _stakeVault(stakeVaultData);
        } else if (operationType == OperationType.UnstakeVault) {
            UnstakeVaultParams memory unstakeVaultData = abi.decode(data[5:], (UnstakeVaultParams));
            _unstakeVault(unstakeVaultData);
        } else if (operationType == OperationType.Transfer) {
            TransferParams memory params = abi.decode(data[5:], (TransferParams));
            _transfer(params);
        } else if (operationType == OperationType.DeleteSubaccount) {
            DeleteSubaccountParams memory params = abi.decode(data[5:], (DeleteSubaccountParams));
            _deleteSubaccount(params);
        } else {
            revert Errors.Exchange_InvalidOperationType();
        }
    }

    /// @dev Handles matching normal orders
    function _matchOrders(bytes calldata data) internal {
        OrderLogic.matchOrders(_accounts, this, OrderLogic.OrderEngine(book, spotEngine), data);
    }

    /// @dev Handles matching liquidation orders
    function _matchLiquidationOrders(bytes calldata data) internal {
        OrderLogic.matchLiquidationOrders(_accounts, this, OrderLogic.OrderEngine(book, spotEngine), data);
    }

    /// @dev Handles a withdraw
    function _withdraw(Withdraw memory data) internal enabledWithdraw {
        if (isWithdrawNonceUsed[data.sender][data.nonce]) {
            revert Errors.Exchange_Withdraw_NonceUsed(data.sender, data.nonce);
        }
        isWithdrawNonceUsed[data.sender][data.nonce] = true;

        try BalanceLogic.withdraw(
            _accounts, _collectedFee, this, BalanceLogic.BalanceEngine(clearingService, spotEngine), data
        ) {
            emit WithdrawSucceeded(data.token, data.sender, data.nonce, data.amount, 0, data.withdrawalSequencerFee);
        } catch {
            emit WithdrawFailed(data.sender, data.nonce, 0, 0);
        }
    }

    /// @dev Handles a transfer between 2 accounts in the exchange
    function _transfer(TransferParams memory params) internal {
        address signer = _accounts[params.from].accountType == IExchange.AccountType.Subaccount
            ? _accounts[params.from].main
            : params.from;
        if (_isNonceUsed[signer][params.nonce]) {
            revert Errors.Exchange_NonceUsed(signer, params.nonce);
        }
        _isNonceUsed[signer][params.nonce] = true;

        try BalanceLogic.transfer(
            this, _accounts, BalanceLogic.BalanceEngine(clearingService, spotEngine), signer, params
        ) {
            emit Transfer(
                params.token,
                params.from,
                params.to,
                signer,
                params.nonce,
                params.amount.safeInt256(),
                ActionStatus.Success
            );
        } catch {
            emit Transfer(
                params.token,
                params.from,
                params.to,
                address(0),
                params.nonce,
                params.amount.safeInt256(),
                ActionStatus.Failure
            );
        }
    }

    function _transferToBSX1000(TransferToBSX1000Params memory params) internal {
        if (isTransferToBSX1000NonceUsed[params.account][params.nonce]) {
            revert Errors.Exchange_TransferToBSX1000_NonceUsed(params.account, params.nonce);
        }
        isTransferToBSX1000NonceUsed[params.account][params.nonce] = true;

        try BalanceLogic.transferToBSX1000(
            _accounts,
            this,
            IBSX1000x(access.getBsx1000()),
            BalanceLogic.BalanceEngine(clearingService, spotEngine),
            params
        ) returns (uint256 balance) {
            emit TransferToBSX1000(
                params.token, params.account, params.nonce, params.amount, balance, TransferToBSX1000Status.Success
            );
        } catch {
            emit TransferToBSX1000(
                params.token, params.account, params.nonce, params.amount, 0, TransferToBSX1000Status.Failure
            );
        }
    }

    /// @dev Call to vault manager to stake
    function _stakeVault(StakeVaultParams memory data) internal {
        IVaultManager vaultManager = access.getVaultManager();
        if (_isNonceUsed[data.account][data.nonce]) {
            revert Errors.Exchange_NonceUsed(data.account, data.nonce);
        }
        _isNonceUsed[data.account][data.nonce] = true;

        try vaultManager.stake(data.vault, data.account, data.token, data.amount, data.nonce, data.signature) returns (
            uint256 shares
        ) {
            emit StakeVault(
                data.vault, data.account, data.nonce, data.token, data.amount, shares, VaultActionStatus.Success
            );
        } catch {
            emit StakeVault(data.vault, data.account, data.nonce, data.token, data.amount, 0, VaultActionStatus.Failure);
        }
    }

    /// @dev Call to vault manager to unstake
    function _unstakeVault(UnstakeVaultParams memory data) internal {
        IVaultManager vaultManager = access.getVaultManager();
        if (_isNonceUsed[data.account][data.nonce]) {
            revert Errors.Exchange_NonceUsed(data.account, data.nonce);
        }
        _isNonceUsed[data.account][data.nonce] = true;

        try vaultManager.unstake(data.vault, data.account, data.token, data.amount, data.nonce, data.signature)
        returns (uint256 shares, uint256 fee, address feeRecipient) {
            emit UnstakeVault(
                data.vault,
                data.account,
                data.nonce,
                data.token,
                data.amount,
                shares,
                fee,
                feeRecipient,
                VaultActionStatus.Success
            );
        } catch {
            emit UnstakeVault(
                data.vault,
                data.account,
                data.nonce,
                data.token,
                data.amount,
                0,
                0,
                address(0),
                VaultActionStatus.Failure
            );
        }
    }

    function _deleteSubaccount(DeleteSubaccountParams memory params) internal {
        try AccountLogic.deleteSubaccount(_accounts, access, this, params) {
            emit DeleteSubaccount(params.main, params.subaccount, ActionStatus.Success);
        } catch {
            emit DeleteSubaccount(params.main, params.subaccount, ActionStatus.Failure);
        }
    }

    /// @dev Validates and authorizes a signer to sign on behalf of a sender.
    /// Supports adding a signing wallet for both EOA and smart contract.
    /// Smart contract signature validation follows ERC1271 standards.
    function _addSigningWallet(AddSigningWallet memory params) internal {
        return SignerLogic.registerSigner(isRegisterSignerNonceUsed, _signingWallets, this, params);
    }

    /// @dev Validates and authorizes a signer to place order on behalf of a subaccount.
    function _registerSubaccountSigner(RegisterSubaccountSignerParams memory params) internal {
        return SignerLogic.registerSubaccountSigner(_accounts, isRegisterSignerNonceUsed, _signingWallets, this, params);
    }
}

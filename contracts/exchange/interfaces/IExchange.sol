// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {TxStatus} from "../share/Enums.sol";
import {IClearingService} from "./IClearingService.sol";
import {ILiquidation} from "./ILiquidation.sol";
import {IOrderBook} from "./IOrderBook.sol";
import {ISwap} from "./ISwap.sol";

/// @title Exchange
/// @notice Entrypoint of the system
interface IExchange is ILiquidation, ISwap {
    /// @notice Emitted when a token is added to the supported tokens list
    /// @param token Token address which is added
    event SupportedTokenAdded(address indexed token);

    /// @notice Emitted when a token is removed from the supported tokens list
    /// @param token Token address which is removed
    event SupportedTokenRemoved(address indexed token);

    /// @dev Emitted when an account authorizes a signer to sign on its behalf
    event RegisterSigner(address indexed account, address indexed signer, uint64 nonce);

    /// @notice Emitted when a subaccount is created
    event CreateSubaccount(address indexed main, address indexed subaccount);

    /// @notice Emitted when a subaccount is deleted
    event DeleteSubaccount(address indexed main, address indexed subaccount, TxStatus status);

    /// @dev Emitted when a user deposits tokens to the exchange
    /// @param token Token address
    /// @param user  User address
    /// @param amount Deposit amount (in 18 decimals)
    /// @param balance Deprecated, always 0
    event Deposit(address indexed token, address indexed user, uint256 amount, uint256 balance);

    /// @dev Emitted when a user withdraws tokens from the exchange successfully.
    /// @param token Token address
    /// @param user Account address
    /// @param nonce Nonce of the withdrawal
    /// @param amount Withdraw amount (in 18 decimals)
    /// @param balance Deprecated, always 0
    /// @param withdrawalSequencerFee Sequencer fee of the withdrawal (in 18 decimals)
    event WithdrawSucceeded(
        address indexed token,
        address indexed user,
        uint64 indexed nonce,
        uint256 amount,
        uint256 balance,
        uint256 withdrawalSequencerFee
    );

    /// @dev Emitted when a user is rejected to withdraw tokens from the exchange
    /// `amount` and `balance` will be returned 0 if the withdrawal is rejected due to invalid signature
    /// @param user Account address
    /// @param nonce Nonce of the withdrawal
    /// @param amount Withdraw amount (in 18 decimals)
    /// @param balance Balance of account after withdraw (in 18 decimals)
    event WithdrawFailed(address indexed user, uint64 indexed nonce, uint128 amount, int256 balance);

    /// @dev Emitted when a user deposits tokens to the exchange
    /// @param token Token address
    /// @param from From address
    /// @param to To address
    /// @param signer Signer address who signed the transfer
    /// @param nonce Nonce of the transfer
    /// @param amount Deposit amount (in 18 decimals)
    /// @param status Transfer status
    event Transfer(
        address indexed token,
        address indexed from,
        address indexed to,
        address signer,
        uint256 nonce,
        int256 amount,
        TxStatus status
    );

    /// @dev Emitted when a user transfer collateral to BSX1000
    /// @param token Token address
    /// @param user Account address
    /// @param nonce Nonce of the transfer
    /// @param amount Transfer amount (in 18 decimals)
    /// @param balance Balance of account after transfer (in 18 decimals)
    /// @param status Transfer status
    event TransferToBSX1000(
        address indexed token, address indexed user, uint256 nonce, uint256 amount, uint256 balance, TxStatus status
    );

    /// @dev Emitted when referral rebate is paid
    /// @param referrer Referrer address
    /// @param amount Rebate amount
    /// @param isFeeInBSX Whether the fee is in BSX or not
    event RebateReferrer(address indexed referrer, uint256 amount, bool isFeeInBSX);

    /// @dev Emitted when maker is rebated
    /// @param maker Maker address
    /// @param amount Rebate amount
    /// @param isFeeInBSX Whether the fee is in BSX or not
    event RebateMaker(address indexed maker, uint256 amount, bool isFeeInBSX);

    /// @dev Emitted when the funding rate is updated.
    /// @param productIndex Product id
    /// @param diffPrice Premium funding rate
    /// @param cummulativeFundingRate Cumulative funding rate
    event UpdateFundingRate(uint8 indexed productIndex, int256 diffPrice, int256 cummulativeFundingRate);

    /// @dev Emitted when the insurance fund is deposited.
    /// @param token Token address
    /// @param depositAmount Deposit amount (in 18 decimals)
    /// @param insuranceFund Insurance fund after deposit (in 18 decimals)
    event DepositInsuranceFund(address token, uint256 depositAmount, IClearingService.InsuranceFund insuranceFund);

    /// @dev Emitted when the insurance fund is withdrawn.
    /// @param token Token address
    /// @param withdrawAmount Withdraw amount (in 18 decimals)
    /// @param insuranceFund Insurance fund after withdraw
    event WithdrawInsuranceFund(address token, uint256 withdrawAmount, IClearingService.InsuranceFund insuranceFund);

    /// @notice Emitted when trading fees are claimed
    event ClaimTradingFees(address indexed claimer, IOrderBook.FeeCollection fees);

    /// @notice Emitted when sequencer fees are claimed
    event ClaimSequencerFees(address indexed claimer, address indexed token, uint256 amount);

    /// @notice deprecated, use `WithdrawSucceeded` instead
    event WithdrawInfo(
        address indexed token,
        address indexed user,
        uint256 amount,
        uint256 balance,
        uint64 nonce,
        uint256 withdrawalSequencerFee
    );

    /// @notice deprecated, use `WithdrawFailed` instead
    event WithdrawRejected(address sender, uint64 nonce, uint128 withdrawAmount, int256 spotBalance);

    /// @notice Emitted when account is covered loss by another account
    event CoverLoss(address indexed lostAccount, address indexed payer, address indexed asset, uint256 coverAmount);

    /// @notice Emitted when a new vault is registered
    event RegisterVault(address indexed vault, address indexed feeRecipient, uint256 profitShareBps);

    enum AccountType {
        Main,
        Vault,
        Subaccount
    }

    enum AccountState {
        Active,
        Deleted
    }

    /// @notice Emitted then user stakes to vault
    event StakeVault(
        address indexed vault,
        address indexed account,
        uint256 indexed nonce,
        address token,
        uint256 amount,
        uint256 shares,
        TxStatus status
    );

    /// @notice Emitted then user unstakes from vault
    event UnstakeVault(
        address indexed vault,
        address indexed account,
        uint256 indexed nonce,
        address token,
        uint256 amount,
        uint256 shares,
        uint256 fee,
        address feeRecipient,
        TxStatus status
    );

    /// @notice All operation types in the exchange
    enum OperationType {
        MatchLiquidationOrders,
        MatchOrders,
        _DepositInsuranceFund, // deprecated
        UpdateFundingRate,
        _AssertOpenInterest, // deprecated
        CoverLossByInsuranceFund,
        _UpdateFeeRate, // deprecated
        _UpdateLiquidationFeeRate, // deprecated
        _ClaimFee, // deprecated
        _WithdrawInsuranceFundEmergency, // deprecated
        DeleteSubaccount,
        Transfer,
        AddSigningWallet,
        RegisterSubaccountSigner,
        Withdraw,
        TransferToBSX1000,
        StakeVault,
        UnstakeVault
    }

    struct TransferParams {
        address from;
        address to;
        address token;
        uint256 amount;
        uint256 nonce;
        bytes signature;
    }

    /// @notice Account information
    struct Account {
        address main;
        AccountType accountType;
        AccountState state;
        address[] subaccounts;
    }

    /// @notice Authorizes a wallet to sign on behalf of the sender
    struct AddSigningWallet {
        address sender;
        address signer;
        string message;
        uint64 nonce;
        bytes walletSignature;
        bytes signerSignature;
    }

    /// @notice Authorizes a signer to sign on behalf of the subaccount
    struct RegisterSubaccountSignerParams {
        address main;
        address subaccount;
        address signer;
        string message;
        uint64 nonce;
        bytes mainSignature;
        bytes signerSignature;
    }

    /// @notice Struct for transferring collateral to BSX1000
    struct TransferToBSX1000Params {
        address account;
        address token;
        uint256 amount;
        uint256 nonce;
        bytes signature;
    }

    /// @notice Withdraws tokens from the exchange
    struct Withdraw {
        address sender;
        address token;
        uint128 amount;
        uint64 nonce;
        bytes signature;
        uint128 withdrawalSequencerFee;
    }

    struct StakeVaultParams {
        address vault;
        address account;
        address token;
        uint256 amount;
        uint256 nonce;
        bytes signature;
    }

    struct UnstakeVaultParams {
        address vault;
        address account;
        address token;
        uint256 amount;
        uint256 nonce;
        bytes signature;
    }

    struct DeleteSubaccountParams {
        address main;
        address subaccount;
        bytes mainSignature;
    }

    /// @notice Adds the supported token. Only admin can call this function
    /// @dev Emits a {SupportedTokenAdded} event
    /// @param token Token address
    function addSupportedToken(address token) external;

    /// @notice Removes the supported token. Only admin can call this function
    /// @dev Emits a {SupportedTokenRemoved} event
    /// @param token Token address
    function removeSupportedToken(address token) external;

    /// @notice Covers the loss of account
    /// @dev Emits a {CoverLoss} event
    /// @param account Account with loss
    /// @param payer Payer address
    /// @param asset Asset address
    /// @return Cover amount
    function coverLoss(address account, address payer, address asset) external returns (uint256);

    /// @notice Creates a subaccount for the main account
    /// Main account is the owner of the subaccount and can transfer assets to the subaccount
    /// A main account can have multiple subaccounts, but a subaccount can only have one main account
    /// @dev Emits a {CreateSubaccount} event
    function createSubaccount(address main, address subaccount, bytes memory mainSignature, bytes memory subSignature)
        external;

    /// @notice Registers account as a vault
    /// @param vault Vault address
    /// @param feeRecipient Fee recipient address
    /// @param profitShareBps Profit share basis points (1 = 0.01%)
    /// @param signature Signature bytes signed by an EOA wallet or a contract wallet
    function registerVault(address vault, address feeRecipient, uint256 profitShareBps, bytes calldata signature)
        external;

    /// @notice Requests token transfer from the exchange
    /// @dev Emits a {RequestToken} event
    /// @param token Token address
    /// @param amount Amount of token (in token decimals)
    function requestToken(address token, uint256 amount) external;

    /// @notice Deposits token with scaled amount to the exchange
    /// @dev Emits a {Deposit} event
    /// @param token Token address
    /// @param amount Scaled amount of token, 18 decimals
    function deposit(address token, uint128 amount) external payable;

    /// @notice Deposits token with recipient with scaled amount to the exchange
    /// @dev Emits a {Deposit} event
    /// @param recipient Recipient address
    /// @param token Token address
    /// @param amount Scaled amount of token, 18 decimals
    function deposit(address recipient, address token, uint128 amount) external payable;

    /// @notice Deposits token with raw amount to the exchange
    /// @dev Emits a {Deposit} event
    /// @param recipient Recipient address
    /// @param token Token address
    /// @param rawAmount Raw amount of token (in token decimals)
    function depositRaw(address recipient, address token, uint128 rawAmount) external payable;

    /// @notice Deposits token to the exchange with authorization, following EIP-3009
    /// @dev Emits a {Deposit} event
    /// @param token  Token address
    /// @param depositor     Depositor address
    /// @param amount        Scaled amount of token, 18 decimals
    /// @param validAfter    The time after which this is valid (unix time)
    /// @param validBefore   The time before which this is valid (unix time)
    /// @param nonce         Unique nonce
    /// @param signature     Signature bytes signed by an EOA wallet or a contract wallet
    function depositWithAuthorization(
        address token,
        address depositor,
        uint128 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external;

    /// @notice Deposits the entire approved amount of a token to the exchange
    /// @dev Emits a {Deposit} event
    /// @param recipient Recipient address
    /// @param token Token address
    /// @param earn Whether to earn yield by depositing them into a vault
    function depositMaxApproved(address recipient, address token, bool earn) external;

    /// @notice Deposits tokens into the exchange and then earns yield by depositing them into a vault
    function depositAndEarn(address token, uint128 amount) external;

    /// @notice Deposits tokens into the exchange with authorization and
    /// then earns yield by depositing them into a vault
    function depositAndEarnWithAuthorization(
        address token,
        address depositor,
        uint128 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;

    /// @notice Submit batch of transactions to the exchange, only admin can call this function
    /// @param operations List of transactions
    function processBatch(bytes[] calldata operations) external;

    /// @notice Deposits token to insurance fund
    /// @dev Emits a {DepositInsurance} event
    /// @param token Token address
    /// @param amount Deposit amount (in 18 decimals)
    function depositInsuranceFund(address token, uint256 amount) external;

    /// @notice Withdraws token from insurance fund
    /// @dev Emits a {WithdrawInsurance} event
    /// @param token Token address
    /// @param amount Withdraw amount (in 18 decimals)
    function withdrawInsuranceFund(address token, uint256 amount) external;

    /// @notice Claims collected the trading fees
    /// @dev Emits a {ClaimTradingFees} event
    function claimTradingFees() external;

    /// @notice Claims collected the sequencer fees
    /// @dev Emits a {ClaimSequencerFees} event
    function claimSequencerFees() external;

    /// @notice Unregisters the signing wallet
    function unregisterSigningWallet(address account, address signer) external;

    /// @dev This function is used for admin to change the fee recipient address.
    function updateFeeRecipientAddress(address newFeeRecipient) external;

    /// @notice Sets the pause flag for the batch process, only admin can call this function
    function setPauseBatchProcess(bool pauseBatchProcess) external;

    /// @notice Sets the deposit flag, only admin can call this function
    function setCanDeposit(bool canDeposit) external;

    /// @notice Sets the withdraw flag, only admin can call this function
    function setCanWithdraw(bool canWithdraw) external;

    /// @notice Returns the account information
    function accounts(address account) external view returns (Account memory);

    /// @dev This function get the balance of user
    /// @param user User address
    /// @return Amount of token
    function balanceOf(address user, address token) external view returns (int256);

    /// @dev This function get the balance of insurance fund.
    /// @return Insurance fund balance
    function getInsuranceFundBalance() external view returns (IClearingService.InsuranceFund memory);

    /// @notice Gets the supported token list
    /// @return List of supported token
    function getSupportedTokenList() external view returns (address[] memory);

    /// @notice Gets the account type
    /// @param account Account address
    /// @return Account type
    function getAccountType(address account) external view returns (AccountType);

    /// @notice Gets the subaccounts of the main account
    /// @param main Main account address
    /// @return List of subaccounts
    function getSubaccounts(address main) external view returns (address[] memory);

    /// @notice Gets collected trading fees
    function getTradingFees() external view returns (IOrderBook.FeeCollection memory);

    /// @notice Gets collected sequencer fees
    /// @param token Token address
    function getSequencerFees(address token) external view returns (uint256);

    /// @notice Gets hash of typed data v4
    function hashTypedDataV4(bytes32 structHash) external view returns (bytes32);

    /// @dev Checks whether the signer is authorized to sign on behalf of the sender
    function isSigningWallet(address sender, address signer) external view returns (bool);

    /// @dev Checks whether the token is supported or not
    /// @param token Token address
    function isSupportedToken(address token) external view returns (bool);

    /// @dev Checks whether the account is a vault or not
    function isVault(address account) external view returns (bool);

    /// @notice Checks whether the nonce is used for staking to vault or not
    function isStakeVaultNonceUsed(address account, uint256 nonce) external view returns (bool);

    /// @notice Checks whether the nonce is used for unstaking from vault or not
    function isUnstakeVaultNonceUsed(address account, uint256 nonce) external view returns (bool);

    /// @notice Checks whether the nonce is used or not
    function isNonceUsed(address account, uint256 nonce) external view returns (bool);
}

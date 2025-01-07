// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ILiquidation} from "./ILiquidation.sol";
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

    /// @dev Emitted when a user transfer collateral to BSX1000
    /// @param token Token address
    /// @param user Account address
    /// @param nonce Nonce of the transfer
    /// @param amount Transfer amount (in 18 decimals)
    /// @param balance Balance of account after transfer (in 18 decimals)
    /// @param status Transfer status
    event TransferToBSX1000(
        address indexed token,
        address indexed user,
        uint256 nonce,
        uint256 amount,
        uint256 balance,
        TransferToBSX1000Status status
    );

    /// @dev Emitted when referral rebate is paid
    /// @param referrer Referrer address
    /// @param amount Rebate amount
    event RebateReferrer(address indexed referrer, uint256 amount);

    /// @dev Emitted when maker is rebated
    /// @param maker Maker address
    /// @param amount Rebate amount
    event RebateMaker(address indexed maker, uint256 amount);

    /// @dev Emitted when the funding rate is updated.
    /// @param productIndex Product id
    /// @param diffPrice Premium funding rate
    /// @param cummulativeFundingRate Cumulative funding rate
    event UpdateFundingRate(uint8 indexed productIndex, int256 diffPrice, int256 cummulativeFundingRate);

    /// @dev Emitted when the insurance fund is deposited.
    /// @param depositAmount Deposit amount (in 18 decimals)
    /// @param insuranceFund Insurance fund after deposit (in 18 decimals)
    event DepositInsuranceFund(uint256 depositAmount, uint256 insuranceFund);

    /// @dev Emitted when the insurance fund is withdrawn.
    /// @param withdrawAmount Withdraw amount (in 18 decimals)
    /// @param insuranceFund Insurance fund after withdraw (in 18 decimals)
    event WithdrawInsuranceFund(uint256 withdrawAmount, uint256 insuranceFund);

    /// @notice Emitted when trading fees are claimed
    event ClaimTradingFees(address indexed claimer, uint256 amount);

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

    /// @notice Emitted then user stakes to vault
    event StakeVault(
        address indexed vault,
        address indexed account,
        uint256 indexed nonce,
        address token,
        uint256 amount,
        uint256 shares,
        VaultActionStatus status
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
        VaultActionStatus status
    );

    enum TransferToBSX1000Status {
        Success,
        Failure
    }

    enum VaultActionStatus {
        Success,
        Failure
    }

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
        _SetMarketMaker, // deprecated
        _UpdateSequencerFee, // deprecated
        AddSigningWallet,
        _ClaimSequencerFees, // deprecated
        Withdraw,
        TransferToBSX1000,
        StakeVault,
        UnstakeVault
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

    /// @notice Registers account as a vault
    /// @param vault Vault address
    /// @param feeRecipient Fee recipient address
    /// @param profitShareBps Profit share basis points (1 = 0.01%)
    /// @param signature Signature bytes signed by an EOA wallet or a contract wallet
    function registerVault(address vault, address feeRecipient, uint256 profitShareBps, bytes calldata signature)
        external;

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

    /// @notice Submit batch of transactions to the exchange, only admin can call this function
    /// @param operations List of transactions
    function processBatch(bytes[] calldata operations) external;

    /// @notice Deposits token to insurance fund
    /// @dev Emits a {DepositInsurance} event
    /// @param amount Deposit amount (in 18 decimals)
    function depositInsuranceFund(uint256 amount) external;

    /// @notice Withdraws token from insurance fund
    /// @dev Emits a {WithdrawInsurance} event
    /// @param amount Withdraw amount (in 18 decimals)
    function withdrawInsuranceFund(uint256 amount) external;

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

    /// @dev This function get the balance of user
    /// @param user User address
    /// @return Amount of token
    function balanceOf(address user, address token) external view returns (int256);

    /// @dev This function get the balance of insurance fund.
    /// @return Amount of insurance fund
    function getInsuranceFundBalance() external view returns (uint256);

    /// @notice Gets the supported token list
    /// @return List of supported token
    function getSupportedTokenList() external view returns (address[] memory);

    /// @notice Gets collected trading fees
    function getTradingFees() external view returns (int128);

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
}

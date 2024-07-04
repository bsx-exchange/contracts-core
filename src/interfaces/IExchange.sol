// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title Exchange
/// @notice Entrypoint of the system
interface IExchange {
    /// @notice Emitted when a token is added to the supported tokens list
    /// @param token Token address which is added
    event SupportedTokenAdded(address indexed token);

    /// @notice Emitted when a token is removed from the supported tokens list
    /// @param token Token address which is removed
    event SupportedTokenRemoved(address indexed token);

    /// @dev Emitted when an account authorizes a wallet to sign on its behalf
    event RegisterSigningWallet(address indexed account, address indexed signer, uint64 nonce);

    /// @dev Emitted when an account authorizes a wallet to sign on its behalf
    event SigningWallet(address indexed sender, address indexed signer, uint32 indexed transactionId);

    /// @dev Emitted when a user deposits tokens to the exchange
    /// @param token Token address
    /// @param user  User address
    /// @param amount Deposit amount (in 18 decimals)
    /// @param balance Balance of user after deposit
    event Deposit(address indexed token, address indexed user, uint256 amount, uint256 balance);

    /// @dev Emitted when a user withdraws tokens from the exchange.
    /// @param token Token address
    /// @param user  Account address
    /// @param amount Withdraw amount (in 18 decimals)
    /// @param balance Balance of account after withdraw (in 18 decimals)
    /// @param nonce Nonce of the withdrawal
    /// @param withdrawalSequencerFee Sequencer fee of the withdrawal (in 18 decimals)
    event WithdrawInfo(
        address indexed token,
        address indexed user,
        uint256 amount,
        uint256 balance,
        uint64 nonce,
        uint256 withdrawalSequencerFee
    );

    /// @dev Emitted when a user is rejected to withdraw tokens from the exchange
    /// @param sender Account address
    /// @param nonce Nonce of the withdrawal
    /// @param withdrawAmount Withdraw amount (in 18 decimals)
    /// @param spotBalance Balance of account after withdraw (in 18 decimals)
    event WithdrawRejected(address sender, uint64 nonce, uint128 withdrawAmount, int256 spotBalance);

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
    /// @param transactionId Transaction id
    event FundingRate(
        uint8 indexed productIndex,
        int256 indexed diffPrice,
        int256 indexed cummulativeFundingRate,
        uint32 transactionId
    );

    /// @dev Emitted when the insurance fund is deposited.
    /// @param depositAmount Deposit amount (in 18 decimals)
    /// @param insuranceFund Insurance fund after deposit (in 18 decimals)
    event DepositInsuranceFund(uint256 depositAmount, uint256 insuranceFund);

    /// @dev Emitted when the insurance fund is withdrawn.
    /// @param withdrawAmount Withdraw amount (in 18 decimals)
    /// @param insuranceFund Insurance fund after withdraw (in 18 decimals)
    event WithdrawInsuranceFund(uint256 withdrawAmount, uint256 insuranceFund);

    event ClaimTradingFees(address indexed claimer, uint256 amount);
    event ClaimSequencerFees(address indexed claimer, uint256 amount);

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
        Invalid
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

    /// @notice Withdraws tokens from the exchange
    struct Withdraw {
        address sender;
        address token;
        uint128 amount;
        uint64 nonce;
        bytes signature;
        uint128 withdrawalSequencerFee;
    }

    /// @dev This struct is used for update funding rate.
    /// @param productIndex Product id
    /// @param priceDiff difference price between index price and mark price
    struct UpdateFundingRate {
        uint8 productIndex;
        int128 priceDiff;
        uint128 lastFundingRateUpdateSequenceNumber;
    }

    /// @notice decprecated
    struct WithdrawalInfo {
        address token;
        address user;
        uint256 amount;
        uint256 scaledAmount18D;
        uint256 requestTime;
        uint8 productIndex;
        bool approved;
        bool isWithdrawSuccess;
    }

    /// @notice Adds the supported token. Only admin can call this function
    /// @dev Emits a {SupportedTokenAdded} event
    /// @param token Token address
    function addSupportedToken(address token) external;

    /// @notice Removes the supported token. Only admin can call this function
    /// @dev Emits a {SupportedTokenRemoved} event
    /// @param token Token address
    function removeSupportedToken(address token) external;

    /// @notice Deposits token with scaled amount to the exchange
    /// @dev Emits a {Deposit} event
    /// @param tokenAddress Token address
    /// @param amount Scaled amount of token, 18 decimals
    function deposit(address tokenAddress, uint128 amount) external;

    /// @notice Deposits token with recipient with scaled amount to the exchange
    /// @dev Emits a {Deposit} event
    /// @param recipient Recipient address
    /// @param tokenAddress Token address
    /// @param amount Scaled amount of token, 18 decimals
    function deposit(address recipient, address tokenAddress, uint128 amount) external;

    /// @notice Deposits token with raw amount to the exchange
    /// @dev Emits a {Deposit} event
    /// @param recipient Recipient address
    /// @param token Token address
    /// @param rawAmount Raw amount of token (in token decimals)
    function depositRaw(address recipient, address token, uint128 rawAmount) external;

    /// @notice Deposits token to the exchange with authorization, following EIP-3009
    /// @dev Emits a {Deposit} event
    /// @param tokenAddress  Token address
    /// @param depositor     Depositor address
    /// @param amount        Scaled amount of token, 18 decimals
    /// @param validAfter    The time after which this is valid (unix time)
    /// @param validBefore   The time before which this is valid (unix time)
    /// @param nonce         Unique nonce
    /// @param signature     Signature bytes signed by an EOA wallet or a contract wallet
    function depositWithAuthorization(
        address tokenAddress,
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

    /// @dev This function get the amount of insurance fund.
    /// @return Amount of insurance fund
    function getBalanceInsuranceFund() external view returns (uint256);

    /// @notice Gets the supported token list
    /// @return List of supported token
    function getSupportedTokenList() external view returns (address[] memory);

    /// @notice Gets collected trading fees
    function getTradingFees() external view returns (int128);

    /// @notice Gets collected sequencer fees
    function getSequencerFees() external view returns (int256);

    /// @dev Checks whether the signer is authorized to sign on behalf of the sender
    function isSigningWallet(address sender, address signer) external view returns (bool);

    /// @dev Checks whether the token is supported or not
    /// @param token Token address
    function isSupportedToken(address token) external view returns (bool);
}

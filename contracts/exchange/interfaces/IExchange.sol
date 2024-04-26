// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;
import "../lib/LibOrder.sol";
import "./ISpot.sol";
import "./IPerp.sol";

interface IExchange {
    /**
     * @dev Emitted when a user deposits tokens to the exchange.s
     * @param token Token address
     * @param user  User address
     * @param amount Number of tokens
     * @param balance Balance of user after deposit
     */
    event Deposit(
        address indexed token,
        address indexed user,
        uint256 amount,
        uint256 balance
    );
    /**
     * @dev Emitted when a user withdraws tokens from the exchange.
     * @param token Token address
     * @param user  User address
     * @param amount Number of tokens
     * @param balance Balance of user after withdraw
     */
    event WithdrawInfo(
        address indexed token,
        address indexed user,
        uint256 amount,
        uint256 balance,
        uint64 nonce,
        uint256 withdrawalSequencerFee
    );
    /**
     * @dev Emitted when admin add the supported token.
     * @param token Token addresss
     */
    event SupportedTokenAdded(address indexed token);
    /**
     * @dev Emitted when admin remove the supported token.
     * @param token Token addresss
     */
    event SupportedTokenRemoved(address indexed token);
    /**
     * @dev Emitted when the insurance fund is deposited.
     * @param token Token addresss
     * @param amount Amount of token
     */
    event DepositInsurance(address indexed token, uint256 amount);
    /**
     * @dev Emitted when the funding rate is updated.
     * @param productIndex Product id
     * @param diffPrice Premium funding rate
     */
    event FundingRate(
        uint8 indexed productIndex,
        int256 indexed diffPrice,
        int256 indexed cummulativeFundingRate,
        uint32 transactionId
    );
    /**
     * @dev Emitted when user force withdraw.
     */
    event PrepareForceWithdraw(
        address indexed user,
        address indexed tokenAddress,
        uint256 amount
    );
    /**
     * @dev Emitted when the insurance fund is withdrawn.
     */
    event WithdrawInsurance(address indexed token, uint256 amount);
    event SigningWallet(
        address indexed sender,
        address indexed signer,
        uint32 indexed transactionId
    );
    event UpdateFee(
        uint8 indexed feeType,
        uint256 makerFeeRate,
        uint256 takerFeeRate,
        uint32 transactionId
    );
    event UpdateLiquidationFee(
        uint256 liquidationFeeRate,
        uint32 transactionId
    );
    event ClaimSequencerFee(
        address indexed token,
        int256 amount,
        uint32 transactionId
    );
    event UpdateSequencerFeeNumber(
        uint256 takerSequencerFee,
        uint256 withdrawalSequencerFee,
        uint32 transactionId
    );
    event WithdrawRejected(
        address sender,
        uint64 nonce,
        uint128 withdrawAmount,
        int256 spotBalance
    );
    event ClaimTradingFees(address indexed claimer, uint256 amount);
    event ClaimSequencerFees(address indexed claimer, uint256 amount);
    /**
     * @dev This enum is used to indicate the type of transaction.
     * It is used to distinguish between different types of transactions of the submitters.
     */
    enum OperationType {
        MatchLiquidationOrders,
        MatchOrders,
        DepositInsuranceFund,
        UpdateFundingRate,
        AssertOpenInterest,
        CoverLossByInsuranceFund,
        UpdateFeeRate,
        UpdateLiquidationFeeRate,
        ClaimFee,
        WithdrawInsuranceFundEmergency,
        SetMarketMaker,
        UpdateSequencerFee,
        AddSigningWallet,
        ClaimSequencerFees,
        Withdraw,
        Invalid
    }
    /**
     * @dev This struct is used for update funding rate.
     * @param productIndex Product id
     * @param priceDiff difference price between index price and mark price
     */
    struct UpdateFundingRate {
        uint8 productIndex;
        int128 priceDiff;
        uint128 lastFundingRateUpdateSequenceNumber;
    }
    /**
     * @dev This struct is used for assert open interest.
     * @param pairs List of open interest pairs. Includes token address and open interest.
     */
    struct AssertOpenInterest {
        IPerp.OpenInterestPair[] pairs;
    }
    /**
     * @dev This struct is used for match orders in case of liquidation.
     * @param maker Maker order like a normal order
     * @param taker Taker order like a normal order
     */
    struct LiquidateAccountMatchOrders {
        LibOrder.Order maker;
        LibOrder.Order taker;
    }
    /**
     * @dev This struct is used for submit transaction of cover loss by insurance fund.
     * @param account Account addresss
     */
    struct CoverLossByInsuranceFund {
        address account;
        address token;
        uint256 amount;
    }
    /**
     * @dev This struct is used for submit the two phase withdrawal.
     * @param token Token address
     * @param amount Amount of token
     * @param user User address
     * @param requestTime Request time of withdrawal (unix timestamp)
     * @param approved default is true, if admin reject this withdrawal, it will be false
     */
    struct WithdrawalInfo {
        address token;
        address user;
        uint256 amount;
        uint256 scaledAmount18D; //deprecated
        uint256 requestTime;
        uint8 productIndex; //deprecated
        bool approved;
        bool isWithdrawSuccess;
    }
    /**
     * @dev This struct is used for submit transaction of update fee rate.
     * @param feeType Fee type
     * @param makerFeeRate Maker fee rate
     * @param takerFeeRate Taker fee rate
     */
    struct UpdateFeeRate {
        uint8 feeType;
        uint128 makerFeeRate;
        uint128 takerFeeRate;
    }
    /**
     * @dev This struct is used for submit transaction of update liquidation fee rate.
     * @param liquidationFeeRate Liquidation fee rate
     */
    struct UpdateLiquidationFeeRate {
        uint128 liquidationFeeRate;
    }
    /**
     * @dev This struct is used for submit transaction of set market maker.
     * @param marketMakers List of market maker
     * @param isMarketMaker Is market maker, true or false
     */
    struct SetMarketMaker {
        address[] marketMakers;
        bool isMarketMaker;
    }
    /**
     * @dev This struct is used for submit transaction of update max funding rate.
     * @param maxFundingRate Max funding rate
     */
    struct UpdateMaxFundingRate {
        uint256 maxFundingRate;
    }
    struct AddSigningWallet {
        address sender;
        address signer;
        string message;
        uint64 nonce;
        bytes walletSignature;
        bytes signerSignature;
    }
    struct UpdateSequencerFee {
        uint128 takerSequencerFee;
        uint128 withdrawalSequencerFee;
    }
    struct Withdraw {
        address sender;
        address token;
        uint128 amount;
        uint64 nonce;
        bytes signature;
        uint128 withdrawalSequencerFee;
    }
    /**
     * @dev This function add the supported token. Only admin can call this function.
     * This function will add the token to the supported token list, and set the initial price.
     * Emits a {SupportedTokenAdded} event.
     * @param token Token address
     */
    function addSupportedToken(address token) external;
    /**
     * @dev This function remove the supported token. Only admin can call this function.
     * Emits a {SupportedTokenRemoved} event.
     * @param token Token address
     */
    function removeSupportedToken(address token) external;
    /**
     * @dev This function get the supported token list.
     * @return List of supported token
     */
    function getSupportedTokenList() external view returns (address[] memory);
    /**
     * @dev This function check the token is supported or not.
     * @param token Token address
     * @return True if token is supported
     */
    function isSupportedToken(address token) external view returns (bool);
    /**
     * @dev This function deposit token to exchange. User must approve token to exchange before call this function.
     * @param tokenAddress Token address
     * @param amount Amount of token
     * emits a {Deposit} event.
     */
    function deposit(address tokenAddress, uint128 amount) external;
    /**
     * @dev This function deposit token to exchange. User must approve token to exchange before call this function.
     * @param tokenAddress  Token address
     * @param depositor     Depositor address
     * @param amount        Amount of token
     * @param validAfter    The time after which this is valid (unix time)
     * @param validBefore   The time before which this is valid (unix time)
     * @param nonce         Unique nonce
     * @param signature     Signature bytes signed by an EOA wallet or a contract wallet
     * emits a {Deposit} event.
     */
    function depositWithAuthorization(
        address tokenAddress,
        address depositor,
        uint128 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external;
    /**
     * @dev This function is used to submit transactions to the exchange. Only admin can call this function.
     * @param operations List of transactions
     */
    function processBatch(bytes[] calldata operations) external;
    /**
     * @dev This function get the amount of insurance fund.
     * @return Amount of insurance fund
     */
    function getBalanceInsuranceFund() external view returns (uint256);
    /**
     * @dev This function get the balance of user
     * @param user User address
     * @return Amount of token
     */
    function balanceOf(
        address user,
        address token
    ) external view returns (int256);
    /**
     * @dev This function is used for emergency withdraw Ether from exchange. Only admin can call this function.
     * @param amount Amount of token
     */
    function emergencyWithdrawEther(uint256 amount) external;
    /**
     * @dev This function is used for emergency withdraw token from exchange. Only admin can call this function.
     * @param token Token address
     * @param amount Amount of token
     */
    function emergencyWithdrawToken(address token, uint128 amount) external;
    /**
     * @notice This function is WIP.
     * @dev This function is used for user when they want to withdraw their funds from the exchange.
     * This function will require the user to wait for a period of time before they can withdraw their funds.
     * @param token Token address
     * @param amount Amount of token
     * @param sender The account owner
     * @param nonce The nonce when singe this process.
     * @param signature The signature when singe this process.
     * @return requestID
     */
    function prepareForceWithdraw(
        address token,
        uint128 amount,
        address sender,
        uint64 nonce,
        bytes memory signature,
        uint128 withdrawalSequencerFee
    ) external returns (uint256 requestID);
    /**
     * @notice This function is WIP.
     * @dev This function is used for admin to check the force withdraw request.
     * @param requestID The request ID
     * @param approved True if admin approve this request
     */
    function checkForceWithdraw(uint256 requestID, bool approved) external;
    /**
     * @notice This function is WIP.
     * @dev This function is used for user to commit the force withdraw request.
     * This function will transfer the funds to the user.
     * User need to wait for a period of time before they can withdraw their funds.
     * @param requestID The request ID
     */
    function commitForceWithdraw(uint256 requestID) external;
    /**
     * @dev This function is used for admin to change the force withdraw grace period.
     * @param _forceWithdrawalGracePeriodSecond The force withdrawal grace period in second
     */
    function updateForceWithdrawalTime(
        uint256 _forceWithdrawalGracePeriodSecond
    ) external;
    /**
     * @dev This function is used for admin to change the fee recipient address.
     * @param _feeRecipientAddress The fee recipient address
     */
    function updateFeeRecipientAddress(address _feeRecipientAddress) external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Access} from "../../exchange/access/Access.sol";

/// @notice Interface for the BSX1000xs contract
interface IBSX1000x {
    /*//////////////////////////////////////////////////////////////////////////
                                    STRUCTS & ENUMS
    //////////////////////////////////////////////////////////////////////////*/
    enum ClosePositionReason {
        Normal,
        Liquidation,
        TakeProfit
    }

    enum PositionStatus {
        NotExist, // default
        Open,
        Closed,
        TakeProfit,
        Liquidated
    }

    // Struct representing the balance of an account
    struct Balance {
        uint256 available;
        uint256 locked;
    }

    // Struct representing a position
    struct Position {
        PositionStatus status;
        uint32 productId;
        uint128 margin;
        uint128 leverage;
        int128 size; // positive for long, negative for short
        uint128 openPrice;
        uint128 closePrice;
        uint128 takeProfitPrice;
        uint128 liquidationPrice;
    }

    // Struct representing an order
    struct Order {
        uint32 productId;
        address account;
        uint256 nonce;
        uint128 leverage;
        uint128 margin;
        int128 size; // positive for long, negative for short
        uint128 price;
        uint128 takeProfitPrice;
        uint128 liquidationPrice;
        int256 fee;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the amount is zero
    error ZeroAmount();

    /// @notice Thrown when the nonce for an authorizing signer is used
    error AuthorizeSigner_UsedNonce(address account, uint256 nonce);

    /// @notice Thrown when the order with the same nonce already exists
    error PositionExisted(address account, uint256 nonce);

    /// @notice Thrown when the position with the nonce does not exist
    error PositionNotOpening(address account, uint256 nonce);

    /// @notice Thrown when leverage is exceeded the maximum allowed
    error ExceededMaxLeverage();

    /// @notice Thrown when the notional amount exceeds the maximum allowed
    error ExceededNotionalAmount();

    /// @notice Thrown when the order fee is invalid
    error InvalidOrderFee();

    /// @notice Thrown when the reason for closing the position is invalid
    error InvalidClosePositionReason();

    /// @notice Thrown when the nonce for a withdrawal is used
    error Withdraw_UsedNonce(address account, uint256 nonce);

    /// @notice Thrown when the nonce of transfer collateral to exchange is used
    error TransferToExchange_UsedNonce(address account, uint256 nonce);

    /// @notice Thrown when the withdrawal fee exceeds the maximum allowed
    error ExceededMaxWithdrawalFee();

    /// @notice Thrown when the credit amount is larger than the margin
    error InvalidCredit();

    /// @notice Thrown when the signature is invalid
    /// @param account The account address associated with the invalid signature
    error InvalidSignature(address account);

    /// @notice Thrown when the recovered signer does not match the expected signer
    /// @param recoveredSigner The recovered signer from the signature
    /// @param expectedSigner The expected signer
    error InvalidSignerSignature(address recoveredSigner, address expectedSigner);

    /// @notice Thrown when the product ID in the order does not match the product ID in the position
    error ProductIdMismatch();

    /// @notice Thrown when the target profit price is exceeded the maximum allowed
    error InvalidTakeProfitPrice();

    /// @notice Thrown when the liquidation price is exceeded the maximum allowed
    error InvalidLiquidationPrice();

    /// @notice Thrown when the close price is invalid
    error InvalidClosePrice();

    /// @notice Thrown when the PnL of the order is invalid
    error InvalidPnl();

    /// @notice Thrown when the account balance is insufficient
    error InsufficientAccountBalance();

    /// @notice Thrown when the fund balance is insufficient
    error InsufficientFundBalance();

    /// @notice Thrown when the isolated fund balance is insufficient
    error InsufficientIsolatedFundBalance(uint256 productId);

    /// @notice Thrown when the isolated fund is disabled
    error IsolatedFundDisabled();

    /// @notice Thrown when the signer of an order is not authorized
    /// @param account The account address
    /// @param signer The unauthorized signer
    error UnauthorizedSigner(address account, address signer);

    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/
    /// @dev Emitted when a signer is authorized
    /// @param account The account address that authorizes the signer
    /// @param signer The authorized signer
    event AuthorizeSigner(address indexed account, address indexed signer, uint256 nonce);

    /// @dev Emitted when a signer is unauthorized
    /// @param account The account address that unauthorizes the signer
    /// @param signer The unauthorized signer
    event UnauthorizeSigner(address indexed account, address indexed signer);

    /// @dev Emitted when a user deposits tokens to the exchange
    /// @param account The account address
    /// @param amount The deposited amount (in 18 decimals)
    /// @param balance The user's balance after the deposit (in 18 decimals)
    event Deposit(address indexed account, uint256 amount, uint256 balance);

    /// @dev Emitted when withdrawal succeeds
    /// @param account The account address
    /// @param nonce The nonce of the withdrawal
    /// @param amount The withdrawn amount (in 18 decimals)
    /// @param fee The withdrawal fee (in 18 decimals)
    /// @param balance The user's balance after the withdrawal (in 18 decimals)
    event WithdrawSucceeded(
        address indexed account, uint256 indexed nonce, uint256 amount, uint256 fee, uint256 balance
    );

    /// @dev Emitted when transfer collateral to BSX exchange contract
    /// @param account The account address
    /// @param nonce The nonce of the transfer
    /// @param amount The transferred amount (in 18 decimals)
    /// @param balance The user's balance after the transfer (in 18 decimals)
    event TransferToExchange(address indexed account, uint256 indexed nonce, uint256 amount, uint256 balance);

    /// @dev Emitted when a position is opened
    /// @param productId The product ID
    /// @param account The account address
    /// @param nonce The nonce of the order
    /// @param margin The margin of the order
    /// @param leverage The leverage of the order
    /// @param price The price of the order
    /// @param size The size of the order, positive for long, negative for short
    /// @param fee The fee of the order
    /// @param credit The discount for the order margin
    event OpenPosition(
        uint32 indexed productId,
        address indexed account,
        uint256 indexed nonce,
        uint128 margin,
        uint128 leverage,
        uint128 price,
        int128 size,
        int256 fee,
        uint256 credit
    );

    /// @dev Emitted when a position is closed
    /// @param productId The product ID
    /// @param account The account address
    /// @param nonce The nonce of the openning order
    /// @param realizedPnl The final profit or loss of the order
    /// @param pnl The profit or loss of the order
    /// @param fee The fee of the order
    /// @param reason The reason for closing the position
    event ClosePosition(
        uint32 indexed productId,
        address indexed account,
        uint256 indexed nonce,
        int256 realizedPnl,
        int256 pnl,
        int256 fee,
        ClosePositionReason reason
    );

    /// @dev Emitted when depositing into fund
    /// @param amount The deposited amount (in 18 decimals)
    /// @param fundBalance The fund balance after the deposit (in 18 decimals)
    event DepositFund(uint256 amount, uint256 fundBalance);

    /// @dev Emitted when withdrawing from fund
    /// @param amount The withdrawn amount (in 18 decimals)
    /// @param fundBalance The fund balance after the withdrawal (in 18 decimals)
    event WithdrawFund(uint256 amount, uint256 fundBalance);

    event OpenIsolatedFund(uint256 productId);

    event CloseIsolatedFund(uint256 productId);

    event DepositIsolatedFund(uint256 productId, uint256 amount, uint256 balance);

    /*//////////////////////////////////////////////////////////////////////////
                                    FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/
    /// @notice Deposit collateral to the exchange
    /// @param amount The amount to deposit (in 18 decimals)
    function deposit(uint256 amount) external;

    /// @notice Deposit collateral to an account in the exchange
    /// @param account The account address
    /// @param amount The amount to deposit (in 18 decimals)
    function deposit(address account, uint256 amount) external;

    /// @notice Deposit collateral to an account in the exchange
    /// @param account The account address to deposit
    /// @param token Token address to deposit
    /// @param amount Raw amount of token (in token decimals)
    function depositRaw(address account, address token, uint256 amount) external;

    /// @notice Deposit collateral to the exchange with authorization
    /// @param account The account address
    /// @param amount The amount to deposit (in 18 decimals)
    /// @param validAfter The timestamp after which the authorization is valid (in seconds)
    /// @param validBefore The timestamp before which the authorization is valid (in seconds)
    /// @param nonce The nonce of the authorization
    /// @param signature The signature of the authorization
    function depositWithAuthorization(
        address account,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;

    /// @notice Transfer collateral to the exchange
    /// @param account The account address
    /// @param amount The amount to transfer (in 18 decimals)
    /// @param nonce The nonce of the transfer
    /// @param signature The signature of the transfer
    function transferToExchange(address account, uint256 amount, uint256 nonce, bytes memory signature) external;

    /// @notice Withdraw collateral from the exchange
    /// @param account The account address
    /// @param amount The amount to withdraw (in 18 decimals)
    /// @param fee The withdrawal fee (in 18 decimals)
    /// @param nonce The nonce of the withdrawal
    /// @param signature The signature of the withdrawal
    function withdraw(address account, uint256 amount, uint256 fee, uint256 nonce, bytes memory signature) external;

    /// @notice Open isolated fund for a product
    function openIsolatedFund(uint32 productId) external;

    /// @notice Close and move the isolated fund to the general fund
    function closeIsolatedFund(uint32 productId) external;

    /// @notice Deposit to the isolated fund
    function depositIsolatedFund(uint32 productId, uint256 amount) external;

    /// @notice Deposit fund to the exchange
    /// @param amount The amount to deposit (in 18 decimals)
    function depositFund(uint256 amount) external;

    /// @notice Withdraw fund from the exchange
    /// @param amount The amount to withdraw (in 18 decimals)
    function withdrawFund(uint256 amount) external;

    /// @notice Opens a position
    /// @param order The order information
    /// @param signature The signature of the order from the authorized signer
    function openPosition(Order calldata order, bytes memory signature) external;

    /// @notice Opens a position
    /// @param order The order information
    /// @param credit The discount for the order margin
    /// @param signature The signature of the order from the authorized signer
    function openPosition(Order calldata order, uint256 credit, bytes memory signature) external;

    /// @notice Closes a position
    /// @param productId The product ID
    /// @param account The account address
    /// @param nonce The nonce of the openning order
    /// @param closePrice The price to close the position
    /// @param fee The fee of the order
    /// @param signature The signature of the order from the authorized signer
    function closePosition(
        uint32 productId,
        address account,
        uint256 nonce,
        uint128 closePrice,
        int256 pnl,
        int256 fee,
        bytes memory signature
    ) external;

    /// @notice Forces close a position when the price reaches take profit or liquidation price
    /// @param productId The product ID
    /// @param account The account address
    /// @param nonce The nonce of the openning order
    /// @param fee The fee of the order
    /// @param reason The reason for closing the position
    function forceClosePosition(
        uint32 productId,
        address account,
        uint256 nonce,
        int256 pnl,
        int256 fee,
        ClosePositionReason reason
    ) external;

    /// @notice Checks if the signer is authorized for a specific account
    /// @dev Queries the main exchange contract for authorization status
    /// @param account The account address to check for authorization
    /// @param signer The signer address to verify
    /// @return True if the signer is authorized for the account, otherwise false
    function isAuthorizedSigner(address account, address signer) external view returns (bool);

    /// @notice Returns the access control contract
    function access() external view returns (Access);

    /// @notice Returns the collateral token
    function collateralToken() external view returns (IERC20);

    /// @notice Returns the general fund balance used to pay profits for winning trades
    function generalFund() external view returns (uint256);

    /// @notice Returns the isolated fund balance used to pay profits for winning trades in isolated products
    /// @param productId The product ID
    /// @return enable Whether the isolated fund is enabled
    /// @return fund The isolated fund balance
    function getIsolatedFund(uint32 productId) external view returns (bool enable, uint256 fund);

    /// @notice Returns total amount of all isolated funds
    function getTotalIsolatedFunds() external view returns (uint256);

    /// @notice Returns all isolated product IDs
    function getIsolatedProducts() external view returns (uint256[] memory);

    /// @notice Returns the balance of an account
    function getBalance(address account) external view returns (Balance memory);

    /// @notice Returns the position information
    function getPosition(address account, uint256 nonce) external view returns (Position memory);

    /// @notice Checks if the nonce is used for withdrawal or not
    function isWithdrawNonceUsed(address account, uint256 nonce) external view returns (bool);
}

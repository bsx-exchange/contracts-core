// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IClearinghouse} from "./IClearinghouse.sol";
import {IOrderbook} from "./IOrderbook.sol";
import {IPerpEngine} from "./IPerpEngine.sol";
import {ISpotEngine} from "./ISpotEngine.sol";

/// @title Exchange
/// @notice Entrypoint of the system
interface IExchange {
    /// @dev This struct is used for submit the two phase withdrawal.
    /// @param token Token address
    /// @param amount Amount of token
    /// @param user User address
    /// @param requestTime Request time of withdrawal (unix timestamp)
    /// @param approved default is true, if admin reject this withdrawal, it will be false
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

    /*//////////////////////////////////////////////////////////////////////////
                               NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Add supported token
    /// @param token Token Address
    function addSupportedToken(address token) external;

    /// @notice Remove supported token
    /// @param token Token Address
    function removeSupportedToken(address token) external;

    /// @notice Get supported token list
    /// @return address[] List of supported tokens
    function getSupportedTokenList() external view returns (address[] memory);

    /// @notice Check if a token is supported
    /// @param token Token Address
    /// @return bool True if token is supported
    function isSupportedToken(address token) external view returns (bool);

    /// @notice Deposit token to the exchange
    /// @dev payer and recipient are msg sender
    /// @param token Token address
    /// @param amount Standardized amount of token (18 decimals)
    function deposit(address token, uint128 amount) external;

    /// @notice Deposit token to the exchange
    /// @dev payer is msg sender, recipient is specified
    /// @param recipient Recipient address
    /// @param token Token address
    /// @param amount Standardized amount of token (18 decimals)
    function deposit(address recipient, address token, uint128 amount) external;

    /// @notice Deposit token to the exchange
    /// @dev payer is msg sender, recipient is specified
    /// @param token Token address
    /// @param rawAmount Token amount (token decimals)
    function depositRaw(address recipient, address token, uint256 rawAmount) external;

    /// @notice Deposit token to the exchange with authorization using ERC3009
    /// @param token Token address
    /// @param depositor Depositor address
    /// @param amount Standardized amount of token (18 decimals)
    /// @param validAfter The time after which this is valid (unix time)
    /// @param validBefore The time before which this is valid (unix time)
    /// @param nonce Unique nonce
    /// @param signature Signature bytes signed by an EOA wallet or a contract wallet
    function depositWithAuthorization(
        address token,
        address depositor,
        uint128 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;

    /// @notice Submit a batch of operations to the exchange
    /// @dev Only authorized addresses can call this function
    /// @param operations List of operations
    function processBatch(bytes[] calldata operations) external;

    /// @notice Claim collected trading fees
    /// @dev It get all collected trading fees from orderbook and set it to 0
    function claimCollectedTradingFees() external;

    /// @notice Claim collected sequencer fees
    /// @dev It get all collected sequencer fees from orderbook and exchange and set them to 0
    function claimCollectedSequencerFees() external;

    /// @notice Deposit collateral token for insurance fund
    /// @param amount Standardized amount of token (18 decimals)
    function depositInsuranceFund(uint256 amount) external;

    /// @notice Withdraw collateral token from insurance fund
    /// @param amount Standardized amount of token (18 decimals)
    function withdrawInsuranceFund(uint256 amount) external;

    /// @notice Update fee recipient
    /// @param feeRecipient New fee recipient address
    function updateFeeRecipient(address feeRecipient) external;

    /// @notice Pause processing batch of operations
    function pauseProcessBatch() external;

    /// @notice Unpause processing batch of operations
    function unpauseProcessBatch() external;

    /// @notice Enable withdraw
    function enableWithdraw() external;

    /// @notice Disable withdraw
    function disableWithdraw() external;

    /// @notice Enable deposit
    function enableDeposit() external;

    /// @notice Disable deposit
    function disableDeposit() external;

    /*//////////////////////////////////////////////////////////////////////////
                                 CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Get collected trading fees
    /// @dev Include collected sequencer fees from orderbook and exchange
    /// @return Collected sequencer fees
    function getCollectedSequencerFees() external view returns (uint256);

    /// @notice Get the clearinghouse contract
    /// @return IClearinghouse
    function clearinghouse() external view returns (IClearinghouse);

    /// @notice Get the orderbook contract
    /// @return IOrderbook
    function orderbook() external view returns (IOrderbook);

    /// @notice Get the spot engine contract
    /// @return ISpotEngine
    function spotEngine() external view returns (ISpotEngine);

    /// @notice Get the perpetual engine contract
    /// @return IPerpEngine
    function perpEngine() external view returns (IPerpEngine);
}

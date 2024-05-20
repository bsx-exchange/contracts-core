// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

/// @title Errors
/// @notice Library containing all custom errors the protocol may revert with.
library Errors {
    /*//////////////////////////////////////////////////////////////////////////
                                      GENERICS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when setting the zero address
    error ZeroAddress();

    /// @notice Thrown when setting the zero amount
    error ZeroAmount();

    /*//////////////////////////////////////////////////////////////////////////
                                      GATEWAY
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when `msg.sender` is not authorized
    error Gateway_Unauthorized();

    /*//////////////////////////////////////////////////////////////////////////
                                      EXCHANGE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when adding a token that is already supported
    error Exchange_TokenAlreadySupported(address token);

    /// @notice Thrown when token is not supported
    error Exchange_TokenNotSupported(address token);

    /// @notice Thrown when deposit is disabled
    error Exchange_DisabledDeposit();

    /// @notice Thrown when withdraw is disabled
    error Exchange_DisabledWithdraw();

    /// @notice Thrown when the operation type is invalid
    error Exchange_InvalidOperation();

    /// @notice Thrown when transaction id does not match current id
    /// @param invalidTransactionId The invalid transaction id
    /// @param currentTransactionId The current transaction id
    error Exchange_InvalidTransactionId(uint32 invalidTransactionId, uint32 currentTransactionId);

    /// @notice Thrown when cumulative funding rate id does not match current id
    /// @param fundingRateId Submitted funding rate id
    /// @param currentFundingRateId Current funding rate id
    error Exchange_InvalidFundingRateId(uint256 fundingRateId, uint256 currentFundingRateId);

    /// @notice Thrown when signer is different from recovered signer
    /// @param recoveredSigner Recovered signer from signature
    /// @param expectedSigner Expected signer
    error Exchange_InvalidSigner(address recoveredSigner, address expectedSigner);

    /// @notice Thrown when signer of order is not authorized
    /// @param account Account address
    /// @param signer Unauthorized signer
    error Exchange_UnauthorizedSigner(address account, address signer);

    /// @notice Thrown when processing a batch of operations is paused
    error Exchange_PausedProcessBatch();

    /// @notice Thrown when depositting or withdrawing insurance fund with invalid token
    error Exchange_NotCollateralToken();

    /// @notice Thrown when product id of orders do not match
    error Exchange_ProductIdMismatch();

    /// @notice Thrown when matching liquidated orders in non-liquidation mode
    error Exchange_LiquidatedOrder();

    /// @notice Thrown when matching non-liquidated orders in liquidation mode
    error Exchange_NotLiquidatedOrder();

    /// @notice Thrown when submitted withdraw fee exceeds maximum withdraw fee
    error Exchange_ExceededMaxWithdrawFee();

    /// @notice Thrown when authorizing signer with used nonce
    error Exchange_AuthorizeSigner_UsedNonce(address account, uint64 nonce);

    /// @notice Thrown when withdrawing with used nonce
    error Exchange_Withdraw_UsedNonce(address account, uint64 nonce);

    /*//////////////////////////////////////////////////////////////////////////
                                      ORDERBOOK
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when using a nonce that has already been used
    error Orderbook_UsedNonce(address account, uint64 nonce);

    /// @notice Thrown when exceeding the maximum trading fee
    error Orderbook_ExceededMaxTradingFee();

    /// @notice Thrown when exceeding the maximum sequencer fee
    error Orderbook_ExceededMaxSequencerFee();

    /// @notice Thrown when referral fee is greater than total fee
    error Orderbook_InvalidReferralFee();

    /// @notice Thrown when the order is invalid
    error Orderbook_InvalidOrder();

    /// @notice Thrown when the price of the order is invalid
    error Orderbook_InvalidPrice();
}

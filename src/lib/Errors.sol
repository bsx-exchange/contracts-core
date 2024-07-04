// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title Errors
/// @notice Library containing all custom errors the protocol may revert with.
library Errors {
    /*//////////////////////////////////////////////////////////////////////////
                                      GENERICS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when setting the zero address
    error ZeroAddress();

    /// @notice Thrown when `msg.sender` is not authorized
    error Unauthorized();

    /*//////////////////////////////////////////////////////////////////////////
                                      EXCHANGE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when setting the zero amount
    error Exchange_ZeroAmount();

    /// @notice Thrown when deposit is disabled
    error Exchange_DisabledDeposit();

    /// @notice Thrown when withdraw is disabled
    error Exchange_DisabledWithdraw();

    /// @notice Thrown when depositting or withdrawing insurance fund with invalid token
    error Exchange_NotCollateralToken();

    /// @notice Thrown when adding a token that is already supported
    error Exchange_TokenAlreadySupported(address token);

    /// @notice Thrown when token is not supported
    error Exchange_TokenNotSupported(address token);

    /// @notice Thrown when processing a batch of operations is paused
    error Exchange_PausedProcessBatch();

    /// @notice Thrown when the operation type is invalid
    error Exchange_InvalidOperationType();

    /// @notice Thrown when transaction id does not match current id
    /// @param invalidTransactionId The invalid transaction id
    /// @param expectedTransactionId The expected transaction id
    error Exchange_InvalidTransactionId(uint32 invalidTransactionId, uint32 expectedTransactionId);

    /// @notice Thrown when product id of orders do not match
    error Exchange_ProductIdMismatch();

    /// @notice Thrown when matching liquidated orders in non-liquidation mode
    /// @param transactionId Id of the transaction
    error Exchange_LiquidatedOrder(uint32 transactionId);

    /// @notice Thrown when matching non-liquidated orders in liquidation mode
    /// @param transactionId Id of the transaction
    error Exchange_NotLiquidatedOrder(uint32 transactionId);

    /// @notice Thrown when maker is liquidated in liquidation mode
    /// @param transactionId Id of the transaction
    error Exchange_MakerLiquidatedOrder(uint32 transactionId);

    /// @notice Thrown when cumulative funding rate sequence number is not greater than current one
    /// @param fundingRateSeqNumber Submitted sequence number of funding rate
    /// @param currentFundingRateSeqNumber Current sequence number of funding rate
    error Exchange_InvalidFundingRateSequenceNumber(uint256 fundingRateSeqNumber, uint256 currentFundingRateSeqNumber);

    /// @notice Throw when signature is invalid
    /// @param signer Signer address
    error Exchange_InvalidSignature(address signer);

    /// @notice Thrown when signer is different from recovered signer
    /// @param recoveredSigner Recovered signer from signature
    /// @param expectedSigner Expected signer
    error Exchange_InvalidSignerSignature(address recoveredSigner, address expectedSigner);

    /// @notice Thrown when signer of order is not authorized
    /// @param account Account address
    /// @param signer Unauthorized signer
    error Exchange_UnauthorizedSigner(address account, address signer);

    /// @notice Thrown when submitted withdraw fee exceeds maximum withdraw fee
    /// @param fee Submitted withdraw fee
    /// @param maxFee Maximum withdraw fee
    error Exchange_ExceededMaxWithdrawFee(uint128 fee, uint128 maxFee);

    /// @notice Thrown when submitted rebate rate exceeds maximum rebate rate
    /// @param rate Submitted rebate rate
    /// @param maxRate Maximum rebate rate
    error Exchange_ExceededMaxRebateRate(uint16 rate, uint16 maxRate);

    /// @notice Thrown when adding signing wallet with used nonce
    error Exchange_AddSigningWallet_UsedNonce(address account, uint64 nonce);

    /// @notice Thrown when withdrawing with used nonce
    error Exchange_Withdraw_NonceUsed(address account, uint64 nonce);

    /*//////////////////////////////////////////////////////////////////////////
                                    CLEARING SERVICE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when setting the zero amount
    error ClearingService_ZeroAmount();

    /// @notice Thrown when insufficient fund in insurance fund
    /// @param amount Requested amount
    /// @param fund Current fund
    error ClearingService_InsufficientFund(uint256 amount, uint256 fund);

    /// @notice Thrown when account has no loss
    error ClearingService_NoLoss(address account, int256 balance);

    /*//////////////////////////////////////////////////////////////////////////
                                      ORDERBOOK
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when using a nonce that has already been used
    error Orderbook_NonceUsed(address account, uint64 nonce);

    /// @notice Thrown when exceeding the maximum trading fee
    error Orderbook_ExceededMaxTradingFee();

    /// @notice Thrown when exceeding the maximum sequencer fee
    error Orderbook_ExceededMaxSequencerFee();

    /// @notice Thrown when exceeding the maximum liquidation fee
    error Orderbook_ExceededMaxLiquidationFee();

    /// @notice Thrown when maker and taker address are the same
    error Orderbook_OrdersWithSameAccounts();

    /// @notice Thrown when the order is invalid
    error Orderbook_OrdersWithSameSides();

    /// @notice Thrown when order price is invalid
    error Orderbook_InvalidOrderPrice();
}

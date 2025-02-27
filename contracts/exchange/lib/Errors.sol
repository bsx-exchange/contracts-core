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

    /// @notice Thrown when signature is invalid
    error InvalidSignature(address account);

    /*//////////////////////////////////////////////////////////////////////////
                                      EXCHANGE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when caller is not this contract
    error Exchange_InternalCall();

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

    /// @notice Thrown when msg.value is not equal to deposit amount
    error Exchange_InvalidEthAmount();

    /// @notice Thrown when insufficient ETH is sent
    error Exchange_InsufficientEth();

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

    /// @notice Thrown when transferring to BSX1000 with used nonce
    error Exchange_TransferToBSX1000_NonceUsed(address account, uint256 nonce);

    /// @notice Thrown when transferring to BSX1000 with invalid token
    error Exchange_TransferToBSX1000_InvalidToken(address transferredToken, address expectedToken);

    /// @notice Thrown when transferring to BSX1000 with insufficient balance
    error Exchange_TransferToBSX1000_InsufficientBalance(address account, int256 balance, uint256 transferAmount);

    /// @notice Thrown when account balance in not positive
    error Exchange_Liquidation_InvalidBalance(address account, address token, int256 balance);

    /// @notice Thrown when exceeded balance to liquidate
    error Exchange_Liquidation_ExceededBalance(address account, address token, int256 balance, uint256 amountIn);

    /// @notice Thrown when asset is not whitelisted
    error Exchange_Liquidation_InvalidAsset(address asset);

    /// @notice Thrown when empty commands submitted to Universal Router
    error Exchange_UniversalRouter_EmptyCommand();

    /// @notice Thrown when commands submitted to Universal Router are not whitelisted
    /// Valid commands include V3_SWAP_EXACT_IN, V3_SWAP_EXACT_OUT, V2_SWAP_EXACT_IN, V2_SWAP_EXACT_OUT
    error Exchange_UniversalRouter_InvalidCommand(uint256 command);

    /// @notice Thrown when liquidating with used nonce
    error Exchange_Liquidation_NonceUsed(address account, uint256 nonce);

    /// @notice Thrown when empty executions submitted to Universal Router
    error Exchange_Liquidation_EmptyExecution();

    /// @notice Thrown when exceeding maximum liquidation fee pips
    error Exchange_Liquidation_ExceededMaxLiquidationFeePips(uint256 feePips);

    /// @notice Thrown when swapping with used nonce
    error Exchange_Swap_NonceUsed(address account, uint256 nonce);

    /// @notice Thrown when swapping with invalid asset
    error Exchange_Swap_InvalidAsset();

    /// @notice Thrown when swapping with same asset
    error Exchange_Swap_SameAsset();

    /// @notice Thrown when requested amount exceeds the balance
    error Exchange_Swap_ExceededBalance(address account, address token, uint256 amountX18, int256 balanceX18);

    /// @notice Thrown when swap fee exceeds the maximum fee
    error Exchange_Swap_ExceededMaxFee(uint256 feeX18, uint256 maxFeeX18);

    /// @notice Thrown when swap amount in mismatch
    error Exchange_Swap_AmountInMismatch(uint256 swappedRawAmountIn, uint256 requestRawAmountIn);

    /// @notice Thrown when swap amount exceeds the maximum amount
    error Exchange_Swap_AmountOutTooLittle(uint256 amountOutX18, uint256 minAmountOutX18);

    /// @notice Thrown when interacting with vault address
    error Exchange_VaultAddress();

    /// @notice Thrown when account has no loss with a collateral token
    error Exchange_AccountNoLoss(address account, address token);

    /// @notice Thrown when account has insufficient balance
    error Exchange_AccountInsufficientBalance(address account, address token, int256 balance, uint256 amount);

    /*//////////////////////////////////////////////////////////////////////////
                                    CLEARING SERVICE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when setting the zero amount
    error ClearingService_ZeroAmount();

    /// @notice Thrown when invalid token
    error ClearingService_InvalidToken(address token);

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

    /*//////////////////////////////////////////////////////////////////////////
                                      SPOT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when supply of token is exceeded cap
    error ExceededCap(address token);

    /*//////////////////////////////////////////////////////////////////////////
                                    VAULT MANAGER
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when vault is already registered
    error Vault_AlreadyRegistered(address vault);

    /// @notice Thrown when vault is not registered
    error Vault_NotRegistered(address vault);

    /// @notice Thrown when vault address is invalid
    error Vault_InvalidVaultAddress(address vault);

    /// @notice Thrown when fee recipient is invalid
    error Vault_InvalidFeeRecipient(address vault, address feeRecipient);

    /// @notice Thrown when profit share basis points is invalid
    error Vault_InvalidProfitShareBps(address vault, uint256 profitShareBps);

    /// @notice Thrown when token is not the same as asset in vault
    error Vault_InvalidToken(address token, address asset);

    /// @notice Thrown when registering vault with not zero balance
    error Vault_NotZeroBalance(address vault, address token, int256 balance);

    /// @notice Thrown when vault is negative balance
    error Vault_NegativeBalance();

    /// @notice Thrown when stake nonce is used
    error Vault_Stake_UsedNonce(address account, uint256 nonce);

    /// @notice Thrown when unstake nonce is used
    error Vault_Unstake_UsedNonce(address account, uint256 nonce);

    /// @notice Thrown when stake amount exceeds current balance
    error Vault_Stake_InsufficientBalance(address account, int256 balance, uint256 requestAmount);

    /// @notice Thrown when unstake amount exceeds current shares
    error Vault_Unstake_InsufficientShares(address account, uint256 shares, uint256 requestShares);

    /// @notice Thrown when vault has insufficient assets to cover loss
    error Vault_CoverLoss_InsufficientAmount(address vault, address account, uint256 expectedAmount, uint256 amount);
}

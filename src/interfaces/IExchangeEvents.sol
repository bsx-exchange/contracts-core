// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title Events emitted by an exchange
/// @dev All amounts are standardized to 18 decimals
/// @notice Contains all events emitted by the exchange
interface IExchangeEvents {
    /// @notice Emitted when a token is added to the supported tokens list
    /// @param token Token address
    event AddSupportedToken(address token);

    /// @notice Emitted when a token is removed from the supported tokens list
    /// @param token Token address
    event RemoveSupportedToken(address token);

    /// @notice Emitted when account authorizes a signer to execute orders
    /// @param account Account address authorized to execute orders
    /// @param signer Signer address is authorized to execute orders
    /// @param transactionId Transaction id of this operation
    event AuthorizeSigner(address indexed account, address signer, uint32 transactionId);

    /// @notice Emitted when deposit token to the exchange
    /// @param account Account address
    /// @param token Token address
    /// @param amount Deposit amount
    /// @param balance Account balance after deposit
    event Deposit(address account, address token, uint256 amount, int256 balance);

    /// @notice Emitted when funding rate is cumulated
    /// @param productId Product id
    /// @param premiumRate New premium rate
    /// @param cumulativeFundingRate Cumulative funding rate after cumulating
    /// @param transactionId Transaction id of this operation
    event CumulateFundingRate(
        uint8 indexed productId, int256 premiumRate, int256 cumulativeFundingRate, uint32 transactionId
    );

    /// @notice Emitted when withdraw token from the exchange is successful
    /// @param account Account address
    /// @param token Token address
    /// @param amount Withdraw amount
    /// @param fee Withdraw fee
    /// @param balance Account balance after withdraw
    event Withdraw(address indexed account, address indexed token, uint256 amount, uint128 fee, int256 balance);

    /// @notice Emitted when withdraw token from the exchange is rejected
    /// @param account Account address
    /// @param token Token address
    /// @param amount Withdraw amount
    /// @param balance Current account balance
    event WithdrawRejected(address indexed account, address indexed token, uint256 amount, int256 balance);

    /// @notice Emitted when collected trading fees are claimed
    /// @param caller Caller address
    /// @param amount Amount of fees claimed
    event ClaimCollectedTradingFees(address caller, uint256 amount);

    /// @notice Emitted when collected sequencer fees are claimed
    /// @param caller Caller address
    /// @param amount Amount of fees claimed
    event ClaimCollectedSequencerFees(address caller, uint256 amount);

    /// @notice Emitted when deposit insurance fund
    /// @param amount Deposit amount
    event DepositInsuranceFund(uint256 amount);

    /// @notice Emitted when withdraw insurance fund
    /// @param amount Withdraw amount
    event WithdrawInsuranceFund(uint256 amount);
}

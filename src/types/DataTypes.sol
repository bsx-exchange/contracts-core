// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

/// @dev Admin roles in access control contract
enum Role {
    GENERAL_ADMIN,
    TRADING_ADMIN
}

/// @dev Types of engines in the exchange
enum EngineType {
    SPOT,
    PERP
}

/// @dev Order side of the order
enum OrderSide {
    LONG,
    SHORT
}

/// @dev All operation types in the exchange
enum OperationType {
    MatchLiquidatedOrders,
    MatchOrders,
    DepositInsuranceFund,
    CumulateFundingRate,
    AssertOpenInterest, // deprecated
    CoverLossWithInsuranceFund,
    UpdateFeeRate, // deprecated
    UpdateLiquidationFeeRate, // deprecated
    ClaimFee, // deprecated
    WithdrawInsuranceFundEmergency, // deprecated
    SetMarketMaker, // deprecated
    UpdateSequencerFee, // deprecated
    AuthorizeSigner,
    ClaimSequencerFees, // deprecated
    Withdraw,
    Invalid
}

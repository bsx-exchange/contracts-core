// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

/// @title Orderbook
/// @notice Match orders and manage fees
interface IOrderBook {
    enum OrderSide {
        BUY,
        SELL
    }

    struct Order {
        uint8 productIndex;
        address sender;
        uint128 size;
        uint128 price;
        uint64 nonce;
        OrderSide orderSide;
        bytes32 orderHash;
    }

    struct Fees {
        int128 maker;
        int128 taker;
        uint128 makerReferralRebate;
        uint128 takerReferralRebate;
        uint128 liquidation;
        uint128 sequencer;
        bool isMakerFeeInBSX;
        bool isTakerFeeInBSX;
    }

    /// @notice Quote and base amount of the order
    struct Delta {
        int128 quoteAmount;
        int128 productAmount;
    }

    struct FeesInBSX {
        int128 maker;
        int128 taker;
    }

    /// @notice Stores the fee collection of the orderbook
    struct FeeCollection {
        int128 inUSDC;
        int128 inBSX;
    }

    /// @notice Event emitted when an order is matched
    /// @param productIndex The product ID
    /// @param maker The maker address
    /// @param taker The taker address
    /// @param makerSide The maker side
    /// @param makerNonce The maker nonce
    /// @param takerNonce The taker nonce
    /// @param fillAmount The filled amount
    /// @param fillPrice The filled price
    /// @param fees Fees including maker, taker, sequencer, and referral rebate
    /// @param isLiquidation Whether the order is a liquidation
    event OrderMatched(
        uint8 indexed productIndex,
        address indexed maker,
        address indexed taker,
        OrderSide makerSide,
        uint256 makerNonce,
        uint256 takerNonce,
        uint128 fillAmount,
        uint128 fillPrice,
        Fees fees,
        bool isLiquidation
    );

    /// @notice Match orders
    /// @dev Emits a {OrderMatched} event
    /// @param productIndex The product ID
    /// @param maker The maker order
    /// @param taker The taker order
    /// @param fees The fees of the order
    /// @param isLiquidation Whether the order is a liquidation
    function matchOrders(
        uint8 productIndex,
        Order memory maker,
        Order memory taker,
        Fees memory fees,
        bool isLiquidation
    ) external;

    /// @notice Claim the collected trading fee
    /// @dev This functions just set the collected trading fee to 0
    /// Transferring token is handled in Exchange.sol
    function claimTradingFees() external returns (FeeCollection memory);

    // @notice Claim the collected sequencer fee
    /// @dev This functions just set the collected sequencer fee to 0
    /// Transferring token is handled in Exchange.sol
    function claimSequencerFees() external returns (FeeCollection memory);

    /// @notice Get the collateral token address
    function getCollateralToken() external view returns (address);

    /// @notice Get the collected sequencer fee
    function getTradingFees() external view returns (FeeCollection memory);

    /// @notice Get the collected trading fee
    function getSequencerFees() external view returns (FeeCollection memory);

    /// @notice Check if the order is filled
    function isMatched(address userA, uint64 nonceA, address userB, uint64 nonceB) external view returns (bool);
}

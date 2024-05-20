// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

import {OrderSide} from "../types/DataTypes.sol";

/// @title Orderbook
/// @notice Match orders and manage fees
interface IOrderbook {
    struct Order {
        address account;
        uint128 size;
        uint128 price;
        uint64 nonce;
        OrderSide orderSide;
        bytes32 orderHash;
    }

    struct Fee {
        uint128 maker;
        uint128 taker;
        uint128 sequencer;
        uint128 referralRebate;
    }

    /// @notice Event emitted when an order is matched
    /// @param productId The product ID
    /// @param maker The maker address
    /// @param taker The taker address
    /// @param makerSide The maker side
    /// @param makerNonce The maker nonce
    /// @param takerNonce The taker nonce
    /// @param matchedAmount The filled amount
    /// @param matchedPrice The filled price
    /// @param fee Fees including maker, taker, sequencer, and referral rebate
    /// @param isLiquidation Whether the order is a liquidation
    event OrderMatched(
        uint8 indexed productId,
        address indexed maker,
        address indexed taker,
        OrderSide makerSide,
        uint256 makerNonce,
        uint256 takerNonce,
        uint128 matchedAmount,
        uint128 matchedPrice,
        Fee fee,
        bool isLiquidation
    );

    /*//////////////////////////////////////////////////////////////////////////
                                NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Match orders
    /// @param productId The product ID
    /// @param makerOrder The maker order
    /// @param takerOrder The taker order
    /// @param matchFee Fees including maker, taker, sequencer, and referral rebate
    /// @param isLquidate Whether the order is liquidated or not
    function matchOrders(
        uint8 productId,
        Order calldata makerOrder,
        Order calldata takerOrder,
        Fee calldata matchFee,
        bool isLquidate
    ) external;

    /// @notice Claim the collected sequencer fee
    /// @dev This functions just set the collected sequencer fee to 0
    /// Transfer is handled in Exchange.sol
    function claimCollectedSequencerFees() external returns (uint256);

    /// @notice Claim the collected trading fee
    /// @dev This functions just set the collected trading fee to 0
    /// Transfer is handled in Exchange.sol
    function claimCollectedTradingFees() external returns (uint256);

    /*//////////////////////////////////////////////////////////////////////////
                                CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Get the collateral token address
    function getCollateralToken() external view returns (address);

    /// @notice Get the collected sequencer fee
    function getCollectedSequencerFees() external view returns (uint256);

    /// @notice Get the collected trading fee
    function getCollectedTradingFees() external view returns (uint256);
}

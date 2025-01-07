// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

import {OrderLogic} from "../lib/logic/OrderLogic.sol";

/// @title Orderbook
/// @notice Match orders and manage fees
interface IOrderBook {
    /// @notice Stores the fee collection of the orderbook
    struct FeeCollection {
        int128 perpFeeCollection;
    }

    /// @notice Hash of maker and taker order
    struct OrderHash {
        bytes32 maker;
        bytes32 taker;
    }

    /// @notice Quote and base amount of the order
    struct Delta {
        int128 quoteAmount;
        int128 productAmount;
    }

    /// @notice Fee of the order
    struct Fee {
        int128 maker;
        int128 taker;
        uint128 referralRebate;
        uint128 liquidationPenalty;
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
    /// @param feeDelta Fees including maker, taker, sequencer, and referral rebate
    /// @param isLiquidation Whether the order is a liquidation
    event OrderMatched(
        uint8 indexed productIndex,
        address indexed maker,
        address indexed taker,
        OrderLogic.OrderSide makerSide,
        uint256 makerNonce,
        uint256 takerNonce,
        uint128 fillAmount,
        uint128 fillPrice,
        Fee feeDelta,
        bool isLiquidation
    );

    /// @notice Match orders
    /// @dev Emits a {OrderMatched} event
    /// @param maker The maker order
    /// @param taker The taker order
    /// @param digest The order hash of maker and taker
    /// @param productIndex The product ID
    /// @param takerSequencerFee Fee of taker paid to the sequencer
    /// @param delta The fee delta
    function matchOrders(
        OrderLogic.SignedOrder memory maker,
        OrderLogic.SignedOrder memory taker,
        OrderHash memory digest,
        uint8 productIndex,
        uint128 takerSequencerFee,
        Fee memory delta
    ) external;

    /// @notice Claim the collected trading fee
    /// @dev This functions just set the collected trading fee to 0
    /// Transferring token is handled in Exchange.sol
    function claimTradingFees() external returns (int256);

    // @notice Claim the collected sequencer fee
    /// @dev This functions just set the collected sequencer fee to 0
    /// Transferring token is handled in Exchange.sol
    function claimSequencerFees() external returns (int256);

    /// @notice Get the collateral token address
    function getCollateralToken() external view returns (address);

    /// @notice Get the collected sequencer fee
    function getTradingFees() external view returns (int128);

    /// @notice Get the collected trading fee
    function getSequencerFees() external view returns (int256);

    /// @notice Check if the order is filled
    function isMatched(address userA, uint64 nonceA, address userB, uint64 nonceB) external view returns (bool);
}

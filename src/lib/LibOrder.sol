// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

import {OrderSide} from "../share/Enums.sol";

/// @title LibOrder contract
/// @notice This contract defines the data structure of order.
library LibOrder {
    struct Order {
        address sender;
        uint128 size;
        uint128 price;
        uint64 nonce;
        uint8 productIndex;
        OrderSide orderSide;
    }

    struct SignedOrder {
        Order order;
        bytes signature;
        address signer;
        bool isLiquidation; // true: liquidation order, false: normal order
    }

    struct MatchOrders {
        SignedOrder maker;
        SignedOrder taker;
    }
}

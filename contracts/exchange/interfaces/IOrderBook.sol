// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;
import "./IClearingService.sol";
import "../lib/LibOrder.sol";

interface IOrderBook {
    event OrderMatched(
        uint8 indexed productIndex,
        address indexed maker,
        address indexed taker,
        OrderSide makerSide,
        uint256 makerNonce,
        uint256 takerNonce,
        uint128 fillAmount,
        uint128 fillPrice,
        Fee feeDelta,
        bool isLiquidation
    );

    event SpotBalance(
        address indexed maker,
        int128 indexed balance,
        address indexed taker,
        int128 balance256
    );

    event FundingInfo(
        uint8 indexed productIndex,
        int128 indexed cumulativeFundingRate,
        int128 indexed lastFunding,
        address user
    );
    struct OrderHash {
        bytes32 maker;
        bytes32 taker;
    }
    struct Delta {
        int128 quoteAmount;
        int128 productAmount;
    }
    struct Fee {
        int128 maker;
        int128 taker;
    }

    struct FeeCollection {
        int128 perpFeeCollection;
    }

    struct SpotBalanceInfo {
        int128 makerAmount;
        int128 takerAmount;
    }

    struct LastMatchInfo {
        uint64 makerNonce;
        uint64 takerNonce;
        address maker;
        address taker;
    }

    /**
     * @dev Match orders.
     * @param maker Maker order
     * @param taker Taker order
     */
    function matchOrders(
        LibOrder.SignedOrder memory maker,
        LibOrder.SignedOrder memory taker,
        OrderHash memory digest,
        uint8 productIndex,
        uint128 takerSequencerFee,
        Fee memory delta
    ) external;

    /**
     * @dev Claim fee of spot and perpetual.
     */
    function claimTradingFees() external returns (int256);

    /**
     * @dev Claim sequencer fee of perpetual market.
     */
    function claimSequencerFees() external returns (int256);

    function getCollateralToken() external view returns (address);

    function getTradingFees() external view returns (int128);

    function getSequencerFees() external view returns (int256);
}

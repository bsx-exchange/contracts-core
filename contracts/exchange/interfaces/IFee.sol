// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23;

interface IFee {
    error NotSequencer();

    //feeType: 0: market maker, 1: non market maker
    enum FeeType {
        MM,
        REGULAR
    }

    /**
     * @dev Struct of fee rate.
     * @param makerFeeRate Fee rate for maker
     * @param takerFeeRate Fee rate for taker
     */
    struct FeeRate {
        uint128 makerFeeRate;
        uint128 takerFeeRate;
    }

    /**
     * @dev Emitted when the market maker is updated.
     * @param feeType Fee type
     * @param makerFeeRate Fee rate for maker
     * @param takerFeeRate Fee rate for taker
     */
    event UpdateFeeRate(
        uint8 indexed feeType,
        uint128 makerFeeRate,
        uint128 takerFeeRate
    );

    /**
     * @dev Set market maker address. Will be called by exchange contract.
     * @param _marketMakers Market maker address
     * @param _isMarketMaker Is market maker or not
     */
    function setMarketMaker(
        address[] memory _marketMakers,
        bool _isMarketMaker
    ) external;

    /**
     * @dev Get market maker address.
     * @param _marketMaker Market maker address
     */
    function isMarketMaker(address _marketMaker) external view returns (bool);

    /**
     * @dev Update fee rate. Will be called by exchange contract.
     * @param _feeType Fee type
     * @param _makerFee Fee rate for maker
     * @param _takerFee Fee rate for taker
     */
    function updateFeeRate(
        uint8 _feeType,
        uint128 _makerFee,
        uint128 _takerFee
    ) external;

    /**
     * @dev Get fee rate for regular user.
     * @param _isTaker Is taker or not
     */
    function getRegularFeeRate(bool _isTaker) external view returns (uint128);

    /**
     * @dev Get fee rate for market maker who is in the market maker list.
     * @param _isTaker Is taker or not
     */
    function getMMFeeRate(bool _isTaker) external view returns (uint128);

    /**
     * @dev Get liquidation fee rate.
     */
    function getLiquidationFeeRate() external view returns (uint128);

    /**
     * @dev Update liquidation fee rate. Will be called by exchange contract.
     * @param _liquidationFeeRate Liquidation fee rate
     */
    function updateLiquidationFeeRate(uint128 _liquidationFeeRate) external;

    /**
     *  @dev Get taker sequencer fee.
     */
    function getTakerSequencerFee() external view returns (uint128);

    function getWithdrawalSequencerFee() external view returns (uint128);

    function updateTakerSequencerFee(uint128 _takerSequencerFee) external;

    function updateWithdrawalSequencerFee(
        uint128 _withdrawalSequencerFee
    ) external;
}

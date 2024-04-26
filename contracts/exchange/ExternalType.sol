// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;
import "./interfaces/IExchange.sol";
import "./lib/LibOrder.sol";

/**
 * @title ExternalType contract
 * @author BSX
 * @notice This contract is only used for generating ABI type for Geth. It is not deployed to the blockchain.
 */
contract ExternalType {
    function getSigningWallets(IExchange.AddSigningWallet memory t) external {}

    function matchOrders(LibOrder.MatchOrders memory t) external {}

    function updateFundingRate(IExchange.UpdateFundingRate memory t) external {}

    function assertOpenInterest(
        IExchange.AssertOpenInterest memory t
    ) external {}

    function updateFeeRate(IExchange.UpdateFeeRate memory t) external {}

    function coverLossByInsuranceFund(
        IExchange.CoverLossByInsuranceFund memory t
    ) external {}

    function updatepdateLiquidationFeeRate(
        IExchange.UpdateLiquidationFeeRate memory t
    ) external {}

    function setMarketMaker(IExchange.SetMarketMaker memory t) external {}

    function addSigningWallet(IExchange.AddSigningWallet memory t) external {}

    function withdraw(IExchange.Withdraw memory t) external {}
}

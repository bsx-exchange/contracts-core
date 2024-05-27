// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ISpot} from "./ISpot.sol";

/// @title Clearing service interface
/// @notice Manage insurance fund and spot balance
interface IClearingService {
    /// @notice Deposits token to spot account
    /// @param account Account address
    /// @param amount Amount of token
    /// @param token Token address
    /// @param spotEngine Spot engine address
    function deposit(address account, uint256 amount, address token, ISpot spotEngine) external;

    /// @notice Withdraws token from spot account
    /// @param account Account address
    /// @param amount Amount of token
    /// @param token Token address
    /// @param spotEngine Spot engine address
    function withdraw(address account, uint256 amount, address token, ISpot spotEngine) external;

    /// @notice Deposits token to insurance fund
    /// @param amount Amount of token
    function depositInsuranceFund(uint256 amount) external;

    /// @notice Withdraw token from insurance fund
    /// @param amount Amount of token
    function withdrawInsuranceFundEmergency(uint256 amount) external;

    /// @notice Uses the insurance fund to cover the loss of the account
    /// @param account Account address
    /// @param amount Amount of token
    /// @param spotEngine Spot engine address
    function insuranceCoverLost(address account, uint256 amount, ISpot spotEngine, address token) external;

    /// @notice Gets insurance fund balance
    function getInsuranceFund() external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Access} from "./access/Access.sol";
import {IClearingService} from "./interfaces/IClearingService.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {ISpot} from "./interfaces/ISpot.sol";
import {Errors} from "./lib/Errors.sol";

/// @title Clearinghouse contract
/// @notice Manage insurance fund and spot balance
/// @dev This contract is upgradeable
contract ClearingService is IClearingService, Initializable {
    using SafeCast for uint256;

    Access public access;
    uint256 private insuranceFundBalance;

    // function initialize(address _access) public initializer {
    //     if (_access == address(0)) {
    //         revert Errors.ZeroAddress();
    //     }
    //     access = Access(_access);
    // }

    modifier onlySequencer() {
        if (
            msg.sender != address(access.getExchange()) && msg.sender != address(access.getOrderBook())
                && msg.sender != address(access.getVaultManager())
        ) {
            revert Errors.Unauthorized();
        }
        _;
    }

    /// @inheritdoc IClearingService
    function deposit(address account, uint256 amount, address token) external onlySequencer {
        ISpot spotEngine = access.getSpotEngine();
        int256 _amount = amount.toInt256();
        spotEngine.updateBalance(account, token, _amount);
        spotEngine.updateTotalBalance(token, _amount);
    }

    /// @inheritdoc IClearingService
    function withdraw(address account, uint256 amount, address token) external onlySequencer {
        ISpot spotEngine = access.getSpotEngine();
        int256 _amount = -amount.toInt256();
        spotEngine.updateBalance(account, token, _amount);
        spotEngine.updateTotalBalance(token, _amount);
    }

    /// @inheritdoc IClearingService
    function depositInsuranceFund(uint256 amount) external onlySequencer {
        if (amount == 0) {
            revert Errors.ClearingService_ZeroAmount();
        }
        insuranceFundBalance += amount;
    }

    /// @inheritdoc IClearingService
    function collectLiquidationFee(address account, uint64 nonce, uint256 amount) external onlySequencer {
        insuranceFundBalance += amount;
        emit CollectLiquidationFee(account, nonce, amount, insuranceFundBalance);
    }

    /// @inheritdoc IClearingService
    function withdrawInsuranceFundEmergency(uint256 amount) external onlySequencer {
        if (amount == 0) {
            revert Errors.ClearingService_ZeroAmount();
        }
        if (amount > insuranceFundBalance) {
            revert Errors.ClearingService_InsufficientFund(amount, insuranceFundBalance);
        }
        insuranceFundBalance -= amount;
    }

    /// @inheritdoc IClearingService
    function coverLossWithInsuranceFund(address account, uint256 amount) external onlySequencer {
        IOrderBook orderBook = IOrderBook(access.getOrderBook());
        ISpot spotEngine = ISpot(access.getSpotEngine());

        address collateralToken = orderBook.getCollateralToken();
        int256 balance = spotEngine.getBalance(collateralToken, account);
        if (balance >= 0) {
            revert Errors.ClearingService_NoLoss(account, balance);
        }

        if (amount > insuranceFundBalance) {
            revert Errors.ClearingService_InsufficientFund(amount, insuranceFundBalance);
        }
        insuranceFundBalance -= amount;

        spotEngine.updateBalance(account, collateralToken, amount.toInt256());
    }

    function getInsuranceFundBalance() external view returns (uint256) {
        return insuranceFundBalance;
    }
}

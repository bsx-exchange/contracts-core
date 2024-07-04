// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Access} from "./access/Access.sol";
import {IClearingService} from "./interfaces/IClearingService.sol";
import {ISpot} from "./interfaces/ISpot.sol";
import {Errors} from "./lib/Errors.sol";

/// @title Clearinghouse contract
/// @notice Manage insurance fund and spot balance
/// @dev This contract is upgradeable
contract ClearingService is IClearingService, Initializable, OwnableUpgradeable {
    Access public access;
    uint256 private insuranceFund18D;

    function initialize(address _access) public initializer {
        if (_access == address(0)) {
            revert Errors.ZeroAddress();
        }
        access = Access(_access);
    }

    function _onlySequencer() internal view {
        if (msg.sender != access.getExchange() && msg.sender != access.getOrderBook()) {
            revert Errors.Unauthorized();
        }
    }

    modifier onlySequencer() {
        _onlySequencer();
        _;
    }

    /// @inheritdoc IClearingService
    function deposit(address account, uint256 amount, address token, ISpot spotEngine) external onlySequencer {
        ISpot.AccountDelta[] memory productDelta = new ISpot.AccountDelta[](1);
        productDelta[0] = ISpot.AccountDelta(token, account, int256(amount));
        spotEngine.modifyAccount(productDelta);
        spotEngine.setTotalBalance(token, amount, true);
    }

    /// @inheritdoc IClearingService
    function withdraw(address account, uint256 amount, address token, ISpot spotEngine) external onlySequencer {
        ISpot.AccountDelta[] memory productDelta = new ISpot.AccountDelta[](1);
        productDelta[0] = ISpot.AccountDelta(token, account, -int256(amount));
        spotEngine.modifyAccount(productDelta);
        spotEngine.setTotalBalance(token, amount, false);
    }

    /// @inheritdoc IClearingService
    function depositInsuranceFund(uint256 amount) external onlySequencer {
        if (amount == 0) {
            revert Errors.ClearingService_ZeroAmount();
        }
        insuranceFund18D += amount;
    }

    /// @inheritdoc IClearingService
    function collectLiquidationFee(address account, uint64 nonce, uint256 amount) external onlySequencer {
        insuranceFund18D += amount;
        emit CollectLiquidationFee(account, nonce, amount, insuranceFund18D);
    }

    /// @inheritdoc IClearingService
    function withdrawInsuranceFundEmergency(uint256 amount) external onlySequencer {
        if (amount == 0) {
            revert Errors.ClearingService_ZeroAmount();
        }
        if (amount > insuranceFund18D) {
            revert Errors.ClearingService_InsufficientFund(amount, insuranceFund18D);
        }
        insuranceFund18D -= amount;
    }

    /// @inheritdoc IClearingService
    function coverLossWithInsuranceFund(ISpot spotEngine, address token, address account) external onlySequencer {
        int256 balance = spotEngine.getBalance(token, account);
        if (balance >= 0) {
            revert Errors.ClearingService_NoLoss(account, balance);
        }

        uint256 loss = uint256(-balance);
        if (loss > insuranceFund18D) {
            revert Errors.ClearingService_InsufficientFund(loss, insuranceFund18D);
        }
        insuranceFund18D -= loss;

        ISpot.AccountDelta[] memory productDelta = new ISpot.AccountDelta[](1);
        productDelta[0] = ISpot.AccountDelta(token, account, int256(loss));
        spotEngine.modifyAccount(productDelta);
    }

    /// @inheritdoc IClearingService
    function getInsuranceFund() external view returns (uint256) {
        return insuranceFund18D;
    }
}

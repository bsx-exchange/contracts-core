// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Access} from "./access/Access.sol";
import {IClearingService} from "./interfaces/IClearingService.sol";
import {ISpot} from "./interfaces/ISpot.sol";
import {
    AMOUNT_EXCEEDS_FUND,
    INSUFFICIENT_BALANCE,
    INVALID_ADDRESS,
    INVALID_AMOUNT,
    NOT_SEQUENCER,
    SPOT_NOT_NEGATIVE
} from "./share/RevertReason.sol";

/// @title Clearinghouse contract
/// @notice Manage insurance fund and spot balance
/// @dev This contract is upgradeable
contract ClearingService is IClearingService, Initializable {
    Access public access;
    uint256 private insuranceFund18D;

    function initialize(address _access) public initializer {
        if (_access == address(0)) {
            revert(INVALID_ADDRESS);
        }
        access = Access(_access);
    }

    function _onlyExchange() internal view {
        if (msg.sender != access.getExchange()) {
            revert(NOT_SEQUENCER);
        }
    }

    modifier onlyExchange() {
        _onlyExchange();
        _;
    }

    /// @inheritdoc IClearingService
    function deposit(address account, uint256 amount, address token, ISpot spotEngine) external onlyExchange {
        ISpot.AccountDelta[] memory productDelta = new ISpot.AccountDelta[](1);
        productDelta[0] = ISpot.AccountDelta(token, account, int256(amount));
        spotEngine.modifyAccount(productDelta);
        spotEngine.setTotalBalance(token, amount, true);
    }

    /// @inheritdoc IClearingService
    function withdraw(address account, uint256 amount, address token, ISpot spotEngine) external onlyExchange {
        ISpot.AccountDelta[] memory productDelta = new ISpot.AccountDelta[](1);
        productDelta[0] = ISpot.AccountDelta(token, account, -int256(amount));
        spotEngine.modifyAccount(productDelta);
        spotEngine.setTotalBalance(token, amount, false);
    }

    /// @inheritdoc IClearingService
    function depositInsuranceFund(uint256 amount) external onlyExchange {
        if (amount == 0) {
            revert(INVALID_AMOUNT);
        }
        insuranceFund18D += amount;
    }

    /// @inheritdoc IClearingService
    function withdrawInsuranceFundEmergency(uint256 amount) external onlyExchange {
        if (amount == 0) {
            revert(INVALID_AMOUNT);
        }
        if (amount > insuranceFund18D) {
            revert(INSUFFICIENT_BALANCE);
        }
        insuranceFund18D -= amount;
    }

    /// @inheritdoc IClearingService
    function insuranceCoverLost(
        address account,
        uint256 amount,
        ISpot spotEngine,
        address token
    ) external onlyExchange {
        if (amount > insuranceFund18D) {
            revert(AMOUNT_EXCEEDS_FUND);
        }
        int256 balance = spotEngine.getBalance(token, account);
        if (balance >= 0) {
            revert(SPOT_NOT_NEGATIVE);
        }
        ISpot.AccountDelta[] memory productDelta = new ISpot.AccountDelta[](1);
        insuranceFund18D -= amount;
        productDelta[0] = ISpot.AccountDelta(token, account, int256(amount));
        spotEngine.modifyAccount(productDelta);
    }

    /// @inheritdoc IClearingService
    function getInsuranceFund() external view returns (uint256) {
        return insuranceFund18D;
    }
}

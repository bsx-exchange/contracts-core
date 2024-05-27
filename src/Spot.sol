// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Access} from "./access/Access.sol";
import {ISpot} from "./interfaces/ISpot.sol";
import {INVALID_ADDRESS, NOT_SEQUENCER} from "./share/RevertReason.sol";

/// @title Spot contract
/// @notice Manage the token balance states
/// @dev This contract is upgradeable
contract Spot is ISpot, Initializable {
    mapping(address account => mapping(address token => Balance balance)) public balance;
    mapping(address token => uint256 totalBalance) public totalBalancePerToken;
    Access public access;

    function initialize(address _access) public initializer {
        if (_access == address(0)) {
            revert(INVALID_ADDRESS);
        }
        access = Access(_access);
    }

    function _onlySequencer() internal view {
        if (
            msg.sender != access.getExchange() && msg.sender != access.getClearingService()
                && msg.sender != access.getOrderBook()
        ) {
            revert(NOT_SEQUENCER);
        }
    }

    modifier onlySequencer() {
        _onlySequencer();
        _;
    }

    /// @inheritdoc ISpot
    function getTotalBalance(address _token) external view returns (uint256) {
        return totalBalancePerToken[_token];
    }

    /// @inheritdoc ISpot
    function setTotalBalance(address _token, uint256 _amount, bool _increase) external onlySequencer {
        if (_increase) {
            totalBalancePerToken[_token] += _amount;
        } else {
            totalBalancePerToken[_token] -= _amount;
        }
    }

    /// @inheritdoc ISpot
    function getBalance(address _token, address _account) external view returns (int256) {
        return balance[_account][_token].amount;
    }

    /// @inheritdoc ISpot
    function modifyAccount(AccountDelta[] calldata _accountDeltas) external onlySequencer {
        uint256 accountDeltasLength = _accountDeltas.length;
        for (uint256 i = 0; i < accountDeltasLength; ++i) {
            AccountDelta memory accountDelta = _accountDeltas[i];
            address token = accountDelta.token;
            address account = accountDelta.account;
            int256 amount = accountDelta.amount;
            balance[account][token].amount += amount;
        }
    }
}

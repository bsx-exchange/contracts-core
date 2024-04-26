// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./interfaces/ISpot.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./share/Enums.sol";
import "./share/Constants.sol";
import "./interfaces/IClearingService.sol";
import "./access/Access.sol";
import "./interfaces/IERC20Extend.sol";
import "./share/RevertReason.sol";

/**
 * @title Spot contract
 * @author BSX
 * @notice This contract is only used for managing the balance of an account.
 * @dev This contract is upgradeable.
 */
contract Spot is ISpot, OwnableUpgradeable {
    mapping(address => mapping(address => Balance)) public balance;
    mapping(address => uint256) public totalBalancePerToken;
    Access public access;

    function initialize(address _access) public initializer {
        __Ownable_init(msg.sender);
        if (_access == address(0)) {
            revert(INVALID_ADDRESS);
        }
        access = Access(_access);
    }

    function _onlySequencer() internal view {
        if (
            msg.sender != access.getExchange() &&
            msg.sender != access.getClearingService() &&
            msg.sender != access.getOrderBook()
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
    function setTotalBalance(
        address _token,
        uint256 _amount,
        bool _increase
    ) external onlySequencer {
        if (_increase) {
            totalBalancePerToken[_token] += _amount;
        } else {
            totalBalancePerToken[_token] -= _amount;
        }
    }

    /// @inheritdoc ISpot
    function getBalance(
        address _token,
        address _account
    ) external view returns (int256) {
        return balance[_account][_token].amount;
    }

    /// @inheritdoc ISpot
    function modifyAccount(
        AccountDelta[] calldata _accountDeltas
    ) external onlySequencer {
        uint256 accountDeltasLength = _accountDeltas.length;
        for (uint i = 0; i < accountDeltasLength; ++i) {
            AccountDelta memory accountDelta = _accountDeltas[i];
            address token = accountDelta.token;
            address account = accountDelta.account;
            int256 amount = accountDelta.amount;
            if (amount > 0) {
                balance[account][token].amount += amount;
            } else {
                balance[account][token].amount -= -amount;
            }
        }
    }
}

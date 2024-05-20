// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Gateway} from "./abstracts/Gateway.sol";
import {IAccess} from "./interfaces/IAccess.sol";
import {ISpotEngine} from "./interfaces/ISpotEngine.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title Spot contract
/// @notice Manage the token balance states
/// @dev This contract is upgradeable
contract SpotEngine is Gateway, ISpotEngine, Initializable {
    mapping(address account => mapping(address token => Balance balance)) private _balance;
    mapping(address token => uint256 amount) private _totalBalance;

    IAccess public access;

    function initialize(address _access) public initializer {
        if (_access == address(0)) {
            revert Errors.ZeroAddress();
        }
        access = IAccess(_access);
    }

    /// @inheritdoc ISpotEngine
    function updateAccount(address account, address token, int256 amount) external override authorized {
        int256 newBalance = _balance[account][token].amount + amount;
        _balance[account][token].amount = newBalance;
        emit UpdateAccount(account, token, amount, newBalance);
    }

    /// @inheritdoc ISpotEngine
    function increaseTotalBalance(address token, uint256 amount) external override authorized {
        _totalBalance[token] += amount;
    }

    /// @inheritdoc ISpotEngine
    function decreaseTotalBalance(address token, uint256 amount) external override authorized {
        _totalBalance[token] -= amount;
    }

    /// @inheritdoc ISpotEngine
    function getTotalBalance(address token) external view override returns (uint256) {
        return _totalBalance[token];
    }

    /// @inheritdoc ISpotEngine
    function getBalance(address account, address token) external view override returns (int256) {
        return _balance[account][token].amount;
    }

    /// @inheritdoc Gateway
    function _isAuthorized(address caller) internal view override returns (bool) {
        return caller == access.getExchange() || caller == access.getClearinghouse() || caller == access.getOrderbook();
    }
}

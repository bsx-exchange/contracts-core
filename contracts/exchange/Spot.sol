// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

import {Access} from "./access/Access.sol";
import {ISpot} from "./interfaces/ISpot.sol";
import {Errors} from "./lib/Errors.sol";
import {BSX_ORACLE} from "./share/Constants.sol";

/// @title Spot contract
/// @notice Manage the token balance states
/// @dev This contract is upgradeable
contract Spot is ISpot, Initializable {
    using SignedMath for int256;

    mapping(address account => mapping(address token => Balance balance)) public balance;
    mapping(address token => uint256 totalBalance) public totalBalancePerToken;
    Access public access;

    mapping(address token => uint256 cap) public capInUsd;

    // function initialize(address _access) public initializer {
    //     if (_access == address(0)) {
    //         revert Errors.ZeroAddress();
    //     }
    //     access = Access(_access);
    // }

    function _checkRole(bytes32 role, address account) internal view {
        if (!access.hasRole(role, account)) {
            revert Errors.Unauthorized();
        }
    }

    modifier onlyRole(bytes32 role) {
        _checkRole(role, msg.sender);
        _;
    }

    modifier onlySequencer() {
        if (
            msg.sender != address(access.getExchange()) && msg.sender != address(access.getClearingService())
                && msg.sender != address(access.getOrderBook())
        ) {
            revert Errors.Unauthorized();
        }
        _;
    }

    /// @inheritdoc ISpot
    function getTotalBalance(address _token) external view returns (uint256) {
        return totalBalancePerToken[_token];
    }

    /// @inheritdoc ISpot
    function updateTotalBalance(address token, int256 amount) external onlySequencer {
        if (amount > 0) {
            totalBalancePerToken[token] += amount.abs();
            _checkCap(token);
        } else {
            totalBalancePerToken[token] -= amount.abs();
        }
    }

    /// @inheritdoc ISpot
    function getBalance(address _token, address _account) external view returns (int256) {
        return balance[_account][_token].amount;
    }

    /// @inheritdoc ISpot
    function updateBalance(address account, address token, int256 amount) external onlySequencer {
        int256 currentBalance = balance[account][token].amount;
        int256 newBalance = currentBalance + amount;
        balance[account][token].amount = newBalance;
        emit UpdateBalance(account, token, amount, newBalance);
    }

    /// @inheritdoc ISpot
    function setCapInUsd(address token, uint256 cap) external onlyRole(access.GENERAL_ROLE()) {
        capInUsd[token] = cap;
    }

    /// @dev Check if the token supply exceeds the cap
    function _checkCap(address token) internal view {
        uint256 supply = totalBalancePerToken[token];

        uint256 maxSupplyInUsd = capInUsd[token];
        if (maxSupplyInUsd == 0) return;

        uint256 price = BSX_ORACLE.getTokenPriceInUsd(token);
        if (Math.mulDiv(supply, price, 1e18) > maxSupplyInUsd) {
            revert Errors.ExceededCap(token);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IAccess} from "./interfaces/IAccess.sol";
import {Errors} from "./libraries/Errors.sol";
import {Role} from "./types/DataTypes.sol";

/// @title Access contract
/// @notice Manage access control
/// @dev This contract is upgradeable
contract Access is IAccess, Initializable, AccessControlUpgradeable {
    bytes32 public constant GENERAL_ADMIN_ROLE = keccak256(abi.encodePacked(Role.GENERAL_ADMIN));

    address private _exchange;
    address private _clearinghouse;
    address private _orderbook;

    function initialize(address generalAdmin) public initializer {
        if (generalAdmin == address(0)) {
            revert Errors.ZeroAddress();
        }
        _grantRole(GENERAL_ADMIN_ROLE, generalAdmin);
    }

    function grantRoleForAccount(address account, bytes32 role) external override onlyRole(GENERAL_ADMIN_ROLE) {
        _grantRole(role, account);
    }

    function revokeRoleForAccount(address account, bytes32 role) external override onlyRole(GENERAL_ADMIN_ROLE) {
        _revokeRole(role, account);
    }

    function setExchange(address exchange) external override onlyRole(GENERAL_ADMIN_ROLE) {
        if (exchange == address(0)) {
            revert Errors.ZeroAddress();
        }
        _exchange = exchange;
    }

    function setClearinghouse(address clearinghouse) external override onlyRole(GENERAL_ADMIN_ROLE) {
        if (clearinghouse == address(0)) {
            revert Errors.ZeroAddress();
        }
        _clearinghouse = clearinghouse;
    }

    function setOrderbook(address orderbook) external override onlyRole(GENERAL_ADMIN_ROLE) {
        if (orderbook == address(0)) {
            revert Errors.ZeroAddress();
        }
        _orderbook = orderbook;
    }

    function getExchange() external view override returns (address) {
        return _exchange;
    }

    function getClearinghouse() external view override returns (address) {
        return _clearinghouse;
    }

    function getOrderbook() external view override returns (address) {
        return _orderbook;
    }
}

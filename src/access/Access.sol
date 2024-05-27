// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Role} from "../share/Enums.sol";
import {INVALID_ADDRESS} from "../share/RevertReason.sol";

/// @title Access contract
/// @notice Manage access control
/// @dev This contract is upgradeable
contract Access is Initializable, AccessControlUpgradeable {
    bytes32 public constant ADMIN_GENERAL_ROLE = keccak256(abi.encodePacked(Role.ADMIN_GENERAL));

    address private exchange;
    address private clearingService;
    address private orderBook;

    /// @notice Throws if the sender is not a general admin
    error NotAdminGeneral();

    /// @notice Throws if the address is set to the zero address
    error InvalidAddress();

    function initialize(address adminGeneral) public initializer {
        if (adminGeneral == address(0)) {
            revert(INVALID_ADDRESS);
        }
        _grantRole(ADMIN_GENERAL_ROLE, adminGeneral);
    }

    modifier onlyGeneralAdmin() {
        if (!hasRole(ADMIN_GENERAL_ROLE, msg.sender)) {
            revert NotAdminGeneral();
        }
        _;
    }

    function grantRoleForAccount(address account, bytes32 role) external onlyGeneralAdmin {
        _grantRole(role, account);
    }

    function revokeRoleForAccount(address account, bytes32 role) external onlyGeneralAdmin {
        _revokeRole(role, account);
    }

    function setExchange(address _exchange) external onlyGeneralAdmin {
        if (_exchange == address(0)) {
            revert InvalidAddress();
        }
        exchange = _exchange;
    }

    function getExchange() external view returns (address) {
        return exchange;
    }

    function setClearingService(address _clearingService) external onlyGeneralAdmin {
        if (_clearingService == address(0)) {
            revert InvalidAddress();
        }
        clearingService = _clearingService;
    }

    function getClearingService() external view returns (address) {
        return clearingService;
    }

    function setOrderBook(address _orderBook) external onlyGeneralAdmin {
        if (_orderBook == address(0)) {
            revert InvalidAddress();
        }
        orderBook = _orderBook;
    }

    function getOrderBook() external view returns (address) {
        return orderBook;
    }
}

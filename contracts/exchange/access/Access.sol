// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {Errors} from "../lib/Errors.sol";
import {Role} from "../share/Enums.sol";

/// @title Access contract
/// @notice Manage access control
/// @dev This contract is upgradeable
contract Access is Initializable, AccessControlUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 private constant ADMIN_GENERAL_ROLE = keccak256(abi.encodePacked(Role.ADMIN_GENERAL)); // deprecated

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant GENERAL_ROLE = keccak256("GENERAL_ROLE");
    bytes32 public constant BATCH_OPERATOR_ROLE = keccak256("BATCH_OPERATOR_ROLE");
    bytes32 public constant BSX1000_OPERATOR_ROLE = keccak256("BSX1000_OPERATOR_ROLE");
    bytes32 public constant SIGNER_OPERATOR_ROLE = keccak256("SIGNER_OPERATOR_ROLE");
    bytes32 public constant COLLATERAL_OPERATOR_ROLE = keccak256("COLLATERAL_OPERATOR_ROLE");

    address private exchange;
    address private clearingService;
    address private orderBook;
    address private spot;
    address private perp;
    address private bsx1000;

    mapping(bytes32 role => EnumerableSet.AddressSet accounts) private roles;

    function initialize(address adminGeneral) public initializer {
        if (adminGeneral == address(0)) {
            revert Errors.ZeroAddress();
        }
        _grantRole(ADMIN_GENERAL_ROLE, adminGeneral);
    }

    function migrateAdmin() external {
        address account = msg.sender;

        // Revoke deprecated role
        _checkRole(ADMIN_GENERAL_ROLE, account);
        _revokeRole(ADMIN_GENERAL_ROLE, account);

        // Grant new role
        _grantRole(ADMIN_ROLE, account);
        roles[ADMIN_ROLE].add(account);
    }

    function grantRole(bytes32 role, address account) public override onlyRole(ADMIN_ROLE) {
        _grantRole(role, account);
        roles[role].add(account);
    }

    function revokeRole(bytes32 role, address account) public override onlyRole(ADMIN_ROLE) {
        _revokeRole(role, account);
        roles[role].remove(account);
    }

    function setExchange(address _exchange) external onlyRole(ADMIN_ROLE) {
        if (_exchange == address(0)) {
            revert Errors.ZeroAddress();
        }
        exchange = _exchange;
    }

    function setClearingService(address _clearingService) external onlyRole(ADMIN_ROLE) {
        if (_clearingService == address(0)) {
            revert Errors.ZeroAddress();
        }
        clearingService = _clearingService;
    }

    function setOrderBook(address _orderBook) external onlyRole(ADMIN_ROLE) {
        if (_orderBook == address(0)) {
            revert Errors.ZeroAddress();
        }
        orderBook = _orderBook;
    }

    function setPerpEngine(address _perp) external onlyRole(ADMIN_ROLE) {
        if (_perp == address(0)) {
            revert Errors.ZeroAddress();
        }
        perp = _perp;
    }

    function setSpotEngine(address _spot) external onlyRole(ADMIN_ROLE) {
        if (_spot == address(0)) {
            revert Errors.ZeroAddress();
        }
        spot = _spot;
    }

    function setBsx1000(address _bsx1000) external onlyRole(ADMIN_ROLE) {
        if (_bsx1000 == address(0)) {
            revert Errors.ZeroAddress();
        }
        bsx1000 = _bsx1000;
    }

    function getExchange() external view returns (address) {
        return exchange;
    }

    function getClearingService() external view returns (address) {
        return clearingService;
    }

    function getOrderBook() external view returns (address) {
        return orderBook;
    }

    function getSpotEngine() external view returns (address) {
        return spot;
    }

    function getPerpEngine() external view returns (address) {
        return perp;
    }

    function getBsx1000() external view returns (address) {
        return bsx1000;
    }

    function getAccountsForRole(bytes32 role) external view returns (address[] memory accounts) {
        accounts = new address[](roles[role].length());
        for (uint256 i = 0; i < roles[role].length(); i++) {
            accounts[i] = roles[role].at(i);
        }
    }
}

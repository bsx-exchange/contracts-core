// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IBSX1000x} from "../../1000x/interfaces/IBSX1000x.sol";
import {IClearingService} from "../interfaces/IClearingService.sol";
import {IExchange} from "../interfaces/IExchange.sol";
import {IOrderBook} from "../interfaces/IOrderBook.sol";
import {IPerp} from "../interfaces/IPerp.sol";
import {ISpot} from "../interfaces/ISpot.sol";
import {IVaultManager} from "../interfaces/IVaultManager.sol";
import {Errors} from "../lib/Errors.sol";
import {Roles} from "../lib/Roles.sol";

/// @title Access contract
/// @notice Manage access control
/// @dev This contract is upgradeable
contract Access is Initializable, AccessControlUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    IExchange private exchange;
    IClearingService private clearingService;
    IOrderBook private orderBook;
    ISpot private spot;
    IPerp private perp;
    IBSX1000x private bsx1000;

    mapping(bytes32 role => EnumerableSet.AddressSet accounts) private roles;

    IVaultManager private vaultManager;

    // function initialize(address adminGeneral) public initializer {
    //     if (adminGeneral == address(0)) {
    //         revert Errors.ZeroAddress();
    //     }
    //     _grantRole(ADMIN_GENERAL_ROLE, adminGeneral);
    // }

    // function migrateAdmin() external {
    //     address account = msg.sender;
    //     // Revoke deprecated role
    //     _checkRole(ADMIN_GENERAL_ROLE, account);
    //     _revokeRole(ADMIN_GENERAL_ROLE, account);
    //     // Grant new role
    //     _grantRole(ADMIN_ROLE, account);
    //     roles[ADMIN_ROLE].add(account);
    // }

    function grantRole(bytes32 role, address account) public override onlyRole(Roles.ADMIN_ROLE) {
        _grantRole(role, account);
        roles[role].add(account);
    }

    function revokeRole(bytes32 role, address account) public override onlyRole(Roles.ADMIN_ROLE) {
        _revokeRole(role, account);
        roles[role].remove(account);
    }

    function setExchange(address _exchange) external onlyRole(Roles.ADMIN_ROLE) {
        if (_exchange == address(0)) {
            revert Errors.ZeroAddress();
        }
        exchange = IExchange(_exchange);
    }

    function setClearingService(address _clearingService) external onlyRole(Roles.ADMIN_ROLE) {
        if (_clearingService == address(0)) {
            revert Errors.ZeroAddress();
        }
        clearingService = IClearingService(_clearingService);
    }

    function setOrderBook(address _orderBook) external onlyRole(Roles.ADMIN_ROLE) {
        if (_orderBook == address(0)) {
            revert Errors.ZeroAddress();
        }
        orderBook = IOrderBook(_orderBook);
    }

    function setPerpEngine(address _perp) external onlyRole(Roles.ADMIN_ROLE) {
        if (_perp == address(0)) {
            revert Errors.ZeroAddress();
        }
        perp = IPerp(_perp);
    }

    function setSpotEngine(address _spot) external onlyRole(Roles.ADMIN_ROLE) {
        if (_spot == address(0)) {
            revert Errors.ZeroAddress();
        }
        spot = ISpot(_spot);
    }

    function setBsx1000(address _bsx1000) external onlyRole(Roles.ADMIN_ROLE) {
        if (_bsx1000 == address(0)) {
            revert Errors.ZeroAddress();
        }
        bsx1000 = IBSX1000x(_bsx1000);
    }

    function setVaultManager(address _vaultManager) external onlyRole(Roles.ADMIN_ROLE) {
        if (_vaultManager == address(0)) {
            revert Errors.ZeroAddress();
        }
        vaultManager = IVaultManager(_vaultManager);
    }

    function getExchange() external view returns (IExchange) {
        return exchange;
    }

    function getClearingService() external view returns (IClearingService) {
        return clearingService;
    }

    function getOrderBook() external view returns (IOrderBook) {
        return orderBook;
    }

    function getSpotEngine() external view returns (ISpot) {
        return spot;
    }

    function getPerpEngine() external view returns (IPerp) {
        return perp;
    }

    function getBsx1000() external view returns (IBSX1000x) {
        return bsx1000;
    }

    function getVaultManager() external view returns (IVaultManager) {
        return vaultManager;
    }

    function getAccountsForRole(bytes32 role) external view returns (address[] memory accounts) {
        accounts = new address[](roles[role].length());
        for (uint256 i = 0; i < roles[role].length(); i++) {
            accounts[i] = roles[role].at(i);
        }
    }
}

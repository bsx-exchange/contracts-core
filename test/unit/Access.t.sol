// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {Access} from "src/Access.sol";
import {Errors} from "src/libraries/Errors.sol";

contract AccessTest is Test {
    address private admin = makeAddr("admin");
    address private account = makeAddr("account");
    Access private access;

    function setUp() public {
        access = new Access();
        access.initialize(admin);

        vm.startPrank(admin);
    }

    function test_initialize() public view {
        assertTrue(access.hasRole(access.GENERAL_ADMIN_ROLE(), admin));
    }

    function test_initialize_revertsIfSetZeroAddr() public {
        Access _access = new Access();
        vm.expectRevert(Errors.ZeroAddress.selector);
        _access.initialize(address(0));
    }

    function test_grantRoleForAccount() public {
        access.grantRoleForAccount(account, access.GENERAL_ADMIN_ROLE());
        assertTrue(access.hasRole(access.GENERAL_ADMIN_ROLE(), account));
    }

    function test_revokeRoleForAccount() public {
        access.grantRoleForAccount(account, access.GENERAL_ADMIN_ROLE());
        assertTrue(access.hasRole(access.GENERAL_ADMIN_ROLE(), account));

        access.revokeRoleForAccount(account, access.GENERAL_ADMIN_ROLE());
        assertFalse(access.hasRole(access.GENERAL_ADMIN_ROLE(), account));
    }

    function test_setExchange() public {
        address exchange = makeAddr("exchange");
        access.setExchange(exchange);
        assertEq(exchange, access.getExchange());
    }

    function test_setClearinghouse() public {
        address clearinghouse = makeAddr("clearinghouse");
        access.setClearinghouse(clearinghouse);
        assertEq(clearinghouse, access.getClearinghouse());
    }

    function test_setOrderbook() public {
        address orderbook = makeAddr("orderbook");
        access.setOrderbook(orderbook);
        assertEq(orderbook, access.getOrderbook());
    }

    function test_setExchange_revertsIfSetZeroAddr() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        access.setExchange(address(0));
    }

    function test_setClearinghouse_revertsIfSetZeroAddr() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        access.setClearinghouse(address(0));
    }

    function test_setOrderbook_revertsIfSetZeroAddr() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        access.setOrderbook(address(0));
    }
}

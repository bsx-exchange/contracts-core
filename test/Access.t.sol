// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {Access} from "src/access/Access.sol";
import {Errors} from "src/lib/Errors.sol";

contract AccessTest is Test {
    address private admin = makeAddr("admin");
    address private account = makeAddr("account");
    Access private access;

    function setUp() public {
        access = new Access();
        access.initialize(admin);
    }

    function test_initialize() public view {
        assertEq(access.hasRole(access.ADMIN_GENERAL_ROLE(), admin), true);
    }

    function test_initialize_revertsIfSetZeroAddr() public {
        Access _access = new Access();
        vm.expectRevert(Errors.ZeroAddress.selector);
        _access.initialize(address(0));
    }

    function test_grantRoleForAccount() public {
        vm.startPrank(admin);

        access.grantRoleForAccount(account, access.ADMIN_GENERAL_ROLE());
        assertEq(access.hasRole(access.ADMIN_GENERAL_ROLE(), account), true);
    }

    function test_grantRoleForAccount_revertsIfNotAdminGeneral() public {
        vm.expectRevert(Access.NotAdminGeneral.selector);
        access.grantRoleForAccount(account, keccak256("role"));
    }

    function test_revokeRoleForAccount() public {
        vm.startPrank(admin);

        access.grantRoleForAccount(account, access.ADMIN_GENERAL_ROLE());
        assertEq(access.hasRole(access.ADMIN_GENERAL_ROLE(), account), true);

        access.revokeRoleForAccount(account, access.ADMIN_GENERAL_ROLE());
        assertEq(access.hasRole(access.ADMIN_GENERAL_ROLE(), account), false);
    }

    function test_revokeRoleForAccount_revertsIfNotAdminGeneral() public {
        vm.expectRevert(Access.NotAdminGeneral.selector);
        access.revokeRoleForAccount(account, keccak256("role"));
    }

    function test_setExchange() public {
        vm.startPrank(admin);

        address exchange = makeAddr("exchange");
        access.setExchange(exchange);
        assertEq(exchange, access.getExchange());
    }

    function test_setExchange_revertsIfSetZeroAddr() public {
        vm.startPrank(admin);

        vm.expectRevert(Access.InvalidAddress.selector);
        access.setExchange(address(0));
    }

    function test_setExchange_revertsIfNotAdminGeneral() public {
        vm.expectRevert(Access.NotAdminGeneral.selector);
        access.setExchange(makeAddr("exchange"));
    }

    function test_setClearingService() public {
        vm.startPrank(admin);

        address clearinghouse = makeAddr("clearinghouse");
        access.setClearingService(clearinghouse);
        assertEq(clearinghouse, access.getClearingService());
    }

    function test_setClearingService_revertsIfSetZeroAddr() public {
        vm.startPrank(admin);

        vm.expectRevert(Access.InvalidAddress.selector);
        access.setClearingService(address(0));
    }

    function test_setClearingService_revertsIfNotAdminGeneral() public {
        vm.expectRevert(Access.NotAdminGeneral.selector);
        access.setClearingService(makeAddr("clearingService"));
    }

    function test_setOrderBook() public {
        vm.startPrank(admin);

        address orderbook = makeAddr("orderbook");
        access.setOrderBook(orderbook);
        assertEq(orderbook, access.getOrderBook());
    }

    function test_setOrderBook_revertsIfSetZeroAddr() public {
        vm.startPrank(admin);

        vm.expectRevert(Access.InvalidAddress.selector);
        access.setOrderBook(address(0));
    }

    function test_setOrderBook_revertsIfNotAdminGeneral() public {
        vm.expectRevert(Access.NotAdminGeneral.selector);
        access.setOrderBook(makeAddr("orderBook"));
    }
}

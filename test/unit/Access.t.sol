// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {Access} from "contracts/exchange/access/Access.sol";
import {Errors} from "contracts/exchange/lib/Errors.sol";
import {Roles} from "contracts/exchange/lib/Roles.sol";

contract AccessTest is Test {
    using stdStorage for StdStorage;

    address private admin = makeAddr("admin");
    address private account = makeAddr("account");
    Access private access;

    function setUp() public {
        access = new Access();

        stdstore.target(address(access)).sig("hasRole(bytes32,address)").with_key(Roles.ADMIN_ROLE).with_key(admin)
            .checked_write(true);
    }

    function test_grantRole() public {
        vm.startPrank(admin);

        access.grantRole(Roles.ADMIN_ROLE, account);
        assertEq(access.hasRole(Roles.ADMIN_ROLE, account), true);

        access.grantRole(Roles.BATCH_OPERATOR_ROLE, account);
        assertEq(access.hasRole(Roles.BATCH_OPERATOR_ROLE, account), true);

        access.grantRole(Roles.COLLATERAL_OPERATOR_ROLE, account);
        assertEq(access.hasRole(Roles.COLLATERAL_OPERATOR_ROLE, account), true);
    }

    function test_grantRole_revertsIfNotAdmin() public {
        bytes32 role = Roles.BATCH_OPERATOR_ROLE;
        address malicious = makeAddr("malicious");

        vm.prank(admin);
        access.grantRole(role, account);

        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, Roles.ADMIN_ROLE)
        );
        access.grantRole(role, malicious);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), Roles.ADMIN_ROLE
            )
        );
        access.grantRole(keccak256("role"), account);
    }

    function test_revokeRoleForAccount() public {
        vm.startPrank(admin);

        access.grantRole(Roles.ADMIN_ROLE, account);
        assertEq(access.hasRole(Roles.ADMIN_ROLE, account), true);

        access.revokeRole(Roles.ADMIN_ROLE, account);
        assertEq(access.hasRole(Roles.ADMIN_ROLE, account), false);
    }

    function test_revokeRoleForAccount_revertsIfNotAdmin() public {
        bytes32 role = Roles.BATCH_OPERATOR_ROLE;
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), Roles.ADMIN_ROLE
            )
        );
        access.revokeRole(role, account);
    }

    function test_setExchange() public {
        vm.startPrank(admin);

        address exchange = makeAddr("exchange");
        access.setExchange(exchange);
        assertEq(exchange, address(access.getExchange()));
    }

    function test_setExchange_revertsIfSetZeroAddr() public {
        vm.startPrank(admin);

        vm.expectRevert(Errors.ZeroAddress.selector);
        access.setExchange(address(0));
    }

    function test_setExchange_revertsIfNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), Roles.ADMIN_ROLE
            )
        );
        access.setExchange(makeAddr("exchange"));
    }

    function test_setClearingService() public {
        vm.startPrank(admin);

        address clearinghouse = makeAddr("clearinghouse");
        access.setClearingService(clearinghouse);
        assertEq(clearinghouse, address(access.getClearingService()));
    }

    function test_setClearingService_revertsIfSetZeroAddr() public {
        vm.startPrank(admin);

        vm.expectRevert(Errors.ZeroAddress.selector);
        access.setClearingService(address(0));
    }

    function test_setClearingService_revertsIfNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), Roles.ADMIN_ROLE
            )
        );
        access.setClearingService(makeAddr("clearingService"));
    }

    function test_setOrderBook() public {
        vm.startPrank(admin);

        address orderbook = makeAddr("orderbook");
        access.setOrderBook(orderbook);
        assertEq(orderbook, address(access.getOrderBook()));
    }

    function test_setOrderBook_revertsIfSetZeroAddr() public {
        vm.startPrank(admin);

        vm.expectRevert(Errors.ZeroAddress.selector);
        access.setOrderBook(address(0));
    }

    function test_setOrderBook_revertsIfNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), Roles.ADMIN_ROLE
            )
        );
        access.setOrderBook(makeAddr("orderBook"));
    }

    function test_setSpotEngine() public {
        vm.startPrank(admin);

        address spotEngine = makeAddr("spotEngine");
        access.setSpotEngine(spotEngine);
        assertEq(spotEngine, address(access.getSpotEngine()));
    }

    function test_setSpotEngine_revertsIfSetZeroAddr() public {
        vm.startPrank(admin);

        vm.expectRevert(Errors.ZeroAddress.selector);
        access.setSpotEngine(address(0));
    }

    function test_setSpotEngine_revertsIfNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), Roles.ADMIN_ROLE
            )
        );
        access.setSpotEngine(makeAddr("spotEngine"));
    }

    function test_setPerpEngine() public {
        vm.startPrank(admin);

        address perpEngine = makeAddr("perpEngine");
        access.setPerpEngine(perpEngine);
        assertEq(perpEngine, address(access.getPerpEngine()));
    }

    function test_setPerpEngine_revertsIfSetZeroAddr() public {
        vm.startPrank(admin);

        vm.expectRevert(Errors.ZeroAddress.selector);
        access.setPerpEngine(address(0));
    }

    function test_setPerpEngine_revertsIfNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), Roles.ADMIN_ROLE
            )
        );
        access.setPerpEngine(makeAddr("perpEngine"));
    }

    function test_setBsx1000() public {
        vm.startPrank(admin);

        address bsx1000 = makeAddr("bsx1000");
        access.setBsx1000(bsx1000);
        assertEq(bsx1000, address(access.getBsx1000()));
    }

    function test_setBsx1000_revertsIfSetZeroAddr() public {
        vm.startPrank(admin);

        vm.expectRevert(Errors.ZeroAddress.selector);
        access.setBsx1000(address(0));
    }

    function test_setBsx1000_revertsIfNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), Roles.ADMIN_ROLE
            )
        );
        access.setBsx1000(makeAddr("bsx1000"));
    }

    function test_setVaultManager() public {
        vm.startPrank(admin);

        address vaultManager = makeAddr("vaultManager");
        access.setVaultManager(vaultManager);
        assertEq(vaultManager, address(access.getVaultManager()));
    }

    function test_setVaultManager_revertsIfSetZeroAddr() public {
        vm.startPrank(admin);

        vm.expectRevert(Errors.ZeroAddress.selector);
        access.setVaultManager(address(0));
    }

    function test_setVaultManager_revertsIfNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), Roles.ADMIN_ROLE
            )
        );
        access.setVaultManager(makeAddr("vaultManager"));
    }

    function test_getAccountsForRole() public {
        vm.startPrank(admin);

        address[] memory accounts = access.getAccountsForRole(Roles.BATCH_OPERATOR_ROLE);
        assertEq(accounts.length, 0);

        for (uint256 i = 0; i < 5; i++) {
            address addr = makeAddr(string(abi.encode(i)));
            access.grantRole(Roles.BATCH_OPERATOR_ROLE, addr);
        }

        accounts = access.getAccountsForRole(Roles.BATCH_OPERATOR_ROLE);
        assertEq(accounts.length, 5);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(accounts[i], makeAddr(string(abi.encode(i))));
            assertEq(access.hasRole(Roles.BATCH_OPERATOR_ROLE, accounts[i]), true);
        }
    }
}

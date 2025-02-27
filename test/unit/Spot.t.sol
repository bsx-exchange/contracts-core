// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {ISpot, Spot} from "contracts/exchange/Spot.sol";
import {Access} from "contracts/exchange/access/Access.sol";
import {Errors} from "contracts/exchange/lib/Errors.sol";

contract SpotEngineTest is Test {
    using stdStorage for StdStorage;

    address private exchange = makeAddr("exchange");
    address private orderBook = makeAddr("orderBook");
    address private clearingService = makeAddr("clearingService");

    Access private access;
    Spot private spotEngine;

    function setUp() public {
        access = new Access();
        stdstore.target(address(access)).sig("hasRole(bytes32,address)").with_key(access.ADMIN_ROLE()).with_key(
            address(this)
        ).checked_write(true);

        access.setExchange(exchange);
        access.setClearingService(clearingService);
        access.setOrderBook(orderBook);

        spotEngine = new Spot();
        stdstore.target(address(spotEngine)).sig("access()").checked_write(address(access));
    }

    function test_authorized() public {
        address anyAddr = makeAddr("anyAddress");
        int256 anyAmount = 100;

        vm.prank(exchange);
        spotEngine.updateBalance(anyAddr, anyAddr, anyAmount);

        vm.prank(clearingService);
        spotEngine.updateBalance(anyAddr, anyAddr, anyAmount);

        vm.prank(orderBook);
        spotEngine.updateBalance(anyAddr, anyAddr, anyAmount);
    }

    function test_updateBalance() public {
        vm.startPrank(exchange);

        address token = makeAddr("token");
        address[] memory accounts = new address[](2);
        accounts[0] = makeAddr("account_0");
        accounts[1] = makeAddr("account_1");

        for (uint256 i = 0; i < accounts.length; i++) {
            assertEq(spotEngine.getBalance(token, accounts[i]), 0);

            int256 amount0 = 100;
            vm.expectEmit(address(spotEngine));
            emit ISpot.UpdateBalance(accounts[i], token, amount0, amount0);
            spotEngine.updateBalance(accounts[i], token, amount0);
            assertEq(spotEngine.getBalance(token, accounts[i]), amount0);

            int256 amount1 = -300;
            vm.expectEmit(address(spotEngine));
            emit ISpot.UpdateBalance(accounts[i], token, amount1, amount0 + amount1);
            spotEngine.updateBalance(accounts[i], token, amount1);
            assertEq(spotEngine.getBalance(token, accounts[i]), amount0 + amount1);
        }
    }

    function test_updateBalance_revertsWhenUnauthorized() public {
        address anyAddr = makeAddr("anyAddress");
        vm.expectRevert(Errors.Unauthorized.selector);
        spotEngine.updateBalance(anyAddr, anyAddr, 0);
    }

    function test_updateTotalBalance_increase() public {
        vm.startPrank(exchange);

        address token = makeAddr("token");
        spotEngine.updateTotalBalance(token, 100);
        assertEq(spotEngine.getTotalBalance(token), 100);
    }

    function test_updateTotalBalance_increase_revertsWhenUnauthorized() public {
        address token = makeAddr("token");
        vm.expectRevert(Errors.Unauthorized.selector);
        spotEngine.updateTotalBalance(token, 100);
    }

    function test_updateTotalBalance_decrease() public {
        vm.startPrank(exchange);

        address token = makeAddr("token");
        spotEngine.updateTotalBalance(token, 100);
        assertEq(spotEngine.getTotalBalance(token), 100);

        spotEngine.updateTotalBalance(token, -50);
        assertEq(spotEngine.getTotalBalance(token), 100 - 50);
    }

    function test_updateTotalBalance_decrease_revertsWhenUnauthorized() public {
        address token = makeAddr("token");
        vm.expectRevert(Errors.Unauthorized.selector);
        spotEngine.updateTotalBalance(token, -100);
    }
}

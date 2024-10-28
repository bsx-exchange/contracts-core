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
        ISpot.AccountDelta[] memory deltas = new ISpot.AccountDelta[](1);
        deltas[0] = ISpot.AccountDelta({token: anyAddr, account: anyAddr, amount: anyAmount});
        vm.prank(exchange);
        spotEngine.modifyAccount(deltas);

        vm.prank(clearingService);
        spotEngine.modifyAccount(deltas);

        vm.prank(orderBook);
        spotEngine.modifyAccount(deltas);
    }

    function test_modifyAccount() public {
        vm.startPrank(exchange);

        address token = makeAddr("token");
        address[] memory accounts = new address[](2);
        accounts[0] = makeAddr("account_0");
        accounts[1] = makeAddr("account_1");

        ISpot.AccountDelta[] memory deltas = new ISpot.AccountDelta[](1);

        for (uint256 i = 0; i < accounts.length; i++) {
            assertEq(spotEngine.getBalance(token, accounts[i]), 0);

            int256 amount0 = 100;
            ISpot.AccountDelta memory delta0 = ISpot.AccountDelta({token: token, account: accounts[i], amount: amount0});
            deltas[0] = delta0;
            vm.expectEmit(address(spotEngine));
            emit ISpot.UpdateBalance(accounts[i], token, amount0, amount0);
            spotEngine.modifyAccount(deltas);
            assertEq(spotEngine.getBalance(token, accounts[i]), amount0);

            int256 amount1 = -300;
            ISpot.AccountDelta memory delta1 = ISpot.AccountDelta({token: token, account: accounts[i], amount: amount1});
            deltas[0] = delta1;
            vm.expectEmit(address(spotEngine));
            emit ISpot.UpdateBalance(accounts[i], token, amount1, amount0 + amount1);
            spotEngine.modifyAccount(deltas);
            assertEq(spotEngine.getBalance(token, accounts[i]), amount0 + amount1);
        }
    }

    function test_modifyAccount_revertsWhenUnauthorized() public {
        ISpot.AccountDelta[] memory deltas = new ISpot.AccountDelta[](0);
        vm.expectRevert(Errors.Unauthorized.selector);
        spotEngine.modifyAccount(deltas);
    }

    function test_setTotalBalance_increase() public {
        vm.startPrank(exchange);

        address token = makeAddr("token");
        spotEngine.setTotalBalance(token, 100, true);
        assertEq(spotEngine.getTotalBalance(token), 100);
    }

    function test_setTotalBalance_increase_revertsWhenUnauthorized() public {
        address token = makeAddr("token");
        vm.expectRevert(Errors.Unauthorized.selector);
        spotEngine.setTotalBalance(token, 100, true);
    }

    function test_setTotalBalance_decrease() public {
        vm.startPrank(exchange);

        address token = makeAddr("token");
        spotEngine.setTotalBalance(token, 100, true);
        assertEq(spotEngine.getTotalBalance(token), 100);

        spotEngine.setTotalBalance(token, 50, false);
        assertEq(spotEngine.getTotalBalance(token), 100 - 50);
    }

    function test_setTotalBalance_decrease_revertsWhenUnauthorized() public {
        address token = makeAddr("token");
        vm.expectRevert(Errors.Unauthorized.selector);
        spotEngine.setTotalBalance(token, 100, false);
    }
}

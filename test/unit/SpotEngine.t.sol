// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {Access} from "src/Access.sol";
import {SpotEngine} from "src/SpotEngine.sol";
import {ISpotEngine} from "src/interfaces/ISpotEngine.sol";
import {Errors} from "src/libraries/Errors.sol";

contract SpotEngineTest is Test {
    address private exchange = makeAddr("exchange");
    address private orderbook = makeAddr("orderbook");
    address private clearinghouse = makeAddr("clearinghouse");

    Access private access;
    SpotEngine private spotEngine;

    function setUp() public {
        access = new Access();
        access.initialize(address(this));
        access.setExchange(exchange);
        access.setClearinghouse(clearinghouse);
        access.setOrderbook(orderbook);

        spotEngine = new SpotEngine();
        spotEngine.initialize(address(access));
    }

    function test_initialize() public view {
        assertEq(address(spotEngine.access()), address(access));
    }

    function test_initialize_revertsIfSetZeroAddr() public {
        SpotEngine _spotEngine = new SpotEngine();
        vm.expectRevert(Errors.ZeroAddress.selector);
        _spotEngine.initialize(address(0));
    }

    function test_authorized() public {
        address anyAddr = makeAddr("anyAddress");
        int256 anyAmount = 100;
        vm.prank(exchange);
        spotEngine.updateAccount(anyAddr, anyAddr, anyAmount);

        vm.prank(clearinghouse);
        spotEngine.updateAccount(anyAddr, anyAddr, anyAmount);

        vm.prank(orderbook);
        spotEngine.updateAccount(anyAddr, anyAddr, anyAmount);
    }

    function test_updateAccount() public {
        vm.startPrank(exchange);

        address token = makeAddr("token");
        address[] memory accounts = new address[](2);
        accounts[0] = makeAddr("account_0");
        accounts[1] = makeAddr("account_1");

        for (uint256 i = 0; i < accounts.length; i++) {
            assertEq(spotEngine.getBalance(accounts[i], token), 0);

            int256 amount0 = 100;
            vm.expectEmit(address(spotEngine));
            emit ISpotEngine.UpdateAccount(accounts[i], token, amount0, amount0);
            spotEngine.updateAccount(accounts[i], token, amount0);
            assertEq(spotEngine.getBalance(accounts[i], token), amount0);

            int256 amount1 = -300;
            vm.expectEmit(address(spotEngine));
            emit ISpotEngine.UpdateAccount(accounts[i], token, amount1, amount0 + amount1);
            spotEngine.updateAccount(accounts[i], token, amount1);
            assertEq(spotEngine.getBalance(accounts[i], token), amount0 + amount1);
        }
    }

    function test_updateAccount_revertsWhenUnauthorized() public {
        address account = makeAddr("account");
        address token = makeAddr("token");
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        spotEngine.updateAccount(account, token, 100);
    }

    function test_increaseTokenBalance() public {
        vm.startPrank(exchange);

        address token = makeAddr("token");
        spotEngine.increaseTotalBalance(token, 100);
        assertEq(spotEngine.getTotalBalance(token), 100);
    }

    function test_increaseTokenBalance_revertsWhenUnauthorized() public {
        address token = makeAddr("token");
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        spotEngine.increaseTotalBalance(token, 100);
    }

    function test_decreaseTokenBalance() public {
        vm.startPrank(exchange);

        address token = makeAddr("token");
        spotEngine.increaseTotalBalance(token, 100);
        assertEq(spotEngine.getTotalBalance(token), 100);

        spotEngine.decreaseTotalBalance(token, 50);
        assertEq(spotEngine.getTotalBalance(token), 100 - 50);
    }

    function test_decreaseTokenBalance_revertsWhenUnauthorized() public {
        address token = makeAddr("token");
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        spotEngine.decreaseTotalBalance(token, 100);
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {Access} from "src/Access.sol";
import {Clearinghouse} from "src/Clearinghouse.sol";
import {SpotEngine} from "src/SpotEngine.sol";
import {IClearinghouse} from "src/interfaces/IClearinghouse.sol";
import {IExchange} from "src/interfaces/IExchange.sol";
import {Errors} from "src/libraries/Errors.sol";

contract ClearinghouseTest is Test {
    address private exchange = makeAddr("exchange");
    address private account = makeAddr("account");
    address private token = makeAddr("token");

    Access private access;
    SpotEngine private spotEngine;
    Clearinghouse private clearinghouse;

    function setUp() public {
        access = new Access();
        access.initialize(address(this));
        access.setExchange(exchange);

        spotEngine = new SpotEngine();
        spotEngine.initialize(address(access));

        vm.mockCall(exchange, abi.encodeWithSelector(IExchange.spotEngine.selector), abi.encode(spotEngine));

        clearinghouse = new Clearinghouse();
        clearinghouse.initialize(address(access));

        access.setClearinghouse(address(clearinghouse));
    }

    function test_initialize() public view {
        assertEq(address(clearinghouse.access()), address(access));
    }

    function test_initialize_revertsIfSetZeroAddr() public {
        Clearinghouse _clearinghouse = new Clearinghouse();
        vm.expectRevert(Errors.ZeroAddress.selector);
        _clearinghouse.initialize(address(0));
    }

    function test_deposit() public {
        vm.startPrank(exchange);

        uint256 amount = 100;
        clearinghouse.deposit(account, token, amount);
        assertEq(spotEngine.getBalance(account, token), int256(amount));
        assertEq(spotEngine.getTotalBalance(token), amount);
    }

    function test_deposit_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        clearinghouse.deposit(address(0x1), address(0x2), 10);
    }

    function test_withdraw() public {
        vm.startPrank(exchange);

        uint256 amount = 100;
        clearinghouse.deposit(account, token, amount);
        assertEq(spotEngine.getBalance(account, token), int256(amount));
        assertEq(spotEngine.getTotalBalance(token), amount);

        clearinghouse.withdraw(account, token, amount);
        assertEq(spotEngine.getBalance(account, token), int256(0));
    }

    function test_withdraw_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        clearinghouse.withdraw(address(0x1), address(0x2), 10);
    }

    function test_depositInsuranceFund() public {
        vm.startPrank(exchange);

        uint256 amount = 100;
        clearinghouse.depositInsuranceFund(amount);
        assertEq(clearinghouse.getInsuranceFund(), amount);
    }

    function test_depositInsuranceFund_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        clearinghouse.depositInsuranceFund(10);
    }

    function test_withdrawInsuranceFund() public {
        vm.startPrank(exchange);

        uint256 amount = 100;
        clearinghouse.depositInsuranceFund(amount);
        assertEq(clearinghouse.getInsuranceFund(), amount);

        clearinghouse.withdrawInsuranceFund(amount);
        assertEq(clearinghouse.getInsuranceFund(), 0);
    }

    function test_withdrawInsuranceFund_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        clearinghouse.withdrawInsuranceFund(10);
    }

    function test_withdrawInsuranceFund_revertsIfInsufficientFund() public {
        vm.startPrank(exchange);

        uint256 amount = 100;
        clearinghouse.depositInsuranceFund(amount);
        assertEq(clearinghouse.getInsuranceFund(), amount);

        uint256 withdrawAmount = amount + 1;
        vm.expectRevert(abi.encodeWithSelector(IClearinghouse.InsufficientFund.selector, amount, withdrawAmount));
        clearinghouse.withdrawInsuranceFund(withdrawAmount);
    }

    function test_coverLoss() public {
        vm.startPrank(exchange);

        uint256 fund = 1000;
        clearinghouse.depositInsuranceFund(fund);

        int256 loss = -100;
        spotEngine.updateAccount(account, token, loss);

        clearinghouse.coverLossWithInsuranceFund(account, token);
        assertEq(spotEngine.getBalance(account, token), int256(0));
        assertEq(clearinghouse.getInsuranceFund(), fund - uint256(-loss));
    }

    function test_coverLoss_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        clearinghouse.coverLossWithInsuranceFund(address(0x1), address(0x2));
    }

    function test_coverLoss_revertsIfNoNeedToCover() public {
        vm.startPrank(exchange);

        int256 balance = 100;
        spotEngine.updateAccount(account, token, balance);

        vm.expectRevert(abi.encodeWithSelector(IClearinghouse.NoNeedToCover.selector, account, token, balance));
        clearinghouse.coverLossWithInsuranceFund(account, token);
    }

    function test_coverLoss_revertsIfInsufficientFund() public {
        vm.startPrank(exchange);

        uint256 fund = 100;
        clearinghouse.depositInsuranceFund(fund);

        int256 loss = -1000;
        spotEngine.updateAccount(account, token, loss);

        vm.expectRevert(abi.encodeWithSelector(IClearinghouse.InsufficientFund.selector, fund, uint256(-loss)));
        clearinghouse.coverLossWithInsuranceFund(account, token);
    }
}

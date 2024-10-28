// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {ClearingService, IClearingService} from "contracts/exchange/ClearingService.sol";
import {OrderBook} from "contracts/exchange/OrderBook.sol";
import {ISpot, Spot} from "contracts/exchange/Spot.sol";
import {Access} from "contracts/exchange/access/Access.sol";
import {Errors} from "contracts/exchange/lib/Errors.sol";

contract ClearingServiceTest is Test {
    using stdStorage for StdStorage;

    address private exchange = makeAddr("exchange");
    address private account = makeAddr("account");
    address private token = makeAddr("token");

    Access private access;
    OrderBook private orderbook;
    Spot private spotEngine;
    ClearingService private clearingService;

    function setUp() public {
        access = new Access();
        stdstore.target(address(access)).sig("hasRole(bytes32,address)").with_key(access.ADMIN_ROLE()).with_key(
            address(this)
        ).checked_write(true);

        spotEngine = new Spot();
        stdstore.target(address(spotEngine)).sig("access()").checked_write(address(access));

        clearingService = new ClearingService();
        stdstore.target(address(clearingService)).sig("access()").checked_write(address(access));

        orderbook = new OrderBook();
        stdstore.target(address(orderbook)).sig("clearingService()").checked_write(address(clearingService));
        stdstore.target(address(orderbook)).sig("spotEngine()").checked_write(address(spotEngine));
        stdstore.target(address(orderbook)).sig("access()").checked_write(address(access));
        stdstore.target(address(orderbook)).sig("getCollateralToken()").checked_write(token);

        access.setExchange(exchange);
        access.setOrderBook(address(orderbook));
        access.setSpotEngine(address(spotEngine));
        access.setClearingService(address(clearingService));
    }

    function test_deposit() public {
        vm.startPrank(exchange);

        uint256 amount = 100;
        clearingService.deposit(account, amount, token, spotEngine);
        assertEq(spotEngine.getBalance(token, account), int256(amount));
        assertEq(spotEngine.getTotalBalance(token), amount);
    }

    function test_deposit_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        clearingService.deposit(account, 10, token, spotEngine);
    }

    function test_withdraw() public {
        vm.startPrank(exchange);

        uint256 amount = 100;
        clearingService.deposit(account, amount, token, spotEngine);
        assertEq(spotEngine.getBalance(token, account), int256(amount));
        assertEq(spotEngine.getTotalBalance(token), amount);

        clearingService.withdraw(account, amount, token, spotEngine);
        assertEq(spotEngine.getBalance(token, account), int256(0));
    }

    function test_withdraw_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        clearingService.withdraw(account, 10, token, spotEngine);
    }

    function test_depositInsuranceFund() public {
        vm.startPrank(exchange);

        uint256 amount = 100;
        clearingService.depositInsuranceFund(amount);
        assertEq(clearingService.getInsuranceFundBalance(), amount);
    }

    function test_depositInsuranceFund_revertsIfZeroAmount() public {
        vm.startPrank(exchange);

        vm.expectRevert(Errors.ClearingService_ZeroAmount.selector);
        clearingService.depositInsuranceFund(0);
    }

    function test_depositInsuranceFund_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        clearingService.depositInsuranceFund(10);
    }

    function test_withdrawInsuranceFundEmergency() public {
        vm.startPrank(exchange);

        uint256 amount = 100;
        clearingService.depositInsuranceFund(amount);
        assertEq(clearingService.getInsuranceFundBalance(), amount);

        clearingService.withdrawInsuranceFundEmergency(amount);
        assertEq(clearingService.getInsuranceFundBalance(), 0);
    }

    function test_withdrawInsuranceFundEmergency_revertsIfZeroAmount() public {
        vm.startPrank(exchange);

        vm.expectRevert(Errors.ClearingService_ZeroAmount.selector);
        clearingService.withdrawInsuranceFundEmergency(0);
    }

    function test_withdrawInsuranceFundEmergency_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        clearingService.withdrawInsuranceFundEmergency(10);
    }

    function test_withdrawInsuranceFundEmergency_revertsIfInsufficientFund() public {
        vm.startPrank(exchange);

        uint256 amount = 100;
        clearingService.depositInsuranceFund(amount);
        assertEq(clearingService.getInsuranceFundBalance(), amount);

        uint256 withdrawAmount = amount + 1;
        vm.expectRevert(
            abi.encodeWithSelector(Errors.ClearingService_InsufficientFund.selector, withdrawAmount, amount)
        );
        clearingService.withdrawInsuranceFundEmergency(withdrawAmount);
    }

    function test_collectLiquidationFee() public {
        vm.startPrank(exchange);

        uint64 nonce = 10;
        uint256 amount = 100;
        vm.expectEmit();
        emit IClearingService.CollectLiquidationFee(account, nonce, amount, amount);
        clearingService.collectLiquidationFee(account, nonce, amount);
        assertEq(clearingService.getInsuranceFundBalance(), amount);
    }

    function test_collectLiquidationFee_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Unauthorized.selector);

        uint64 nonce = 10;
        uint256 amount = 100;
        clearingService.collectLiquidationFee(account, nonce, amount);
    }

    function test_coverLossWithInsuranceFund() public {
        vm.startPrank(exchange);

        uint256 fund = 1000;
        clearingService.depositInsuranceFund(fund);

        int256 loss = -100;
        ISpot.AccountDelta[] memory deltas = new ISpot.AccountDelta[](1);
        deltas[0] = ISpot.AccountDelta(token, account, loss);
        spotEngine.modifyAccount(deltas);

        clearingService.coverLossWithInsuranceFund(account, uint256(-loss));
        assertEq(spotEngine.getBalance(account, token), int256(0));
        assertEq(clearingService.getInsuranceFundBalance(), fund - uint256(-loss));
    }

    function test_coverLossWithInsuranceFund_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        clearingService.coverLossWithInsuranceFund(account, 10);
    }

    function test_coverLossWithInsuranceFund_revertsIfSpotNotNegative() public {
        vm.startPrank(exchange);

        uint256 balance = 100;
        clearingService.depositInsuranceFund(balance);

        ISpot.AccountDelta[] memory deltas = new ISpot.AccountDelta[](1);
        deltas[0] = ISpot.AccountDelta(token, account, int256(balance));
        spotEngine.modifyAccount(deltas);

        vm.expectRevert(abi.encodeWithSelector(Errors.ClearingService_NoLoss.selector, account, int256(balance)));
        clearingService.coverLossWithInsuranceFund(account, 10);
    }

    function test_coverLossWithInsuranceFund_revertsIfInsufficientFund() public {
        vm.startPrank(exchange);

        uint256 fund = 100;
        clearingService.depositInsuranceFund(fund);

        int256 loss = -1000;
        ISpot.AccountDelta[] memory deltas = new ISpot.AccountDelta[](1);
        deltas[0] = ISpot.AccountDelta(token, account, loss);
        spotEngine.modifyAccount(deltas);

        vm.expectRevert(abi.encodeWithSelector(Errors.ClearingService_InsufficientFund.selector, uint256(-loss), fund));
        clearingService.coverLossWithInsuranceFund(account, uint256(-loss));
    }
}

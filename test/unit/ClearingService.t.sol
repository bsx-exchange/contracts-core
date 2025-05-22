// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {ClearingService, IClearingService} from "contracts/exchange/ClearingService.sol";
import {OrderBook} from "contracts/exchange/OrderBook.sol";
import {Spot} from "contracts/exchange/Spot.sol";
import {Access} from "contracts/exchange/access/Access.sol";
import {Errors} from "contracts/exchange/lib/Errors.sol";
import {Roles} from "contracts/exchange/lib/Roles.sol";
import {BSX_TOKEN, USDC_TOKEN} from "contracts/exchange/share/Constants.sol";

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
        stdstore.target(address(access)).sig("hasRole(bytes32,address)").with_key(Roles.ADMIN_ROLE).with_key(
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
        clearingService.deposit(account, amount, token);
        assertEq(spotEngine.getBalance(token, account), int256(amount));
        assertEq(spotEngine.getTotalBalance(token), amount);
    }

    function test_deposit_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        clearingService.deposit(account, 10, token);
    }

    function test_withdraw() public {
        vm.startPrank(exchange);

        uint256 amount = 100;
        clearingService.deposit(account, amount, token);
        assertEq(spotEngine.getBalance(token, account), int256(amount));
        assertEq(spotEngine.getTotalBalance(token), amount);

        clearingService.withdraw(account, amount, token);
        assertEq(spotEngine.getBalance(token, account), int256(0));
    }

    function test_withdraw_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        clearingService.withdraw(account, 10, token);
    }

    function test_depositInsuranceFund() public {
        vm.startPrank(exchange);

        uint256 usdcAmount = 100;
        clearingService.depositInsuranceFund(USDC_TOKEN, usdcAmount);

        uint256 bsxAmount = 200;
        clearingService.depositInsuranceFund(BSX_TOKEN, bsxAmount);

        IClearingService.InsuranceFund memory insuranceFund = clearingService.getInsuranceFundBalance();
        assertEq(insuranceFund.inUSDC, usdcAmount);
        assertEq(insuranceFund.inBSX, bsxAmount);
    }

    function test_depositInsuranceFund_revertsIfZeroAmount() public {
        vm.startPrank(exchange);

        vm.expectRevert(Errors.ClearingService_ZeroAmount.selector);
        clearingService.depositInsuranceFund(USDC_TOKEN, 0);
    }

    function test_depositInsuranceFund_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        clearingService.depositInsuranceFund(USDC_TOKEN, 10);
    }

    function test_depositInsuranceFund_revertsWhenInvalidToken() public {
        vm.prank(exchange);

        vm.expectRevert(abi.encodeWithSelector(Errors.ClearingService_InvalidToken.selector, token));
        clearingService.depositInsuranceFund(token, 10);
    }

    function test_withdrawInsuranceFund() public {
        vm.startPrank(exchange);

        uint256 usdcAmount = 100;
        clearingService.depositInsuranceFund(USDC_TOKEN, usdcAmount);

        uint256 bsxAmount = 200;
        clearingService.depositInsuranceFund(BSX_TOKEN, bsxAmount);

        IClearingService.InsuranceFund memory insuranceFund = clearingService.getInsuranceFundBalance();
        assertEq(insuranceFund.inUSDC, usdcAmount);
        assertEq(insuranceFund.inBSX, bsxAmount);

        clearingService.withdrawInsuranceFund(USDC_TOKEN, 50);
        clearingService.withdrawInsuranceFund(BSX_TOKEN, 80);

        insuranceFund = clearingService.getInsuranceFundBalance();
        assertEq(insuranceFund.inUSDC, usdcAmount - 50);
        assertEq(insuranceFund.inBSX, bsxAmount - 80);
    }

    function test_withdrawInsuranceFund_revertsIfZeroAmount() public {
        vm.startPrank(exchange);

        vm.expectRevert(Errors.ClearingService_ZeroAmount.selector);
        clearingService.withdrawInsuranceFund(USDC_TOKEN, 0);
    }

    function test_withdrawInsuranceFund_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        clearingService.withdrawInsuranceFund(USDC_TOKEN, 10);
    }

    function test_withdrawInsuranceFund_revertsIfInsufficientFund() public {
        vm.startPrank(exchange);

        uint256 amount = 100;
        clearingService.depositInsuranceFund(USDC_TOKEN, amount);
        clearingService.depositInsuranceFund(BSX_TOKEN, amount);

        uint256 withdrawAmount = amount + 1;

        vm.expectRevert();
        clearingService.withdrawInsuranceFund(USDC_TOKEN, withdrawAmount);

        vm.expectRevert();
        clearingService.withdrawInsuranceFund(BSX_TOKEN, withdrawAmount);
    }

    function test_withdrawInsuranceFund_revertsWhenInvalidToken() public {
        vm.prank(exchange);

        vm.expectRevert(abi.encodeWithSelector(Errors.ClearingService_InvalidToken.selector, token));
        clearingService.withdrawInsuranceFund(token, 10);
    }

    function test_collectLiquidationFee() public {
        vm.startPrank(exchange);

        uint64 nonce = 10;
        uint256 amount = 100;
        bool isFeeInBSX = false;

        IClearingService.InsuranceFund memory expectedInsuranceFund =
            IClearingService.InsuranceFund({inUSDC: 100, inBSX: 0});

        vm.expectEmit();
        emit IClearingService.CollectLiquidationFee(account, nonce, amount, isFeeInBSX, expectedInsuranceFund);
        clearingService.collectLiquidationFee(account, nonce, amount, isFeeInBSX);

        IClearingService.InsuranceFund memory insuranceFund = clearingService.getInsuranceFundBalance();
        assertEq(insuranceFund.inUSDC, 100);
        assertEq(insuranceFund.inBSX, 0);

        nonce = 12;
        amount = 200;
        isFeeInBSX = true;

        expectedInsuranceFund = IClearingService.InsuranceFund({inUSDC: 100, inBSX: 200});

        vm.expectEmit();
        emit IClearingService.CollectLiquidationFee(account, nonce, amount, isFeeInBSX, expectedInsuranceFund);
        clearingService.collectLiquidationFee(account, nonce, amount, isFeeInBSX);

        insuranceFund = clearingService.getInsuranceFundBalance();
        assertEq(insuranceFund.inUSDC, 100);
        assertEq(insuranceFund.inBSX, 200);
    }

    function test_collectLiquidationFee_revertsWhenUnauthorized() public {
        uint64 nonce = 10;
        uint256 amount = 100;
        bool isFeeInBSX = false;

        vm.expectRevert(Errors.Unauthorized.selector);
        clearingService.collectLiquidationFee(account, nonce, amount, isFeeInBSX);
    }

    function test_coverLossWithInsuranceFund() public {
        vm.startPrank(exchange);

        uint256 fund = 1000;
        clearingService.depositInsuranceFund(USDC_TOKEN, fund);

        int256 loss = -100;
        spotEngine.updateBalance(account, USDC_TOKEN, loss);

        clearingService.coverLossWithInsuranceFund(account, uint256(-loss));
        assertEq(spotEngine.getBalance(account, USDC_TOKEN), int256(0));

        IClearingService.InsuranceFund memory insuranceFund = clearingService.getInsuranceFundBalance();
        assertEq(insuranceFund.inUSDC, fund - uint256(-loss));
    }

    function test_coverLossWithInsuranceFund_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        clearingService.coverLossWithInsuranceFund(account, 10);
    }

    function test_coverLossWithInsuranceFund_revertsIfSpotNotNegative() public {
        vm.startPrank(exchange);

        uint256 balance = 100;
        clearingService.depositInsuranceFund(USDC_TOKEN, balance);
        spotEngine.updateBalance(account, USDC_TOKEN, int256(balance));

        vm.expectRevert(abi.encodeWithSelector(Errors.ClearingService_NoLoss.selector, account, int256(balance)));
        clearingService.coverLossWithInsuranceFund(account, 10);
    }

    function test_coverLossWithInsuranceFund_revertsIfInsufficientFund() public {
        vm.startPrank(exchange);

        uint256 fund = 100;
        clearingService.depositInsuranceFund(USDC_TOKEN, fund);

        int256 loss = -1000;
        spotEngine.updateBalance(account, USDC_TOKEN, loss);

        vm.expectRevert(abi.encodeWithSelector(Errors.ClearingService_InsufficientFund.selector, uint256(-loss), fund));
        clearingService.coverLossWithInsuranceFund(account, uint256(-loss));
    }
}

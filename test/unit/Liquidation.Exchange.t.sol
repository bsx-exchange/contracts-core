// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {ERC20Simple} from "../mock/ERC20Simple.sol";
import {UniversalRouter} from "../mock/UniversalRouter.sol";

import {ClearingService} from "contracts/exchange/ClearingService.sol";
import {Exchange} from "contracts/exchange/Exchange.sol";
import {OrderBook} from "contracts/exchange/OrderBook.sol";
import {ISpot, Spot} from "contracts/exchange/Spot.sol";
import {VaultManager} from "contracts/exchange/VaultManager.sol";
import {Access} from "contracts/exchange/access/Access.sol";
import {ILiquidation} from "contracts/exchange/interfaces/ILiquidation.sol";
import {Errors} from "contracts/exchange/lib/Errors.sol";

contract LiquidationExchangeTest is Test {
    using stdStorage for StdStorage;

    address private admin = makeAddr("admin");
    address private liquidator = makeAddr("sequencer");

    Access private access;
    Exchange private exchange;
    ClearingService private clearingService;
    OrderBook private orderbook;
    Spot private spotEngine;

    ERC20Simple private underlyingAsset = new ERC20Simple(6);

    UniversalRouter private mockUniversalRouter;

    function setUp() public {
        vm.startPrank(admin);

        access = new Access();
        stdstore.target(address(access)).sig("hasRole(bytes32,address)").with_key(access.ADMIN_ROLE()).with_key(admin)
            .checked_write(true);
        access.grantRole(access.GENERAL_ROLE(), admin);
        access.grantRole(access.COLLATERAL_OPERATOR_ROLE(), liquidator);

        clearingService = new ClearingService();
        stdstore.target(address(clearingService)).sig("access()").checked_write(address(access));

        spotEngine = new Spot();
        stdstore.target(address(spotEngine)).sig("access()").checked_write(address(access));

        orderbook = new OrderBook();
        stdstore.target(address(orderbook)).sig("clearingService()").checked_write(address(clearingService));
        stdstore.target(address(orderbook)).sig("spotEngine()").checked_write(address(spotEngine));
        stdstore.target(address(orderbook)).sig("access()").checked_write(address(access));
        stdstore.target(address(orderbook)).sig("getCollateralToken()").checked_write(address(underlyingAsset));

        exchange = new Exchange();

        access.setExchange(address(exchange));
        access.setClearingService(address(clearingService));
        access.setOrderBook(address(orderbook));
        access.setSpotEngine(address(spotEngine));

        mockUniversalRouter = new UniversalRouter(address(exchange));

        stdstore.target(address(exchange)).sig("access()").checked_write(address(access));
        stdstore.target(address(exchange)).sig("book()").checked_write(address(orderbook));
        stdstore.target(address(exchange)).sig("clearingService()").checked_write(address(clearingService));
        stdstore.target(address(exchange)).sig("spotEngine()").checked_write(address(spotEngine));
        stdstore.target(address(exchange)).sig("universalRouter()").checked_write(address(mockUniversalRouter));
        exchange.setCanDeposit(true);

        VaultManager vaultManager = new VaultManager();
        stdstore.target(address(vaultManager)).sig("access()").checked_write(address(access));
        access.setVaultManager(address(vaultManager));

        vm.stopPrank();
    }

    function test_liquidateCollateralBatch() public {
        ERC20Simple liquidationAsset = new ERC20Simple(8);
        address user = makeAddr("user");

        vm.prank(admin);
        exchange.addSupportedToken(address(liquidationAsset));
        liquidationAsset.mint(user, 1000 * 1e8);

        vm.startPrank(user);
        liquidationAsset.approve(address(exchange), 1000 * 1e8);
        exchange.deposit(address(liquidationAsset), 1000 * 1e18);
        vm.stopPrank();

        assertEq(exchange.balanceOf(user, address(liquidationAsset)), 1000 * 1e18);
        assertEq(liquidationAsset.balanceOf(address(exchange)), 1000 * 1e8);

        // e.g. 1 liquidation asset = 500 underlying asset
        uint256 liquidationAmount = 1000 * 1e8;
        uint256 receivedAmount = 1000 * 500 * 1e6;

        bytes memory commands = abi.encodePacked(bytes1(0x00));
        bytes[] memory inputs = new bytes[](1);
        // mock input
        inputs[0] = abi.encode(address(liquidationAsset), liquidationAmount, address(underlyingAsset), receivedAmount);

        ILiquidation.ExecutionParams[] memory executions = new ILiquidation.ExecutionParams[](1);
        executions[0] = ILiquidation.ExecutionParams({
            liquidationAsset: address(liquidationAsset),
            commands: commands,
            inputs: inputs
        });

        ILiquidation.LiquidationParams[] memory params = new ILiquidation.LiquidationParams[](1);
        uint256 nonce = 5;
        uint16 feePips = 500; // 5%
        params[0] =
            ILiquidation.LiquidationParams({account: user, feePips: feePips, nonce: nonce, executions: executions});

        uint256 fee = 1000 * 500 * 1e18 * 5 / 100;

        vm.prank(liquidator);
        vm.expectEmit(address(exchange));
        emit ILiquidation.LiquidateAccount(user, nonce, ILiquidation.AccountLiquidationStatus.Success);
        emit ILiquidation.LiquidateCollateral(
            user,
            nonce,
            address(liquidationAsset),
            ILiquidation.CollateralLiquidationStatus.Success,
            1000 * 1e18,
            1000 * 500 * 1e18 - fee,
            fee
        );
        exchange.liquidateCollateralBatch(params);

        assertEq(exchange.getInsuranceFundBalance(), fee);

        assertEq(exchange.balanceOf(user, address(liquidationAsset)), 0);
        assertEq(exchange.balanceOf(user, address(underlyingAsset)), 1000 * 500 * 1e18 * 95 / 100);

        assertEq(liquidationAsset.balanceOf(address(exchange)), 0);
        assertEq(underlyingAsset.balanceOf(address(exchange)), receivedAmount);
        assertEq(liquidationAsset.allowance(address(exchange), address(mockUniversalRouter)), 0);
    }

    function test_liquidateCollateralBatch_emitFailedStatusIfLiquidationRevert() public {
        address invalidToken = makeAddr("invalidToken");
        address user = makeAddr("user");

        bytes memory commands = abi.encodePacked(bytes1(0x00));
        bytes[] memory inputs = new bytes[](0);

        ILiquidation.ExecutionParams[] memory executions = new ILiquidation.ExecutionParams[](1);
        executions[0] =
            ILiquidation.ExecutionParams({liquidationAsset: invalidToken, commands: commands, inputs: inputs});

        ILiquidation.LiquidationParams[] memory params = new ILiquidation.LiquidationParams[](1);
        uint256 nonce = 8;
        uint16 feePips = 500;
        params[0] =
            ILiquidation.LiquidationParams({account: user, feePips: feePips, nonce: nonce, executions: executions});

        vm.prank(liquidator);
        vm.expectEmit(address(exchange));
        emit ILiquidation.LiquidateAccount(user, nonce, ILiquidation.AccountLiquidationStatus.Failure);
        exchange.liquidateCollateralBatch(params);
    }

    function test_liquidateCollateralBatch_emitFailedStatusIfNoneSuccessfulSwap() public {
        ERC20Simple liquidationAsset = new ERC20Simple(8);
        address user = makeAddr("user");

        vm.prank(admin);
        exchange.addSupportedToken(address(liquidationAsset));

        bytes memory commands = abi.encodePacked(bytes1(0x00));
        bytes[] memory inputs = new bytes[](0);

        ILiquidation.ExecutionParams[] memory executions = new ILiquidation.ExecutionParams[](1);
        executions[0] = ILiquidation.ExecutionParams({
            liquidationAsset: address(liquidationAsset),
            commands: commands,
            inputs: inputs
        });

        ILiquidation.LiquidationParams[] memory params = new ILiquidation.LiquidationParams[](1);
        uint256 nonce = 8;
        uint16 feePips = 300;
        params[0] =
            ILiquidation.LiquidationParams({account: user, feePips: feePips, nonce: nonce, executions: executions});

        vm.prank(address(clearingService));
        ISpot.AccountDelta[] memory deltas = new ISpot.AccountDelta[](1);
        deltas[0] = ISpot.AccountDelta({token: address(liquidationAsset), account: user, amount: 100});
        spotEngine.modifyAccount(deltas);

        vm.prank(liquidator);
        vm.expectEmit(address(exchange));
        emit ILiquidation.LiquidateAccount(user, nonce, ILiquidation.AccountLiquidationStatus.Failure);
        exchange.liquidateCollateralBatch(params);
    }

    function test_liquidateCollateralBatch_emitPartalStatusIfSomeFailedSwap() public {
        ERC20Simple liquidationAsset = new ERC20Simple(8);
        address user = makeAddr("user");

        vm.prank(admin);
        exchange.addSupportedToken(address(liquidationAsset));

        vm.startPrank(user);
        liquidationAsset.mint(user, 1 * 1e8);
        liquidationAsset.approve(address(exchange), 1 * 1e8);
        exchange.deposit(address(liquidationAsset), 1 * 1e18);
        vm.stopPrank();

        underlyingAsset.mint(address(mockUniversalRouter), 1 * 1e6);

        bytes memory commands = abi.encodePacked(bytes1(0x00));
        bytes[] memory inputs1 = new bytes[](1);
        inputs1[0] = abi.encode(address(liquidationAsset), 1e8, address(underlyingAsset), 1e6);

        bytes[] memory inputs2 = new bytes[](1);
        inputs2[0] = abi.encode(address(liquidationAsset), 1e8, address(underlyingAsset), 100e6);

        ILiquidation.ExecutionParams[] memory executions = new ILiquidation.ExecutionParams[](2);
        executions[0] = ILiquidation.ExecutionParams({
            liquidationAsset: address(liquidationAsset),
            commands: commands,
            inputs: inputs1
        });
        executions[1] = ILiquidation.ExecutionParams({
            liquidationAsset: address(liquidationAsset),
            commands: commands,
            inputs: inputs2
        });

        ILiquidation.LiquidationParams[] memory params = new ILiquidation.LiquidationParams[](1);
        uint256 nonce = 8;
        uint16 feePips = 300;
        params[0] =
            ILiquidation.LiquidationParams({account: user, feePips: feePips, nonce: nonce, executions: executions});

        vm.prank(address(clearingService));
        ISpot.AccountDelta[] memory deltas = new ISpot.AccountDelta[](1);
        deltas[0] = ISpot.AccountDelta({token: address(liquidationAsset), account: user, amount: 100});
        spotEngine.modifyAccount(deltas);

        vm.prank(liquidator);
        vm.expectEmit(address(exchange));
        emit ILiquidation.LiquidateAccount(user, nonce, ILiquidation.AccountLiquidationStatus.Partial);
        exchange.liquidateCollateralBatch(params);
    }

    function test_liquidateCollateralBatch_revertIfCallerIsNotLiquidator() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(this),
                access.COLLATERAL_OPERATOR_ROLE()
            )
        );
        exchange.liquidateCollateralBatch(new ILiquidation.LiquidationParams[](0));
    }

    function test_liquidateCollateralBatch_revertIfNonceUsed() public {
        address liquidationAsset = makeAddr("liquidationAsset");
        address user = makeAddr("user");

        uint256 nonce = 1;
        stdstore.target(address(exchange)).sig("isLiquidationNonceUsed(address,uint256)").with_key(user).with_key(nonce)
            .checked_write(true);

        vm.prank(admin);
        exchange.addSupportedToken(liquidationAsset);

        ILiquidation.ExecutionParams[] memory executions = new ILiquidation.ExecutionParams[](1);
        executions[0] = ILiquidation.ExecutionParams({
            liquidationAsset: liquidationAsset,
            commands: abi.encodePacked(bytes1(0x00)),
            inputs: new bytes[](0)
        });
        ILiquidation.LiquidationParams[] memory params = new ILiquidation.LiquidationParams[](1);
        uint16 feePips = 200;
        params[0] =
            ILiquidation.LiquidationParams({account: user, feePips: feePips, nonce: nonce, executions: executions});

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_Liquidation_NonceUsed.selector, user, nonce));
        exchange.liquidateCollateralBatch(params);
    }

    function test_liquidateCollateralBatch_revertIfEmptyExectuion() public {
        address liquidationAsset = makeAddr("liquidationAsset");
        address user = makeAddr("user");

        vm.prank(admin);
        exchange.addSupportedToken(liquidationAsset);

        ILiquidation.ExecutionParams[] memory executions = new ILiquidation.ExecutionParams[](0);
        ILiquidation.LiquidationParams[] memory params = new ILiquidation.LiquidationParams[](1);
        params[0] = ILiquidation.LiquidationParams({account: user, feePips: 200, nonce: 0, executions: executions});

        vm.prank(liquidator);
        vm.expectRevert(Errors.Exchange_Liquidation_EmptyExecution.selector);
        exchange.liquidateCollateralBatch(params);
    }

    function test_liquidateCollateralBatch_revertIfExceededMaxLiquidationFeePips() public {
        address liquidationAsset = makeAddr("liquidationAsset");
        address user = makeAddr("user");

        vm.prank(admin);
        exchange.addSupportedToken(liquidationAsset);

        ILiquidation.ExecutionParams[] memory executions = new ILiquidation.ExecutionParams[](1);
        executions[0] = ILiquidation.ExecutionParams({
            liquidationAsset: liquidationAsset,
            commands: abi.encodePacked(bytes1(0x00)),
            inputs: new bytes[](0)
        });
        ILiquidation.LiquidationParams[] memory params = new ILiquidation.LiquidationParams[](1);
        uint16 feePips = 1001; // 10.01%
        params[0] = ILiquidation.LiquidationParams({account: user, feePips: feePips, nonce: 0, executions: executions});

        vm.prank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.Exchange_Liquidation_ExceededMaxLiquidationFeePips.selector, feePips)
        );
        exchange.liquidateCollateralBatch(params);
    }

    function test_innerLiquidation_emitFailedEventIfSwapFailed() public {
        address user = makeAddr("user");
        address liquidationAsset = address(new ERC20Simple(8));

        vm.prank(admin);
        exchange.addSupportedToken(liquidationAsset);

        ILiquidation.ExecutionParams[] memory execs = new ILiquidation.ExecutionParams[](1);
        execs[0] = ILiquidation.ExecutionParams({
            liquidationAsset: liquidationAsset,
            commands: abi.encodePacked(bytes1(0x00)),
            inputs: new bytes[](0)
        });
        uint256 nonce = 4;
        ILiquidation.LiquidationParams memory params =
            ILiquidation.LiquidationParams({account: user, feePips: 200, nonce: nonce, executions: execs});

        vm.prank(address(clearingService));
        ISpot.AccountDelta[] memory deltas = new ISpot.AccountDelta[](1);
        deltas[0] = ISpot.AccountDelta({token: liquidationAsset, account: user, amount: 100});
        spotEngine.modifyAccount(deltas);

        vm.prank(address(exchange));
        vm.expectEmit(address(exchange));
        emit ILiquidation.LiquidateCollateral(
            user, nonce, liquidationAsset, ILiquidation.CollateralLiquidationStatus.Failure, 0, 0, 0
        );
        exchange.innerLiquidation(params);
    }

    function test_innerLiquidation_revertIfCallerNotContract() public {
        ILiquidation.LiquidationParams memory emptyParams;
        vm.expectRevert(Errors.Exchange_InternalCall.selector);
        exchange.innerLiquidation(emptyParams);
    }

    function test_innerLiquidation_revertIfLiquidationAssetNotInWhitelist() public {
        address user = makeAddr("user");
        address token = makeAddr("token");
        ILiquidation.ExecutionParams[] memory execs = new ILiquidation.ExecutionParams[](1);
        execs[0] = ILiquidation.ExecutionParams({
            liquidationAsset: token,
            commands: abi.encodePacked(bytes1(0x00)),
            inputs: new bytes[](0)
        });
        ILiquidation.LiquidationParams memory params =
            ILiquidation.LiquidationParams({account: user, feePips: 200, nonce: 0, executions: execs});

        vm.prank(address(exchange));
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_Liquidation_InvalidAsset.selector, token));
        exchange.innerLiquidation(params);
    }

    function test_innerLiquidation_revertIfLiquidationAssetIsNotPositive() public {
        address user = makeAddr("user");
        address liquidationAsset = makeAddr("liquidationAsset");

        vm.prank(admin);
        exchange.addSupportedToken(liquidationAsset);
        ILiquidation.ExecutionParams[] memory execs = new ILiquidation.ExecutionParams[](1);
        execs[0] = ILiquidation.ExecutionParams({
            liquidationAsset: liquidationAsset,
            commands: abi.encodePacked(bytes1(0x00)),
            inputs: new bytes[](0)
        });
        ILiquidation.LiquidationParams memory params =
            ILiquidation.LiquidationParams({account: user, feePips: 50, nonce: 0, executions: execs});

        vm.prank(address(exchange));
        vm.expectRevert(
            abi.encodeWithSelector(Errors.Exchange_Liquidation_InvalidBalance.selector, user, liquidationAsset, 0)
        );
        exchange.innerLiquidation(params);

        vm.prank(address(clearingService));
        ISpot.AccountDelta[] memory deltas = new ISpot.AccountDelta[](1);
        deltas[0] = ISpot.AccountDelta({token: liquidationAsset, account: user, amount: -10});
        spotEngine.modifyAccount(deltas);

        vm.prank(address(exchange));
        vm.expectRevert(
            abi.encodeWithSelector(Errors.Exchange_Liquidation_InvalidBalance.selector, user, liquidationAsset, -10)
        );
        exchange.innerLiquidation(params);
    }

    function test_innerLiquidation_revertIfEmptyCommands() public {
        address user = makeAddr("user");
        address liquidationAsset = address(new ERC20Simple(8));

        vm.prank(admin);
        exchange.addSupportedToken(liquidationAsset);

        bytes memory emptyCommands;
        ILiquidation.ExecutionParams[] memory execs = new ILiquidation.ExecutionParams[](1);
        execs[0] = ILiquidation.ExecutionParams({
            liquidationAsset: liquidationAsset,
            commands: emptyCommands,
            inputs: new bytes[](0)
        });
        ILiquidation.LiquidationParams memory params =
            ILiquidation.LiquidationParams({account: user, feePips: 50, nonce: 1, executions: execs});

        vm.prank(address(clearingService));
        ISpot.AccountDelta[] memory deltas = new ISpot.AccountDelta[](1);
        deltas[0] = ISpot.AccountDelta({token: liquidationAsset, account: user, amount: 50});
        spotEngine.modifyAccount(deltas);

        vm.prank(address(exchange));
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_UniversalRouter_EmptyCommand.selector));
        exchange.innerLiquidation(params);
    }

    function test_innerLiquidation_revertIfInvalidCommand() public {
        address user = makeAddr("user");
        address liquidationAsset = address(new ERC20Simple(8));

        vm.prank(admin);
        exchange.addSupportedToken(liquidationAsset);
        ILiquidation.ExecutionParams[] memory execs = new ILiquidation.ExecutionParams[](1);
        execs[0] = ILiquidation.ExecutionParams({
            liquidationAsset: liquidationAsset,
            commands: abi.encodePacked(bytes1(0x03)),
            inputs: new bytes[](0)
        });
        ILiquidation.LiquidationParams memory params =
            ILiquidation.LiquidationParams({account: user, feePips: 50, nonce: 1, executions: execs});

        vm.prank(address(clearingService));
        ISpot.AccountDelta[] memory deltas = new ISpot.AccountDelta[](1);
        deltas[0] = ISpot.AccountDelta({token: liquidationAsset, account: user, amount: 50});
        spotEngine.modifyAccount(deltas);

        vm.prank(address(exchange));
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_UniversalRouter_InvalidCommand.selector, 3));
        exchange.innerLiquidation(params);
    }
}

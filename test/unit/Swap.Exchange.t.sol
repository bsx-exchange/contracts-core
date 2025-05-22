// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {Helper} from "../Helper.sol";
import {ERC20Simple} from "../mock/ERC20Simple.sol";
import {UniversalRouter} from "../mock/UniversalRouter.sol";
import {UniversalSigValidator} from "../mock/UniversalSigValidator.sol";

import {ClearingService} from "contracts/exchange/ClearingService.sol";
import {Exchange} from "contracts/exchange/Exchange.sol";
import {OrderBook} from "contracts/exchange/OrderBook.sol";
import {Spot} from "contracts/exchange/Spot.sol";
import {VaultManager} from "contracts/exchange/VaultManager.sol";
import {Access} from "contracts/exchange/access/Access.sol";
import {ISwap} from "contracts/exchange/interfaces/ISwap.sol";
import {Errors} from "contracts/exchange/lib/Errors.sol";
import {MathHelper} from "contracts/exchange/lib/MathHelper.sol";
import {Roles} from "contracts/exchange/lib/Roles.sol";
import {UNIVERSAL_SIG_VALIDATOR} from "contracts/exchange/share/Constants.sol";
import {TxStatus} from "contracts/exchange/share/Enums.sol";

contract SwapExchangeTest is Test {
    using stdStorage for StdStorage;
    using MathHelper for uint256;

    address private sequencer = makeAddr("sequencer");
    address private user;
    uint256 private userKey;

    Access private access;
    Exchange private exchange;
    ClearingService private clearingService;
    OrderBook private orderbook;
    Spot private spotEngine;

    ERC20Simple private tokenIn = new ERC20Simple(8);
    ERC20Simple private tokenOut = new ERC20Simple(6);

    UniversalRouter private universalRouter;

    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant SWAP_TYPEHASH = keccak256(
        "Swap(address account,address assetIn,uint256 amountIn,address assetOut,uint256 minAmountOut,uint256 nonce)"
    );
    bytes32 private constant REGISTER_VAULT_TYPEHASH =
        keccak256("RegisterVault(address vault,address feeRecipient,uint256 profitShareBps)");

    function setUp() public {
        vm.startPrank(sequencer);

        access = new Access();
        stdstore.target(address(access)).sig("hasRole(bytes32,address)").with_key(Roles.ADMIN_ROLE).with_key(sequencer)
            .checked_write(true);
        access.grantRole(Roles.GENERAL_ROLE, sequencer);
        access.grantRole(Roles.COLLATERAL_OPERATOR_ROLE, sequencer);

        clearingService = new ClearingService();
        stdstore.target(address(clearingService)).sig("access()").checked_write(address(access));

        spotEngine = new Spot();
        stdstore.target(address(spotEngine)).sig("access()").checked_write(address(access));

        orderbook = new OrderBook();
        stdstore.target(address(orderbook)).sig("clearingService()").checked_write(address(clearingService));
        stdstore.target(address(orderbook)).sig("spotEngine()").checked_write(address(spotEngine));
        stdstore.target(address(orderbook)).sig("access()").checked_write(address(access));

        exchange = new Exchange();
        bytes memory code = address(new UniversalSigValidator()).code;
        vm.etch(address(UNIVERSAL_SIG_VALIDATOR), code);

        access.setExchange(address(exchange));
        access.setClearingService(address(clearingService));
        access.setSpotEngine(address(spotEngine));
        access.setOrderBook(address(orderbook));

        universalRouter = new UniversalRouter(address(exchange));

        stdstore.target(address(exchange)).sig("access()").checked_write(address(access));
        stdstore.target(address(exchange)).sig("clearingService()").checked_write(address(clearingService));
        stdstore.target(address(exchange)).sig("book()").checked_write(address(orderbook));
        stdstore.target(address(exchange)).sig("spotEngine()").checked_write(address(spotEngine));
        stdstore.target(address(exchange)).sig("universalRouter()").checked_write(address(universalRouter));

        VaultManager vaultManager = new VaultManager();
        stdstore.target(address(vaultManager)).sig("access()").checked_write(address(access));
        access.setVaultManager(address(vaultManager));

        exchange.setCanDeposit(true);
        exchange.addSupportedToken(address(tokenIn));
        exchange.addSupportedToken(address(tokenOut));

        (user, userKey) = makeAddrAndKey("user");

        tokenIn.mint(address(exchange), 1_000_000_000 * 1e18);
        tokenOut.mint(address(exchange), 1_000_000_000 * 1e18);

        vm.stopPrank();
    }

    function test_swapCollateralBatch() public {
        tokenIn.mint(user, 1000 * 1e8);

        vm.startPrank(user);
        tokenIn.approve(address(exchange), 1000 * 1e8);
        exchange.deposit(address(tokenIn), 1000 ether);
        vm.stopPrank();

        assertEq(exchange.balanceOf(user, address(tokenIn)), 1000 ether);

        bytes memory commands = abi.encodePacked(bytes1(0x00), bytes1(0x01), bytes1(0x08), bytes1(0x09));
        bytes[] memory inputs = new bytes[](1);
        // mock input
        uint256 swapAmountIn = 800 * 1e8;
        uint256 amountOut = 4000 * 1e6;
        inputs[0] = abi.encode(address(tokenIn), swapAmountIn, address(tokenOut), amountOut);

        uint256 swapAmountInX18 = swapAmountIn.convertToScale(address(tokenIn));
        uint256 amountOutX18 = amountOut.convertToScale(address(tokenOut));
        uint256 feeAmountX18 = swapAmountInX18 * 5 / 1000;
        uint256 amountInX18 = swapAmountInX18 + feeAmountX18;
        uint256 nonce = 1;
        bytes memory signature = _signTypedDataHash(
            userKey,
            keccak256(
                abi.encode(SWAP_TYPEHASH, user, address(tokenIn), amountInX18, address(tokenOut), amountOutX18, nonce)
            )
        );

        ISwap.SwapParams[] memory params = new ISwap.SwapParams[](1);
        params[0] = ISwap.SwapParams({
            account: user,
            nonce: nonce,
            assetIn: address(tokenIn),
            assetOut: address(tokenOut),
            amountIn: amountInX18,
            minAmountOut: amountOutX18,
            feeAmount: feeAmountX18,
            commands: commands,
            inputs: inputs,
            signature: signature
        });

        uint256 exchangeTokenInBal = tokenIn.balanceOf(address(exchange));
        uint256 exchangeTokenOutBal = tokenOut.balanceOf(address(exchange));

        int256 userTokenInBal = exchange.balanceOf(user, address(tokenIn));
        int256 userTokenOutBal = exchange.balanceOf(user, address(tokenOut));

        vm.prank(sequencer);
        vm.expectEmit(address(exchange));
        emit ISwap.SwapCollateral(
            user,
            nonce,
            address(tokenIn),
            amountInX18,
            address(tokenOut),
            amountOutX18,
            address(tokenIn),
            feeAmountX18,
            TxStatus.Success
        );
        exchange.swapCollateralBatch(params);

        assertEq(amountInX18, swapAmountInX18 + feeAmountX18);

        assertEq(tokenIn.balanceOf(address(exchange)), exchangeTokenInBal - swapAmountIn);
        assertEq(tokenOut.balanceOf(address(exchange)), exchangeTokenOutBal + amountOut);

        assertEq(tokenIn.allowance(address(exchange), address(universalRouter)), 0);

        assertEq(exchange.balanceOf(user, address(tokenIn)), userTokenInBal - int256(amountInX18));
        assertEq(exchange.balanceOf(user, address(tokenOut)), userTokenOutBal + int256(amountOutX18));

        assertEq(exchange.getSequencerFees(address(tokenIn)), feeAmountX18);

        assertEq(exchange.isSwapNonceUsed(user, nonce), true);
    }

    function test_swapCollateralBatch_emitFailedStatusIfInnerSwapRevert() public {
        tokenIn.mint(user, 1000 * 1e8);

        vm.startPrank(user);
        tokenIn.approve(address(exchange), 1000 * 1e8);
        exchange.deposit(address(tokenIn), 1000 ether);
        vm.stopPrank();

        bytes memory commands;
        bytes[] memory inputs;
        bytes memory signature;
        uint256 amountInX18 = 1 ether;
        uint256 minAmountOutX18 = 500 ether;
        uint256 feeAmountX18 = 1;
        uint256 nonce = 1;

        ISwap.SwapParams[] memory params = new ISwap.SwapParams[](1);
        params[0] = ISwap.SwapParams({
            account: user,
            nonce: nonce,
            assetIn: address(tokenIn),
            assetOut: address(tokenOut),
            amountIn: amountInX18,
            minAmountOut: minAmountOutX18,
            feeAmount: feeAmountX18,
            commands: commands,
            inputs: inputs,
            signature: signature
        });

        uint256 exchangeTokenInBal = tokenIn.balanceOf(address(exchange));
        uint256 exchangeTokenOutBal = tokenOut.balanceOf(address(exchange));

        vm.prank(sequencer);
        vm.expectEmit(address(exchange));
        emit ISwap.SwapCollateral(
            user, nonce, address(tokenIn), amountInX18, address(tokenOut), 0, address(tokenIn), 0, TxStatus.Failure
        );
        exchange.swapCollateralBatch(params);

        assertEq(tokenIn.balanceOf(address(exchange)), exchangeTokenInBal);
        assertEq(tokenOut.balanceOf(address(exchange)), exchangeTokenOutBal);

        assertEq(exchange.balanceOf(user, address(tokenIn)), 1000 ether);
        assertEq(exchange.balanceOf(user, address(tokenOut)), 0);

        assertEq(exchange.getSequencerFees(address(tokenIn)), 0);
    }

    function test_swapCollateralBatch_revertIfCallerIsNotSequencer() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), Roles.COLLATERAL_OPERATOR_ROLE
            )
        );
        exchange.swapCollateralBatch(new ISwap.SwapParams[](0));
    }

    function test_swapCollateralBatch_revertIfNonceUsed() public {
        tokenIn.mint(user, 1000 * 1e8);

        vm.startPrank(user);
        tokenIn.approve(address(exchange), 1000 * 1e8);
        exchange.deposit(address(tokenIn), 1000 ether);
        vm.stopPrank();

        uint256 nonce = 1;

        stdstore.target(address(exchange)).sig("isSwapNonceUsed(address,uint256)").with_key(user).with_key(nonce)
            .checked_write(true);

        bytes memory commands;
        bytes[] memory inputs = new bytes[](1);
        bytes memory signature;

        ISwap.SwapParams[] memory params = new ISwap.SwapParams[](1);
        params[0] = ISwap.SwapParams({
            account: user,
            nonce: nonce,
            assetIn: address(tokenIn),
            assetOut: address(tokenOut),
            amountIn: 0,
            minAmountOut: 0,
            feeAmount: 0,
            commands: commands,
            inputs: inputs,
            signature: signature
        });

        vm.prank(sequencer);
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_Swap_NonceUsed.selector, user, nonce));
        exchange.swapCollateralBatch(params);
    }

    function test_innerSwapWithPermit_revertIfCallerNotContract() public {
        ISwap.SwapParams memory emptyParams;
        vm.expectRevert(Errors.Exchange_InternalCall.selector);
        exchange.innerSwapWithPermit(emptyParams);
    }

    function test_innerSwapWithPermit_revertIfAccountIsVault() public {
        address vault = _registerVault();
        ISwap.SwapParams memory params;
        params.account = vault;

        vm.prank(address(exchange));
        vm.expectRevert(Errors.Exchange_VaultAddress.selector);
        exchange.innerSwapWithPermit(params);
    }

    function test_innerSwapWithPermit_revertIfInvalidSigner() public {
        (, uint256 maliciousSignerKey) = makeAddrAndKey("maliciousSigner");

        ISwap.SwapParams memory params;
        params.account = user;
        params.nonce = 1;
        params.assetIn = address(tokenIn);
        params.assetOut = address(tokenOut);
        params.amountIn = 1 ether;
        params.minAmountOut = 200 ether;
        params.feeAmount = 1;
        params.signature = _signTypedDataHash(
            maliciousSignerKey,
            keccak256(
                abi.encode(
                    SWAP_TYPEHASH,
                    user,
                    params.assetIn,
                    params.amountIn,
                    params.assetOut,
                    params.minAmountOut,
                    params.nonce
                )
            )
        );

        vm.prank(address(exchange));
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_InvalidSignature.selector, user));
        exchange.innerSwapWithPermit(params);
    }

    function test_innerSwapWithPermit_revertIfInvalidAsset() public {
        vm.startPrank(address(exchange));

        ISwap.SwapParams memory params;
        params.account = user;
        params.assetIn = makeAddr("invalid");
        params.assetOut = address(tokenOut);
        params.signature = _signTypedDataHash(
            userKey,
            keccak256(
                abi.encode(
                    SWAP_TYPEHASH,
                    user,
                    params.assetIn,
                    params.amountIn,
                    params.assetOut,
                    params.minAmountOut,
                    params.nonce
                )
            )
        );
        vm.expectRevert(Errors.Exchange_Swap_InvalidAsset.selector);
        exchange.innerSwapWithPermit(params);

        params.assetIn = address(tokenIn);
        params.assetOut = makeAddr("invalid");
        params.signature = _signTypedDataHash(
            userKey,
            keccak256(
                abi.encode(
                    SWAP_TYPEHASH,
                    user,
                    params.assetIn,
                    params.amountIn,
                    params.assetOut,
                    params.minAmountOut,
                    params.nonce
                )
            )
        );
        vm.expectRevert(Errors.Exchange_Swap_InvalidAsset.selector);
        exchange.innerSwapWithPermit(params);

        vm.stopPrank();
    }

    function test_innerSwapWithPermit_revertIfSwapSameAsset() public {
        ISwap.SwapParams memory params;
        params.account = user;
        params.assetIn = address(tokenOut);
        params.assetOut = address(tokenOut);
        params.signature = _signTypedDataHash(
            userKey,
            keccak256(
                abi.encode(
                    SWAP_TYPEHASH,
                    user,
                    params.assetIn,
                    params.amountIn,
                    params.assetOut,
                    params.minAmountOut,
                    params.nonce
                )
            )
        );

        vm.prank(address(exchange));
        vm.expectRevert(Errors.Exchange_Swap_SameAsset.selector);
        exchange.innerSwapWithPermit(params);
    }

    function test_innerSwapWithPermit_revertIfExceedesBalance() public {
        ISwap.SwapParams memory params;
        params.account = user;
        params.amountIn = 1;
        params.assetIn = address(tokenIn);
        params.assetOut = address(tokenOut);
        params.signature = _signTypedDataHash(
            userKey,
            keccak256(
                abi.encode(
                    SWAP_TYPEHASH,
                    user,
                    params.assetIn,
                    params.amountIn,
                    params.assetOut,
                    params.minAmountOut,
                    params.nonce
                )
            )
        );

        vm.prank(address(exchange));
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.Exchange_Swap_ExceededBalance.selector, user, address(tokenIn), params.amountIn, 0
            )
        );
        exchange.innerSwapWithPermit(params);
    }

    function test_innerSwapWithPermit_revertIfExceedesMaxFee() public {
        tokenIn.mint(user, 1000 * 1e8);

        vm.startPrank(user);
        tokenIn.approve(address(exchange), 1000 * 1e8);
        exchange.deposit(address(tokenIn), 1000 ether);
        vm.stopPrank();

        ISwap.SwapParams memory params;
        params.account = user;
        params.assetIn = address(tokenIn);
        params.assetOut = address(tokenOut);

        // max fee 1% of amountIn
        params.amountIn = 1000;
        params.feeAmount = 11;
        uint256 maxFeeAmount = 10;

        params.signature = _signTypedDataHash(
            userKey,
            keccak256(
                abi.encode(
                    SWAP_TYPEHASH,
                    user,
                    params.assetIn,
                    params.amountIn,
                    params.assetOut,
                    params.minAmountOut,
                    params.nonce
                )
            )
        );

        vm.prank(address(exchange));
        vm.expectRevert(
            abi.encodeWithSelector(Errors.Exchange_Swap_ExceededMaxFee.selector, params.feeAmount, maxFeeAmount)
        );
        exchange.innerSwapWithPermit(params);
    }

    function test_innerSwapWithPermit_revertIfSwapZeroAmount() public {
        tokenIn.mint(user, 1000 * 1e8);

        vm.startPrank(user);
        tokenIn.approve(address(exchange), 1000 * 1e8);
        exchange.deposit(address(tokenIn), 1000 ether);
        vm.stopPrank();

        ISwap.SwapParams memory params;
        params.account = user;
        params.assetIn = address(tokenIn);
        params.assetOut = address(tokenOut);
        params.amountIn = 1;
        params.signature = _signTypedDataHash(
            userKey,
            keccak256(
                abi.encode(
                    SWAP_TYPEHASH,
                    user,
                    params.assetIn,
                    params.amountIn,
                    params.assetOut,
                    params.minAmountOut,
                    params.nonce
                )
            )
        );

        vm.prank(address(exchange));
        vm.expectRevert(Errors.Exchange_ZeroAmount.selector);
        exchange.innerSwapWithPermit(params);
    }

    function test_innerSwapWithPermit_revertIfEmptyCommand() public {
        tokenIn.mint(user, 1000 * 1e8);

        vm.startPrank(user);
        tokenIn.approve(address(exchange), 1000 * 1e8);
        exchange.deposit(address(tokenIn), 1000 ether);
        vm.stopPrank();

        ISwap.SwapParams memory params;
        params.account = user;
        params.nonce = 1;
        params.assetIn = address(tokenIn);
        params.assetOut = address(tokenOut);
        params.amountIn = 1 ether;
        params.minAmountOut = 500;
        params.feeAmount = 10;
        params.signature = params.signature = _signTypedDataHash(
            userKey,
            keccak256(
                abi.encode(
                    SWAP_TYPEHASH,
                    user,
                    params.assetIn,
                    params.amountIn,
                    params.assetOut,
                    params.minAmountOut,
                    params.nonce
                )
            )
        );

        vm.prank(address(exchange));
        vm.expectRevert(Errors.Exchange_UniversalRouter_EmptyCommand.selector);
        exchange.innerSwapWithPermit(params);
    }

    function test_innerSwapWithPermit_revertIfInvalidCommands() public {
        tokenIn.mint(user, 1000 * 1e8);

        vm.startPrank(user);
        tokenIn.approve(address(exchange), 1000 * 1e8);
        exchange.deposit(address(tokenIn), 1000 ether);
        vm.stopPrank();

        ISwap.SwapParams memory params;
        params.account = user;
        params.nonce = 1;
        params.assetIn = address(tokenIn);
        params.assetOut = address(tokenOut);
        params.amountIn = 1 ether;
        params.minAmountOut = 500;
        params.feeAmount = 10;
        params.signature = params.signature = _signTypedDataHash(
            userKey,
            keccak256(
                abi.encode(
                    SWAP_TYPEHASH,
                    user,
                    params.assetIn,
                    params.amountIn,
                    params.assetOut,
                    params.minAmountOut,
                    params.nonce
                )
            )
        );

        for (uint8 i = 0; i < 64; i++) {
            if (i == 0 || i == 1 || i == 8 || i == 9) continue;
            params.commands = abi.encodePacked(i);

            vm.prank(address(exchange));
            vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_UniversalRouter_InvalidCommand.selector, i));
            exchange.innerSwapWithPermit(params);
        }
    }

    function test_innerSwapWithPermit_revertIfAmountInMismatch() public {
        tokenIn.mint(user, 1000 * 1e8);

        vm.startPrank(user);
        tokenIn.approve(address(exchange), 1000 * 1e8);
        exchange.deposit(address(tokenIn), 1000 ether);
        vm.stopPrank();

        ISwap.SwapParams memory params;
        params.account = user;
        params.nonce = 3;
        params.assetIn = address(tokenIn);
        params.assetOut = address(tokenOut);
        params.amountIn = 1000 ether;
        params.minAmountOut = 500 ether;
        params.signature = _signTypedDataHash(
            userKey,
            keccak256(
                abi.encode(
                    SWAP_TYPEHASH,
                    user,
                    params.assetIn,
                    params.amountIn,
                    params.assetOut,
                    params.minAmountOut,
                    params.nonce
                )
            )
        );
        params.commands = abi.encodePacked(bytes1(0x01));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(tokenIn), 900 * 1e8, address(tokenOut), 400 * 1e6);
        params.inputs = inputs;

        vm.prank(address(exchange));
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_Swap_AmountInMismatch.selector, 900 * 1e8, 1000 * 1e8));
        exchange.innerSwapWithPermit(params);
    }

    function test_innerSwapWithPermit_revertIfAmountOutTooLow() public {
        tokenIn.mint(user, 1000 * 1e8);

        vm.startPrank(user);
        tokenIn.approve(address(exchange), 1000 * 1e8);
        exchange.deposit(address(tokenIn), 1000 ether);
        vm.stopPrank();

        ISwap.SwapParams memory params;
        params.account = user;
        params.nonce = 1;
        params.assetIn = address(tokenIn);
        params.assetOut = address(tokenOut);
        params.amountIn = 1000 ether;
        params.minAmountOut = 500 ether;
        params.signature = _signTypedDataHash(
            userKey,
            keccak256(
                abi.encode(
                    SWAP_TYPEHASH,
                    user,
                    params.assetIn,
                    params.amountIn,
                    params.assetOut,
                    params.minAmountOut,
                    params.nonce
                )
            )
        );
        params.commands = abi.encodePacked(bytes1(0x01));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(tokenIn), 1000 * 1e8, address(tokenOut), 400 * 1e6);
        params.inputs = inputs;

        vm.prank(address(exchange));
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_Swap_AmountOutTooLittle.selector, 400 ether, 500 ether));
        exchange.innerSwapWithPermit(params);
    }

    function _registerVault() private returns (address) {
        (address vault, uint256 vaultPrivKey) = makeAddrAndKey("vault");
        address feeRecipient = makeAddr("feeRecipient");
        uint256 profitShareBps = 100;
        bytes32 structHash = keccak256(abi.encode(REGISTER_VAULT_TYPEHASH, vault, feeRecipient, profitShareBps));
        bytes memory signature = _signTypedDataHash(vaultPrivKey, structHash);
        vm.prank(sequencer);
        exchange.registerVault(vault, feeRecipient, profitShareBps, signature);
        return vault;
    }

    function _signTypedDataHash(uint256 privateKey, bytes32 structHash) private view returns (bytes memory) {
        return Helper.signTypedDataHash(exchange, privateKey, structHash);
    }
}

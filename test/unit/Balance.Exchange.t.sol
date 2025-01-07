// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {Helper} from "../Helper.sol";
import {ERC1271} from "../mock/ERC1271.sol";
import {ERC20MissingReturn} from "../mock/ERC20MissingReturn.sol";
import {ERC20Simple} from "../mock/ERC20Simple.sol";
import {UniversalSigValidator} from "../mock/UniversalSigValidator.sol";
import {WETH9Mock} from "../mock/WETH9.sol";

import {BSX1000x, IBSX1000x} from "contracts/1000x/BSX1000x.sol";
import {ClearingService} from "contracts/exchange/ClearingService.sol";
import {Exchange, IExchange} from "contracts/exchange/Exchange.sol";
import {ISpot, Spot} from "contracts/exchange/Spot.sol";
import {Access} from "contracts/exchange/access/Access.sol";
import {IERC3009Minimal} from "contracts/exchange/interfaces/external/IERC3009Minimal.sol";
import {Errors} from "contracts/exchange/lib/Errors.sol";
import {MathHelper} from "contracts/exchange/lib/MathHelper.sol";
import {NATIVE_ETH, UNIVERSAL_SIG_VALIDATOR, WETH9} from "contracts/exchange/share/Constants.sol";

// solhint-disable max-states-count
contract ExchangeTest is Test {
    using stdStorage for StdStorage;
    using Helper for bytes;
    using Helper for uint128;
    using MathHelper for int128;
    using MathHelper for uint128;

    address private sequencer = makeAddr("sequencer");

    ERC20Simple private collateralToken = new ERC20Simple(6);

    Access private access;
    Exchange private exchange;
    ClearingService private clearingService;
    Spot private spotEngine;

    BSX1000x private bsx1000;

    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function setUp() public {
        vm.startPrank(sequencer);

        access = new Access();
        stdstore.target(address(access)).sig("hasRole(bytes32,address)").with_key(access.ADMIN_ROLE()).with_key(
            sequencer
        ).checked_write(true);
        access.grantRole(access.GENERAL_ROLE(), sequencer);
        access.grantRole(access.BATCH_OPERATOR_ROLE(), sequencer);
        access.grantRole(access.COLLATERAL_OPERATOR_ROLE(), sequencer);
        access.grantRole(access.SIGNER_OPERATOR_ROLE(), sequencer);

        clearingService = new ClearingService();
        stdstore.target(address(clearingService)).sig("access()").checked_write(address(access));

        spotEngine = new Spot();
        stdstore.target(address(spotEngine)).sig("access()").checked_write(address(access));

        exchange = new Exchange();
        bytes memory code = address(new UniversalSigValidator()).code;
        vm.etch(address(UNIVERSAL_SIG_VALIDATOR), code);

        bsx1000 = new BSX1000x();
        stdstore.target(address(bsx1000)).sig("access()").checked_write(address(access));
        stdstore.target(address(bsx1000)).sig("collateralToken()").checked_write(address(collateralToken));

        access.setExchange(address(exchange));
        access.setClearingService(address(clearingService));
        access.setSpotEngine(address(spotEngine));
        access.setBsx1000(address(bsx1000));

        stdstore.target(address(exchange)).sig("access()").checked_write(address(access));
        stdstore.target(address(exchange)).sig("clearingService()").checked_write(address(clearingService));
        stdstore.target(address(exchange)).sig("spotEngine()").checked_write(address(spotEngine));
        exchange.setCanDeposit(true);
        exchange.setCanWithdraw(true);

        exchange.addSupportedToken(address(collateralToken));

        vm.stopPrank();
    }

    function test_deposit() public {
        address account = makeAddr("account");
        uint128 totalAmount;
        uint8 tokenDecimals = collateralToken.decimals();

        vm.startPrank(account);

        for (uint128 i = 1; i < 5; i++) {
            uint128 amount = i * 1e18;
            _prepareDeposit(account, amount);

            totalAmount += amount;
            vm.expectEmit(address(exchange));
            emit IExchange.Deposit(address(collateralToken), account, amount, 0);
            exchange.deposit(address(collateralToken), amount);

            assertEq(exchange.balanceOf(account, address(collateralToken)), int128(totalAmount));
            assertEq(spotEngine.getBalance(address(collateralToken), account), int128(totalAmount));
            assertEq(spotEngine.getTotalBalance(address(collateralToken)), totalAmount);
            assertEq(collateralToken.balanceOf(address(exchange)), totalAmount.convertFrom18D(tokenDecimals));
        }
    }

    function test_deposit_withErc20MissingReturn() public {
        ERC20MissingReturn erc20MissingReturn = new ERC20MissingReturn();

        vm.prank(sequencer);
        exchange.addSupportedToken(address(erc20MissingReturn));

        address account = makeAddr("account");
        uint8 tokenDecimals = erc20MissingReturn.decimals();

        vm.startPrank(account);

        uint128 amount = 5 * 1e18;
        _prepareDeposit(account, address(erc20MissingReturn), amount);

        vm.expectEmit(address(exchange));
        emit IExchange.Deposit(address(erc20MissingReturn), account, amount, 0);
        exchange.deposit(address(erc20MissingReturn), amount);

        assertEq(exchange.balanceOf(account, address(erc20MissingReturn)), int128(amount));
        assertEq(spotEngine.getBalance(address(erc20MissingReturn), account), int128(amount));
        assertEq(spotEngine.getTotalBalance(address(erc20MissingReturn)), amount);
        assertEq(erc20MissingReturn.balanceOf(address(exchange)), amount.convertFrom18D(tokenDecimals));
    }

    function test_deposit_withNativeETH() public {
        bytes memory code = address(new WETH9Mock()).code;
        vm.etch(WETH9, code);

        vm.prank(sequencer);
        exchange.addSupportedToken(NATIVE_ETH);

        address account = makeAddr("account");
        uint128 amount = 5 ether;
        vm.deal(account, amount);

        vm.prank(account);
        vm.expectEmit(address(exchange));
        emit IExchange.Deposit(WETH9, account, amount, 0);
        exchange.deposit{value: amount}(NATIVE_ETH, amount);

        assertEq(exchange.balanceOf(account, WETH9), int128(amount));
        assertEq(spotEngine.getBalance(WETH9, account), int128(amount));
        assertEq(spotEngine.getTotalBalance(WETH9), amount);
        assertEq(ERC20Simple(WETH9).balanceOf(address(exchange)), amount);
    }

    function test_deposit_withNativeETH_revertsIfInsufficientEth() public {
        bytes memory code = address(new WETH9Mock()).code;
        vm.etch(WETH9, code);

        vm.prank(sequencer);
        exchange.addSupportedToken(NATIVE_ETH);

        address account = makeAddr("account");
        uint128 depositAmount = 4 ether;
        vm.deal(account, depositAmount);

        vm.prank(account);
        vm.expectRevert(Errors.Exchange_InvalidEthAmount.selector);
        exchange.deposit{value: 3 ether}(NATIVE_ETH, depositAmount);
    }

    function test_deposit_revertsIfZeroAmount() public {
        vm.expectRevert(Errors.Exchange_ZeroAmount.selector);
        exchange.deposit(address(collateralToken), 0);

        uint128 maxZeroScaledAmount = _maxZeroScaledAmount();
        vm.expectRevert(Errors.Exchange_ZeroAmount.selector);
        exchange.deposit(address(collateralToken), maxZeroScaledAmount);
    }

    function test_deposit_revertsIfTokenNotSupported() public {
        address notSupportedToken = makeAddr("notSupportedToken");
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_TokenNotSupported.selector, notSupportedToken));
        exchange.deposit(notSupportedToken, 100);
    }

    function test_deposit_revertsIfDisabledDeposit() public {
        vm.prank(sequencer);
        exchange.setCanDeposit(false);

        vm.expectRevert(Errors.Exchange_DisabledDeposit.selector);
        exchange.deposit(address(collateralToken), 100);
    }

    function test_deposit_withRecipient() public {
        address payer = makeAddr("payer");
        address recipient = makeAddr("recipient");
        uint128 totalAmount;
        uint8 tokenDecimals = collateralToken.decimals();

        vm.startPrank(payer);

        for (uint128 i = 1; i < 2; i++) {
            uint128 amount = i * 1e18;
            _prepareDeposit(payer, amount);

            totalAmount += amount;
            vm.expectEmit(address(exchange));
            emit IExchange.Deposit(address(collateralToken), recipient, amount, 0);
            exchange.deposit(recipient, address(collateralToken), amount);

            assertEq(exchange.balanceOf(payer, address(collateralToken)), 0);
            assertEq(exchange.balanceOf(recipient, address(collateralToken)), int128(totalAmount));
            assertEq(spotEngine.getBalance(address(collateralToken), recipient), int128(totalAmount));
            assertEq(spotEngine.getTotalBalance(address(collateralToken)), totalAmount);
            assertEq(collateralToken.balanceOf(address(exchange)), totalAmount.convertFrom18D(tokenDecimals));
        }
    }

    function test_deposit_withRecipient_withErc20MissingReturn() public {
        ERC20MissingReturn erc20MissingReturn = new ERC20MissingReturn();

        vm.prank(sequencer);
        exchange.addSupportedToken(address(erc20MissingReturn));

        address payer = makeAddr("payer");
        address recipient = makeAddr("recipient");
        uint8 tokenDecimals = erc20MissingReturn.decimals();

        vm.startPrank(payer);

        uint128 amount = 5 * 1e18;
        _prepareDeposit(payer, address(erc20MissingReturn), amount);

        vm.expectEmit(address(exchange));
        emit IExchange.Deposit(address(erc20MissingReturn), recipient, amount, 0);
        exchange.deposit(recipient, address(erc20MissingReturn), amount);

        assertEq(spotEngine.getBalance(address(erc20MissingReturn), recipient), int128(amount));
        assertEq(spotEngine.getTotalBalance(address(erc20MissingReturn)), amount);
        assertEq(erc20MissingReturn.balanceOf(address(exchange)), amount.convertFrom18D(tokenDecimals));
    }

    function test_deposit_withRecipient_revertsIfZeroAmount() public {
        address recipient = makeAddr("recipient");
        vm.expectRevert(Errors.Exchange_ZeroAmount.selector);
        exchange.deposit(recipient, address(collateralToken), 0);

        uint128 maxZeroScaledAmount = _maxZeroScaledAmount();
        vm.expectRevert(Errors.Exchange_ZeroAmount.selector);
        exchange.deposit(recipient, address(collateralToken), maxZeroScaledAmount);
    }

    function test_deposit_withRecipient_revertsIfTokenNotSupported() public {
        address recipient = makeAddr("recipient");
        address notSupportedToken = makeAddr("notSupportedToken");
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_TokenNotSupported.selector, notSupportedToken));
        exchange.deposit(recipient, notSupportedToken, 100);
    }

    function test_deposit_withRecipient_revertsIfDepositDisabled() public {
        address recipient = makeAddr("recipient");

        vm.prank(sequencer);
        exchange.setCanDeposit(false);

        vm.expectRevert(Errors.Exchange_DisabledDeposit.selector);
        exchange.deposit(recipient, address(collateralToken), 100);
    }

    function test_depositRaw() public {
        address account = makeAddr("account");
        uint128 totalAmount;
        uint8 tokenDecimals = collateralToken.decimals();

        vm.startPrank(account);

        for (uint128 i = 1; i < 5; i++) {
            uint128 rawAmount = i * 3000;
            collateralToken.mint(account, rawAmount);
            collateralToken.approve(address(exchange), rawAmount);

            uint128 amount = uint128(rawAmount.convertTo18D(tokenDecimals));
            totalAmount += amount;
            vm.expectEmit(address(exchange));
            emit IExchange.Deposit(address(collateralToken), account, amount, 0);
            exchange.depositRaw(account, address(collateralToken), rawAmount);

            assertEq(exchange.balanceOf(account, address(collateralToken)), int128(totalAmount));
            assertEq(spotEngine.getBalance(address(collateralToken), account), int128(totalAmount));
            assertEq(spotEngine.getTotalBalance(address(collateralToken)), totalAmount);
            assertEq(collateralToken.balanceOf(address(exchange)), totalAmount.convertFrom18D(tokenDecimals));
        }
    }

    function test_depositRaw_withErc20MissingReturn() public {
        ERC20MissingReturn erc20MissingReturn = new ERC20MissingReturn();

        vm.prank(sequencer);
        exchange.addSupportedToken(address(erc20MissingReturn));

        address account = makeAddr("account");
        uint8 tokenDecimals = erc20MissingReturn.decimals();

        vm.startPrank(account);

        uint128 rawAmount = 5 * 3000;
        erc20MissingReturn.mint(account, rawAmount);
        erc20MissingReturn.approve(address(exchange), rawAmount);

        uint128 amount = uint128(rawAmount.convertTo18D(tokenDecimals));
        vm.expectEmit(address(exchange));
        emit IExchange.Deposit(address(erc20MissingReturn), account, amount, 0);
        exchange.depositRaw(account, address(erc20MissingReturn), rawAmount);

        assertEq(exchange.balanceOf(account, address(erc20MissingReturn)), int128(amount));
        assertEq(spotEngine.getBalance(address(erc20MissingReturn), account), int128(amount));
        assertEq(spotEngine.getTotalBalance(address(erc20MissingReturn)), amount);

        assertEq(erc20MissingReturn.balanceOf(account), 0);
        assertEq(erc20MissingReturn.balanceOf(address(exchange)), amount.convertFrom18D(tokenDecimals));
    }

    function test_depositRaw_withNativeETH() public {
        bytes memory code = address(new WETH9Mock()).code;
        vm.etch(WETH9, code);

        vm.prank(sequencer);
        exchange.addSupportedToken(NATIVE_ETH);

        address account = makeAddr("account");
        uint128 amount = 5 ether;
        vm.deal(account, amount);

        vm.prank(account);
        vm.expectEmit(address(exchange));
        emit IExchange.Deposit(WETH9, account, amount, 0);
        exchange.depositRaw{value: amount}(account, NATIVE_ETH, amount);

        assertEq(exchange.balanceOf(account, WETH9), int128(amount));
        assertEq(spotEngine.getBalance(WETH9, account), int128(amount));
        assertEq(spotEngine.getTotalBalance(WETH9), amount);
        assertEq(ERC20Simple(WETH9).balanceOf(address(exchange)), amount);
    }

    function test_depositRaw_revertsIfZeroAmount() public {
        vm.expectRevert(Errors.Exchange_ZeroAmount.selector);
        exchange.depositRaw(makeAddr("account"), address(collateralToken), 0);
    }

    function test_depositRaw_revertsIfTokenNotSupported() public {
        address account = makeAddr("account");
        address notSupportedToken = makeAddr("notSupportedToken");
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_TokenNotSupported.selector, notSupportedToken));
        exchange.depositRaw(account, notSupportedToken, 100);
    }

    function test_depositRaw_revertsIfDisabledDeposit() public {
        vm.prank(sequencer);
        exchange.setCanDeposit(false);

        address account = makeAddr("account");
        vm.expectRevert(Errors.Exchange_DisabledDeposit.selector);
        exchange.depositRaw(account, address(collateralToken), 100);
    }

    function test_depositWithAuthorization() public {
        address account = makeAddr("account");
        uint128 totalAmount;
        uint8 tokenDecimals = collateralToken.decimals();
        uint256 mockValidTime = block.timestamp;
        bytes32 mockNonce = keccak256(abi.encode(account, mockValidTime));
        bytes memory mockSignature = abi.encode(account, mockValidTime, mockNonce);

        for (uint128 i = 1; i < 5; i++) {
            uint128 amount = i * 1e18;
            vm.startPrank(account);
            _prepareDeposit(account, amount);
            vm.stopPrank();

            totalAmount += amount;

            vm.mockCall(
                address(collateralToken),
                abi.encodeWithSelector(
                    IERC3009Minimal.receiveWithAuthorization.selector,
                    account,
                    address(exchange),
                    amount.convertFrom18D(tokenDecimals),
                    mockValidTime,
                    mockValidTime,
                    mockNonce,
                    mockSignature
                ),
                abi.encode()
            );

            vm.expectEmit(address(exchange));
            emit IExchange.Deposit(address(collateralToken), account, amount, 0);
            vm.prank(sequencer);
            exchange.depositWithAuthorization(
                address(collateralToken), account, amount, mockValidTime, mockValidTime, mockNonce, mockSignature
            );

            assertEq(spotEngine.getBalance(address(collateralToken), account), int128(totalAmount));
            assertEq(spotEngine.getTotalBalance(address(collateralToken)), totalAmount);
        }
    }

    function test_depositWithAuthorization_revertsIfZeroAmount() public {
        vm.startPrank(sequencer);

        address account = makeAddr("account");
        uint128 zeroAmount = 0;
        vm.expectRevert(Errors.Exchange_ZeroAmount.selector);
        exchange.depositWithAuthorization(address(collateralToken), account, zeroAmount, 0, 0, 0, "");

        uint128 maxZeroScaledAmount = _maxZeroScaledAmount();
        vm.expectRevert(Errors.Exchange_ZeroAmount.selector);
        exchange.depositWithAuthorization(address(collateralToken), account, maxZeroScaledAmount, 0, 0, 0, "");
    }

    function test_depositWithAuthorization_revertsIfTokenNotSupported() public {
        vm.startPrank(sequencer);
        address notSupportedToken = makeAddr("notSupportedToken");
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_TokenNotSupported.selector, notSupportedToken));
        exchange.depositWithAuthorization(notSupportedToken, makeAddr("account"), 100, 0, 0, 0, "");
    }

    function test_depositWithAuthorization_revertsIfDisabledDeposit() public {
        vm.startPrank(sequencer);
        exchange.setCanDeposit(false);

        vm.expectRevert(Errors.Exchange_DisabledDeposit.selector);
        exchange.depositWithAuthorization(address(collateralToken), makeAddr("account"), 100, 0, 0, 0, "");
    }

    function test_processBatch_transferToBSX1000_withEOA() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        uint128 balance = 300 * 1e18;
        _prepareDeposit(address(this), balance);
        exchange.deposit(account, address(collateralToken), balance);

        int256 accountBalanceStateBefore = spotEngine.getBalance(address(collateralToken), account);
        uint256 totalBalanceStateBefore = spotEngine.getTotalBalance(address(collateralToken));
        IBSX1000x.Balance memory bsx1000BalanceStateBefore = bsx1000.getBalance(account);

        uint256 exchangeBalanceBefore = collateralToken.balanceOf(address(exchange));
        uint256 bsx1000BalanceBefore = collateralToken.balanceOf(address(bsx1000));
        uint256 accountBalanceBefore = collateralToken.balanceOf(account);

        uint128 transferAmount = 145 * 1e18;
        uint64 nonce = 1;
        bytes memory signature = _signTypedDataHash(
            accountKey,
            keccak256(
                abi.encode(
                    exchange.TRANSFER_TO_BSX1000_TYPEHASH(), account, address(collateralToken), transferAmount, nonce
                )
            )
        );
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.TransferToBSX1000,
            abi.encode(
                IExchange.TransferToBSX1000Params(account, address(collateralToken), transferAmount, nonce, signature)
            )
        );

        uint256 balanceAfter = totalBalanceStateBefore - transferAmount;
        vm.expectEmit(address(exchange));
        emit IExchange.TransferToBSX1000(
            address(collateralToken),
            account,
            nonce,
            transferAmount,
            balanceAfter,
            IExchange.TransferToBSX1000Status.Success
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isTransferToBSX1000NonceUsed(account, nonce), true);
        assertEq(
            spotEngine.getBalance(address(collateralToken), account), accountBalanceStateBefore - int128(transferAmount)
        );
        assertEq(spotEngine.getTotalBalance(address(collateralToken)), balanceAfter);

        IBSX1000x.Balance memory bsx1000BalanceStateAfter = bsx1000.getBalance(account);
        assertEq(bsx1000BalanceStateAfter.available, bsx1000BalanceStateBefore.available + transferAmount);
        assertEq(bsx1000BalanceStateAfter.locked, bsx1000BalanceStateBefore.locked);

        uint8 tokenDecimals = collateralToken.decimals();
        assertEq(collateralToken.balanceOf(account), accountBalanceBefore);
        assertEq(
            collateralToken.balanceOf(address(exchange)),
            exchangeBalanceBefore - transferAmount.convertFrom18D(tokenDecimals)
        );
        assertEq(
            collateralToken.balanceOf(address(bsx1000)),
            bsx1000BalanceBefore + transferAmount.convertFrom18D(tokenDecimals)
        );
    }

    function test_processBatch_transferToBSX1000_smartContract() public {
        collateralToken.mint(address(exchange), type(uint128).max);

        (address owner, uint256 ownerKey) = makeAddrAndKey("owner");
        address contractAccount = address(new ERC1271(owner));
        uint128 balance = 300 * 1e18;
        _prepareDeposit(address(this), balance);
        exchange.deposit(contractAccount, address(collateralToken), balance);

        int256 accountBalanceStateBefore = spotEngine.getBalance(address(collateralToken), contractAccount);
        uint256 totalBalanceStateBefore = spotEngine.getTotalBalance(address(collateralToken));
        IBSX1000x.Balance memory bsx1000BalanceStateBefore = bsx1000.getBalance(contractAccount);

        uint256 exchangeBalanceBefore = collateralToken.balanceOf(address(exchange));
        uint256 bsx1000BalanceBefore = collateralToken.balanceOf(address(bsx1000));
        uint256 accountBalanceBefore = collateralToken.balanceOf(contractAccount);

        uint128 transferAmount = 145 * 1e18;
        uint64 nonce = 1;
        bytes memory signature = _signTypedDataHash(
            ownerKey,
            keccak256(
                abi.encode(
                    exchange.TRANSFER_TO_BSX1000_TYPEHASH(),
                    contractAccount,
                    address(collateralToken),
                    transferAmount,
                    nonce
                )
            )
        );
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.TransferToBSX1000,
            abi.encode(
                IExchange.TransferToBSX1000Params(
                    contractAccount, address(collateralToken), transferAmount, nonce, signature
                )
            )
        );

        uint256 balanceAfter = totalBalanceStateBefore - transferAmount;
        vm.expectEmit(address(exchange));
        emit IExchange.TransferToBSX1000(
            address(collateralToken),
            contractAccount,
            nonce,
            transferAmount,
            balanceAfter,
            IExchange.TransferToBSX1000Status.Success
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isTransferToBSX1000NonceUsed(contractAccount, nonce), true);
        assertEq(
            spotEngine.getBalance(address(collateralToken), contractAccount),
            accountBalanceStateBefore - int128(transferAmount)
        );
        assertEq(spotEngine.getTotalBalance(address(collateralToken)), balanceAfter);

        IBSX1000x.Balance memory bsx1000BalanceStateAfter = bsx1000.getBalance(contractAccount);
        assertEq(bsx1000BalanceStateAfter.available, bsx1000BalanceStateBefore.available + transferAmount);
        assertEq(bsx1000BalanceStateAfter.locked, bsx1000BalanceStateBefore.locked);

        uint8 tokenDecimals = collateralToken.decimals();
        assertEq(collateralToken.balanceOf(contractAccount), accountBalanceBefore);
        assertEq(
            collateralToken.balanceOf(address(exchange)),
            exchangeBalanceBefore - transferAmount.convertFrom18D(tokenDecimals)
        );
        assertEq(
            collateralToken.balanceOf(address(bsx1000)),
            bsx1000BalanceBefore + transferAmount.convertFrom18D(tokenDecimals)
        );
    }

    function test_processBatch_transferToBSX1000_revertsIfNonceUsed() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        uint128 amount = 300 * 1e18;
        _prepareDeposit(address(this), amount);
        exchange.deposit(account, address(collateralToken), amount);

        vm.startPrank(sequencer);

        uint64 nonce = 1;
        bytes memory signature = _signTypedDataHash(
            accountKey,
            keccak256(
                abi.encode(exchange.TRANSFER_TO_BSX1000_TYPEHASH(), account, address(collateralToken), amount, nonce)
            )
        );
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.TransferToBSX1000,
            abi.encode(IExchange.TransferToBSX1000Params(account, address(collateralToken), amount, nonce, signature))
        );
        exchange.processBatch(operation.toArray());

        operation = _encodeDataToOperation(
            IExchange.OperationType.TransferToBSX1000,
            abi.encode(IExchange.TransferToBSX1000Params(account, address(collateralToken), amount, nonce, signature))
        );
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_TransferToBSX1000_NonceUsed.selector, account, nonce));
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_transferToBSX1000_emitsFailedEventIfInvalidSignature() public {
        address account = makeAddr("account");
        (, uint256 maliciousKey) = makeAddrAndKey("malicious");

        int256 accountBalanceStateBefore = spotEngine.getBalance(address(collateralToken), account);
        uint256 totalBalanceStateBefore = spotEngine.getTotalBalance(address(collateralToken));
        IBSX1000x.Balance memory bsx1000BalanceStateBefore = bsx1000.getBalance(account);

        uint256 exchangeBalanceBefore = collateralToken.balanceOf(address(exchange));
        uint256 bsx1000BalanceBefore = collateralToken.balanceOf(address(bsx1000));
        uint256 accountBalanceBefore = collateralToken.balanceOf(account);

        uint64 nonce = 1;
        uint128 amount = 300 * 1e18;
        bytes memory signature = _signTypedDataHash(
            maliciousKey,
            keccak256(
                abi.encode(exchange.TRANSFER_TO_BSX1000_TYPEHASH(), account, address(collateralToken), amount, nonce)
            )
        );
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.TransferToBSX1000,
            abi.encode(IExchange.TransferToBSX1000Params(account, address(collateralToken), amount, nonce, signature))
        );
        vm.expectEmit(address(exchange));
        emit IExchange.TransferToBSX1000(
            address(collateralToken), account, nonce, amount, 0, IExchange.TransferToBSX1000Status.Failure
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isTransferToBSX1000NonceUsed(account, nonce), true);
        assertEq(spotEngine.getBalance(address(collateralToken), account), accountBalanceStateBefore);
        assertEq(spotEngine.getTotalBalance(address(collateralToken)), totalBalanceStateBefore);

        IBSX1000x.Balance memory bsx1000BalanceStateAfter = bsx1000.getBalance(account);
        assertEq(bsx1000BalanceStateAfter.available, bsx1000BalanceStateBefore.available);
        assertEq(bsx1000BalanceStateAfter.locked, bsx1000BalanceStateBefore.locked);

        assertEq(collateralToken.balanceOf(account), accountBalanceBefore);
        assertEq(collateralToken.balanceOf(address(exchange)), exchangeBalanceBefore);
        assertEq(collateralToken.balanceOf(address(bsx1000)), bsx1000BalanceBefore);
    }

    function test_processBatch_transferToBSX1000_emitsFailedEventIfInvalidToken() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");

        int256 accountBalanceStateBefore = spotEngine.getBalance(address(collateralToken), account);
        uint256 totalBalanceStateBefore = spotEngine.getTotalBalance(address(collateralToken));
        IBSX1000x.Balance memory bsx1000BalanceStateBefore = bsx1000.getBalance(account);

        uint256 exchangeBalanceBefore = collateralToken.balanceOf(address(exchange));
        uint256 bsx1000BalanceBefore = collateralToken.balanceOf(address(bsx1000));
        uint256 accountBalanceBefore = collateralToken.balanceOf(account);

        vm.startPrank(sequencer);

        address invalidToken = makeAddr("invalidToken");
        exchange.addSupportedToken(invalidToken);

        uint64 nonce = 1;
        uint128 amount = 100 * 1e18;
        bytes memory signature = _signTypedDataHash(
            accountKey,
            keccak256(abi.encode(exchange.TRANSFER_TO_BSX1000_TYPEHASH(), account, invalidToken, amount, nonce))
        );
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.TransferToBSX1000,
            abi.encode(IExchange.TransferToBSX1000Params(account, invalidToken, amount, nonce, signature))
        );

        vm.expectEmit(address(exchange));
        emit IExchange.TransferToBSX1000(
            invalidToken, account, nonce, amount, 0, IExchange.TransferToBSX1000Status.Failure
        );
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isTransferToBSX1000NonceUsed(account, nonce), true);
        assertEq(spotEngine.getBalance(address(collateralToken), account), accountBalanceStateBefore);
        assertEq(spotEngine.getTotalBalance(address(collateralToken)), totalBalanceStateBefore);

        IBSX1000x.Balance memory bsx1000BalanceStateAfter = bsx1000.getBalance(account);
        assertEq(bsx1000BalanceStateAfter.available, bsx1000BalanceStateBefore.available);
        assertEq(bsx1000BalanceStateAfter.locked, bsx1000BalanceStateBefore.locked);

        assertEq(collateralToken.balanceOf(account), accountBalanceBefore);
        assertEq(collateralToken.balanceOf(address(exchange)), exchangeBalanceBefore);
        assertEq(collateralToken.balanceOf(address(bsx1000)), bsx1000BalanceBefore);
    }

    function test_processBatch_transferToBSX1000_emitsFailedEventIfAmountExceedsBalance() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        uint128 balance = 300 * 1e18;
        _prepareDeposit(address(this), balance);
        exchange.deposit(account, address(collateralToken), balance);

        int256 accountBalanceStateBefore = spotEngine.getBalance(address(collateralToken), account);
        uint256 totalBalanceStateBefore = spotEngine.getTotalBalance(address(collateralToken));
        IBSX1000x.Balance memory bsx1000BalanceStateBefore = bsx1000.getBalance(account);

        uint256 exchangeBalanceBefore = collateralToken.balanceOf(address(exchange));
        uint256 bsx1000BalanceBefore = collateralToken.balanceOf(address(bsx1000));
        uint256 accountBalanceBefore = collateralToken.balanceOf(account);

        uint128 transferAmount = 301 * 1e18;
        uint64 nonce = 1;
        bytes memory signature = _signTypedDataHash(
            accountKey,
            keccak256(
                abi.encode(
                    exchange.TRANSFER_TO_BSX1000_TYPEHASH(), account, address(collateralToken), transferAmount, nonce
                )
            )
        );
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.TransferToBSX1000,
            abi.encode(
                IExchange.TransferToBSX1000Params(account, address(collateralToken), transferAmount, nonce, signature)
            )
        );

        vm.expectEmit(address(exchange));
        emit IExchange.TransferToBSX1000(
            address(collateralToken), account, nonce, transferAmount, 0, IExchange.TransferToBSX1000Status.Failure
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isTransferToBSX1000NonceUsed(account, nonce), true);
        assertEq(spotEngine.getBalance(address(collateralToken), account), accountBalanceStateBefore);
        assertEq(spotEngine.getTotalBalance(address(collateralToken)), totalBalanceStateBefore);

        IBSX1000x.Balance memory bsx1000BalanceStateAfter = bsx1000.getBalance(account);
        assertEq(bsx1000BalanceStateAfter.available, bsx1000BalanceStateBefore.available);
        assertEq(bsx1000BalanceStateAfter.locked, bsx1000BalanceStateBefore.locked);

        assertEq(collateralToken.balanceOf(account), accountBalanceBefore);
        assertEq(collateralToken.balanceOf(address(exchange)), exchangeBalanceBefore);
        assertEq(collateralToken.balanceOf(address(bsx1000)), bsx1000BalanceBefore);
    }

    function test_processBatch_transferToBSX1000_revertsIfZeroAmount() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        uint128 balance = 300 * 1e18;
        _prepareDeposit(address(this), balance);
        exchange.deposit(account, address(collateralToken), balance);

        int256 accountBalanceStateBefore = spotEngine.getBalance(address(collateralToken), account);
        uint256 totalBalanceStateBefore = spotEngine.getTotalBalance(address(collateralToken));
        IBSX1000x.Balance memory bsx1000BalanceStateBefore = bsx1000.getBalance(account);

        uint256 exchangeBalanceBefore = collateralToken.balanceOf(address(exchange));
        uint256 bsx1000BalanceBefore = collateralToken.balanceOf(address(bsx1000));
        uint256 accountBalanceBefore = collateralToken.balanceOf(account);

        uint128 transferAmount = _maxZeroScaledAmount();
        uint64 nonce = 1;
        bytes memory signature = _signTypedDataHash(
            accountKey,
            keccak256(
                abi.encode(
                    exchange.TRANSFER_TO_BSX1000_TYPEHASH(), account, address(collateralToken), transferAmount, nonce
                )
            )
        );
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.TransferToBSX1000,
            abi.encode(
                IExchange.TransferToBSX1000Params(account, address(collateralToken), transferAmount, nonce, signature)
            )
        );

        vm.expectEmit(address(exchange));
        emit IExchange.TransferToBSX1000(
            address(collateralToken), account, nonce, transferAmount, 0, IExchange.TransferToBSX1000Status.Failure
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isTransferToBSX1000NonceUsed(account, nonce), true);
        assertEq(spotEngine.getBalance(address(collateralToken), account), accountBalanceStateBefore);
        assertEq(spotEngine.getTotalBalance(address(collateralToken)), totalBalanceStateBefore);

        IBSX1000x.Balance memory bsx1000BalanceStateAfter = bsx1000.getBalance(account);
        assertEq(bsx1000BalanceStateAfter.available, bsx1000BalanceStateBefore.available);
        assertEq(bsx1000BalanceStateAfter.locked, bsx1000BalanceStateBefore.locked);

        assertEq(collateralToken.balanceOf(account), accountBalanceBefore);
        assertEq(collateralToken.balanceOf(address(exchange)), exchangeBalanceBefore);
        assertEq(collateralToken.balanceOf(address(bsx1000)), bsx1000BalanceBefore);
    }

    function test_innerTransferToBSX1000_revertsIfCallerNotContract() public {
        IExchange.TransferToBSX1000Params memory emptyParams;
        vm.expectRevert(Errors.Exchange_InternalCall.selector);
        exchange.innerTransferToBSX1000(emptyParams);
    }

    function test_processBatch_withdraw_EOA() public {
        collateralToken.mint(address(exchange), type(uint128).max);

        uint128 amount = 5 * 1e18;
        (address account, uint256 accountKey) = makeAddrAndKey("account");

        {
            vm.startPrank(address(exchange));
            ISpot.AccountDelta[] memory deltas = new ISpot.AccountDelta[](1);
            deltas[0] = ISpot.AccountDelta({token: address(collateralToken), account: account, amount: int128(amount)});
            spotEngine.modifyAccount(deltas);
            spotEngine.setTotalBalance(address(collateralToken), amount, true);
            vm.stopPrank();
        }

        int256 accountBalanceStateBefore = spotEngine.getBalance(address(collateralToken), account);
        uint256 totalBalanceStateBefore = spotEngine.getTotalBalance(address(collateralToken));

        uint256 exchangeBalanceBefore = collateralToken.balanceOf(address(exchange));
        uint256 accountBalanceBefore = collateralToken.balanceOf(account);

        uint64 nonce = 1;
        bytes memory signature = _signTypedDataHash(
            accountKey,
            keccak256(abi.encode(exchange.WITHDRAW_TYPEHASH(), account, address(collateralToken), amount, nonce))
        );
        uint128 withdrawFee = 1 * 1e16;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.Withdraw,
            abi.encode(IExchange.Withdraw(account, address(collateralToken), amount, nonce, signature, withdrawFee))
        );

        uint256 balanceAfter = totalBalanceStateBefore - amount;
        vm.expectEmit(address(exchange));
        emit IExchange.WithdrawSucceeded(address(collateralToken), account, nonce, amount, 0, withdrawFee);
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isWithdrawNonceUsed(account, nonce), true);
        assertEq(spotEngine.getBalance(address(collateralToken), account), accountBalanceStateBefore - int128(amount));
        assertEq(spotEngine.getTotalBalance(address(collateralToken)), balanceAfter);

        uint8 tokenDecimals = collateralToken.decimals();
        uint128 netAmount = amount - withdrawFee;
        assertEq(collateralToken.balanceOf(account), accountBalanceBefore + netAmount.convertFrom18D(tokenDecimals));
        assertEq(
            collateralToken.balanceOf(address(exchange)),
            exchangeBalanceBefore - netAmount.convertFrom18D(tokenDecimals)
        );
    }

    function test_processBatch_withdraw_smartContract() public {
        collateralToken.mint(address(exchange), type(uint128).max);

        (address owner, uint256 ownerKey) = makeAddrAndKey("owner");
        address contractAccount = address(new ERC1271(owner));
        uint128 amount = 5 * 1e18;

        {
            vm.startPrank(address(exchange));
            ISpot.AccountDelta[] memory deltas = new ISpot.AccountDelta[](1);
            deltas[0] =
                ISpot.AccountDelta({token: address(collateralToken), account: contractAccount, amount: int128(amount)});
            spotEngine.modifyAccount(deltas);
            spotEngine.setTotalBalance(address(collateralToken), amount, true);
            vm.stopPrank();
        }

        int256 accountBalanceStateBefore = spotEngine.getBalance(address(collateralToken), contractAccount);
        uint256 totalBalanceStateBefore = spotEngine.getTotalBalance(address(collateralToken));

        uint256 exchangeBalanceBefore = collateralToken.balanceOf(address(exchange));
        uint256 accountBalanceBefore = collateralToken.balanceOf(contractAccount);

        uint64 nonce = 1;
        bytes memory signature = _signTypedDataHash(
            ownerKey,
            keccak256(
                abi.encode(exchange.WITHDRAW_TYPEHASH(), contractAccount, address(collateralToken), amount, nonce)
            )
        );
        uint128 withdrawFee = 1 * 1e16;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.Withdraw,
            abi.encode(
                IExchange.Withdraw(contractAccount, address(collateralToken), amount, nonce, signature, withdrawFee)
            )
        );

        uint256 balanceAfter = totalBalanceStateBefore - amount;
        vm.expectEmit(address(exchange));
        emit IExchange.WithdrawSucceeded(address(collateralToken), contractAccount, nonce, amount, 0, withdrawFee);
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isWithdrawNonceUsed(contractAccount, nonce), true);
        assertEq(
            spotEngine.getBalance(address(collateralToken), contractAccount), accountBalanceStateBefore - int128(amount)
        );
        assertEq(spotEngine.getTotalBalance(address(collateralToken)), balanceAfter);

        uint8 tokenDecimals = collateralToken.decimals();
        uint128 netAmount = amount - withdrawFee;
        assertEq(
            collateralToken.balanceOf(contractAccount), accountBalanceBefore + netAmount.convertFrom18D(tokenDecimals)
        );
        assertEq(
            collateralToken.balanceOf(address(exchange)),
            exchangeBalanceBefore - netAmount.convertFrom18D(tokenDecimals)
        );
    }

    function test_processBatch_withdraw_notUnderlyingToken() public {
        ERC20Simple newToken = new ERC20Simple(6);

        vm.prank(sequencer);
        exchange.addSupportedToken(address(newToken));

        newToken.mint(address(exchange), type(uint128).max);

        uint128 amount = 5 * 1e18;
        (address account, uint256 accountKey) = makeAddrAndKey("account");

        {
            vm.startPrank(address(exchange));
            ISpot.AccountDelta[] memory deltas = new ISpot.AccountDelta[](1);
            deltas[0] = ISpot.AccountDelta({token: address(newToken), account: account, amount: int128(amount)});
            spotEngine.modifyAccount(deltas);
            spotEngine.setTotalBalance(address(newToken), amount, true);
            vm.stopPrank();
        }

        int256 accountBalanceStateBefore = spotEngine.getBalance(address(newToken), account);
        uint256 totalBalanceStateBefore = spotEngine.getTotalBalance(address(newToken));

        uint256 exchangeBalanceBefore = newToken.balanceOf(address(exchange));
        uint256 accountBalanceBefore = newToken.balanceOf(account);

        uint64 nonce = 1;
        bytes memory signature = _signTypedDataHash(
            accountKey, keccak256(abi.encode(exchange.WITHDRAW_TYPEHASH(), account, address(newToken), amount, nonce))
        );
        uint128 withdrawFee = 1 * 1e16;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.Withdraw,
            abi.encode(IExchange.Withdraw(account, address(newToken), amount, nonce, signature, withdrawFee))
        );

        uint256 balanceAfter = totalBalanceStateBefore - amount;
        vm.expectEmit(address(exchange));
        emit IExchange.WithdrawSucceeded(address(newToken), account, nonce, amount, 0, withdrawFee);
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isWithdrawNonceUsed(account, nonce), true);
        assertEq(spotEngine.getBalance(address(newToken), account), accountBalanceStateBefore - int128(amount));
        assertEq(spotEngine.getTotalBalance(address(newToken)), balanceAfter);

        uint8 tokenDecimals = newToken.decimals();
        uint128 netAmount = amount - withdrawFee;
        assertEq(newToken.balanceOf(account), accountBalanceBefore + netAmount.convertFrom18D(tokenDecimals));
        assertEq(newToken.balanceOf(address(exchange)), exchangeBalanceBefore - netAmount.convertFrom18D(tokenDecimals));
    }

    function test_processBatch_withdraw_nativeETH_withEOA() public {
        bytes memory code = address(new WETH9Mock()).code;
        vm.etch(WETH9, code);

        vm.prank(sequencer);
        exchange.addSupportedToken(NATIVE_ETH);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        uint128 amount = 5 ether;
        vm.deal(account, amount);

        vm.prank(account);
        exchange.deposit{value: amount}(NATIVE_ETH, amount);

        int256 accountBalanceStateBefore = spotEngine.getBalance(WETH9, account);
        uint256 totalBalanceStateBefore = spotEngine.getTotalBalance(WETH9);

        uint256 exchangeBalanceBefore = ERC20Simple(WETH9).balanceOf(address(exchange));
        uint256 accountBalanceBefore = account.balance;

        uint64 nonce = 1;
        bytes memory signature = _signTypedDataHash(
            accountKey, keccak256(abi.encode(exchange.WITHDRAW_TYPEHASH(), account, NATIVE_ETH, amount, nonce))
        );
        uint128 withdrawFee = 0.001 ether;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.Withdraw,
            abi.encode(IExchange.Withdraw(account, NATIVE_ETH, amount, nonce, signature, withdrawFee))
        );

        uint256 balanceAfter = totalBalanceStateBefore - amount;
        vm.expectEmit(address(exchange));
        emit IExchange.WithdrawSucceeded(NATIVE_ETH, account, nonce, amount, 0, withdrawFee);
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isWithdrawNonceUsed(account, nonce), true);
        assertEq(spotEngine.getBalance(WETH9, account), accountBalanceStateBefore - int128(amount));
        assertEq(spotEngine.getTotalBalance(WETH9), balanceAfter);

        uint128 netAmount = amount - withdrawFee;
        assertEq(account.balance, accountBalanceBefore + netAmount);
        assertEq(ERC20Simple(WETH9).balanceOf(address(exchange)), exchangeBalanceBefore - netAmount);
    }

    function test_processBatch_withdraw_nativeETH_revertsIfSmartContract() public {
        bytes memory code = address(new WETH9Mock()).code;
        vm.etch(WETH9, code);

        vm.prank(sequencer);
        exchange.addSupportedToken(NATIVE_ETH);

        (address owner, uint256 ownerKey) = makeAddrAndKey("owner");
        address contractAccount = address(new ERC1271(owner));
        uint128 amount = 5 ether;
        vm.deal(owner, amount);

        vm.prank(owner);
        exchange.deposit{value: amount}(contractAccount, NATIVE_ETH, amount);

        int256 contractBalanceStateBefore = spotEngine.getBalance(WETH9, contractAccount);
        uint256 totalBalanceStateBefore = spotEngine.getTotalBalance(WETH9);

        uint256 exchangeBalanceBefore = ERC20Simple(WETH9).balanceOf(address(exchange));
        uint256 contractBalanceBefore = contractAccount.balance;

        uint64 nonce = 1;
        bytes memory signature = _signTypedDataHash(
            ownerKey, keccak256(abi.encode(exchange.WITHDRAW_TYPEHASH(), contractAccount, NATIVE_ETH, amount, nonce))
        );
        uint128 withdrawFee = 0.001 ether;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.Withdraw,
            abi.encode(IExchange.Withdraw(contractAccount, NATIVE_ETH, amount, nonce, signature, withdrawFee))
        );

        vm.expectEmit(address(exchange));
        emit IExchange.WithdrawFailed(contractAccount, nonce, 0, 0);
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isWithdrawNonceUsed(contractAccount, nonce), true);
        assertEq(spotEngine.getBalance(WETH9, contractAccount), contractBalanceStateBefore);
        assertEq(spotEngine.getTotalBalance(WETH9), totalBalanceStateBefore);

        assertEq(contractAccount.balance, contractBalanceBefore);
        assertEq(ERC20Simple(WETH9).balanceOf(address(exchange)), exchangeBalanceBefore);
    }

    function test_processBatch_withdraw_revertsIfDisabledWithdraw() public {
        vm.startPrank(sequencer);
        exchange.setCanWithdraw(false);

        address account = makeAddr("account");
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.Withdraw,
            abi.encode(IExchange.Withdraw(account, address(collateralToken), 100, 0, "", 0))
        );
        vm.expectRevert(Errors.Exchange_DisabledWithdraw.selector);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_withdraw_smartContract_revertsIfInvalidSignature() public {
        collateralToken.mint(address(exchange), type(uint128).max);

        (address owner, uint256 ownerKey) = makeAddrAndKey("owner");
        address contractAccount = address(new ERC1271(owner));
        uint128 amount = 5 * 1e18;

        {
            vm.startPrank(address(exchange));
            ISpot.AccountDelta[] memory deltas = new ISpot.AccountDelta[](1);
            deltas[0] =
                ISpot.AccountDelta({token: address(collateralToken), account: contractAccount, amount: int128(amount)});
            spotEngine.modifyAccount(deltas);
            spotEngine.setTotalBalance(address(collateralToken), amount, true);
            vm.stopPrank();
        }

        int256 accountBalanceStateBefore = spotEngine.getBalance(address(collateralToken), contractAccount);
        uint256 totalBalanceStateBefore = spotEngine.getTotalBalance(address(collateralToken));

        uint256 exchangeBalanceBefore = collateralToken.balanceOf(address(exchange));
        uint256 accountBalanceBefore = collateralToken.balanceOf(contractAccount);

        uint64 nonce = 1;
        bytes memory signature = _signTypedDataHash(
            ownerKey,
            keccak256(
                abi.encode(exchange.WITHDRAW_TYPEHASH(), contractAccount, address(collateralToken), amount, nonce)
            )
        );
        uint128 withdrawFee = 1 * 1e16;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.Withdraw,
            abi.encode(
                IExchange.Withdraw(contractAccount, address(collateralToken), amount, nonce, signature, withdrawFee)
            )
        );

        // contract updates the owner before the withdraw is processed
        ERC1271(contractAccount).setNewOwner(makeAddr("newOwner"));

        vm.expectEmit(address(exchange));
        emit IExchange.WithdrawFailed(contractAccount, nonce, 0, 0);
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isWithdrawNonceUsed(contractAccount, nonce), true);
        assertEq(spotEngine.getBalance(address(collateralToken), contractAccount), accountBalanceStateBefore);
        assertEq(spotEngine.getTotalBalance(address(collateralToken)), totalBalanceStateBefore);

        assertEq(collateralToken.balanceOf(contractAccount), accountBalanceBefore);
        assertEq(collateralToken.balanceOf(address(exchange)), exchangeBalanceBefore);
    }

    function test_processBatch_withdraw_revertsIfExceededMaxFee() public {
        vm.startPrank(sequencer);

        (address account, uint256 accountKey) = makeAddrAndKey("account");

        uint64 nonce = 1;
        uint128 amount = 5 * 1e18;
        bytes memory signature = _signTypedDataHash(
            accountKey,
            keccak256(abi.encode(exchange.WITHDRAW_TYPEHASH(), account, address(collateralToken), amount, nonce))
        );

        // fee on stable tokens
        uint128 invalidFee = 1 ether + 1;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.Withdraw,
            abi.encode(IExchange.Withdraw(account, address(collateralToken), amount, nonce, signature, invalidFee))
        );
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_ExceededMaxWithdrawFee.selector, invalidFee, 1 ether));
        exchange.processBatch(operation.toArray());

        // fee on weth
        signature = _signTypedDataHash(
            accountKey, keccak256(abi.encode(exchange.WITHDRAW_TYPEHASH(), account, WETH9, amount, nonce))
        );
        invalidFee = 0.001 ether + 1;
        operation = _encodeDataToOperation(
            IExchange.OperationType.Withdraw,
            abi.encode(IExchange.Withdraw(account, WETH9, amount, nonce, signature, invalidFee))
        );
        vm.expectRevert(
            abi.encodeWithSelector(Errors.Exchange_ExceededMaxWithdrawFee.selector, invalidFee, 0.001 ether)
        );
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_withdraw_revertsIfNonceUsed() public {
        collateralToken.mint(address(exchange), type(uint128).max);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        uint128 amount = 5 * 1e18;

        {
            vm.startPrank(address(exchange));
            ISpot.AccountDelta[] memory deltas = new ISpot.AccountDelta[](1);
            deltas[0] = ISpot.AccountDelta({token: address(collateralToken), account: account, amount: int128(amount)});
            spotEngine.modifyAccount(deltas);
            spotEngine.setTotalBalance(address(collateralToken), amount, true);
            vm.stopPrank();
        }

        vm.startPrank(sequencer);

        uint64 nonce = 1;
        bytes memory signature = _signTypedDataHash(
            accountKey,
            keccak256(abi.encode(exchange.WITHDRAW_TYPEHASH(), account, address(collateralToken), amount, nonce))
        );
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.Withdraw,
            abi.encode(IExchange.Withdraw(account, address(collateralToken), amount, nonce, signature, 0))
        );
        exchange.processBatch(operation.toArray());

        operation = _encodeDataToOperation(
            IExchange.OperationType.Withdraw,
            abi.encode(IExchange.Withdraw(account, address(collateralToken), amount, nonce, signature, 0))
        );
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_Withdraw_NonceUsed.selector, account, nonce));
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_withdraw_revertsIfWithdrawAmountExceedBalance() public {
        collateralToken.mint(address(exchange), type(uint128).max);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        uint128 balance = 5 * 1e18;

        {
            vm.startPrank(address(exchange));
            ISpot.AccountDelta[] memory deltas = new ISpot.AccountDelta[](1);
            deltas[0] = ISpot.AccountDelta({token: address(collateralToken), account: account, amount: int128(balance)});
            spotEngine.modifyAccount(deltas);
            spotEngine.setTotalBalance(address(collateralToken), balance, true);
            vm.stopPrank();
        }

        int256 accountBalanceStateBefore = spotEngine.getBalance(address(collateralToken), account);
        uint256 totalBalanceStateBefore = spotEngine.getTotalBalance(address(collateralToken));

        uint256 exchangeBalanceBefore = collateralToken.balanceOf(address(exchange));
        uint256 accountBalanceBefore = collateralToken.balanceOf(account);

        vm.startPrank(sequencer);

        uint64 nonce = 1;
        uint128 withdrawAmount = balance + 1;
        bytes memory signature = _signTypedDataHash(
            accountKey,
            keccak256(
                abi.encode(exchange.WITHDRAW_TYPEHASH(), account, address(collateralToken), withdrawAmount, nonce)
            )
        );
        bytes memory data =
            abi.encode(IExchange.Withdraw(account, address(collateralToken), withdrawAmount, nonce, signature, 0));
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.Withdraw, data);
        vm.expectEmit(address(exchange));
        emit IExchange.WithdrawFailed(account, nonce, withdrawAmount, int128(balance));
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isWithdrawNonceUsed(account, nonce), true);
        assertEq(spotEngine.getBalance(address(collateralToken), account), accountBalanceStateBefore);
        assertEq(spotEngine.getTotalBalance(address(collateralToken)), totalBalanceStateBefore);

        assertEq(collateralToken.balanceOf(account), accountBalanceBefore);
        assertEq(collateralToken.balanceOf(address(exchange)), exchangeBalanceBefore);
    }

    function test_setCanDeposit() public {
        vm.startPrank(sequencer);

        bool canDeposit = exchange.canDeposit();

        exchange.setCanDeposit(!canDeposit);
        assertEq(exchange.canDeposit(), !canDeposit);

        exchange.setCanDeposit(canDeposit);
        assertEq(exchange.canDeposit(), canDeposit);
    }

    function test_setCanDeposit_revertsWhenUnauthorized() public {
        address malicious = makeAddr("malicious");
        bytes32 role = access.GENERAL_ROLE();

        vm.startPrank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        exchange.setCanDeposit(true);
    }

    function _prepareDeposit(address account, uint128 amount) private {
        _prepareDeposit(account, address(collateralToken), amount);
    }

    function _prepareDeposit(address account, address token, uint128 amount) private {
        uint8 decimals = ERC20Simple(token).decimals();
        uint256 rawAmount = amount.convertFrom18D(decimals);
        ERC20Simple(token).mint(account, rawAmount);
        ERC20Simple(token).approve(address(exchange), rawAmount);
    }

    function _encodeDataToOperation(IExchange.OperationType operationType, bytes memory data)
        private
        view
        returns (bytes memory)
    {
        uint32 transactionId = exchange.executedTransactionCounter();
        return abi.encodePacked(operationType, transactionId, data);
    }

    function _signTypedDataHash(uint256 privateKey, bytes32 structHash) private view returns (bytes memory signature) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            exchange.eip712Domain();
        bytes32 domainSeparator = keccak256(
            abi.encode(TYPE_HASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract)
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function _maxZeroScaledAmount() private view returns (uint128) {
        return uint128(uint128(1).convertTo18D(collateralToken.decimals()) - 1);
    }
}

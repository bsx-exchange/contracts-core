// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {Helper} from "../Helper.sol";
import {ERC1271} from "../mock/ERC1271.sol";
import {ERC20MissingReturn} from "../mock/ERC20MissingReturn.sol";
import {ERC20Simple} from "../mock/ERC20Simple.sol";

import {MockERC4626} from "../mock/MockERC4626.sol";
import {UniversalSigValidator} from "../mock/UniversalSigValidator.sol";
import {WETH9Mock} from "../mock/WETH9.sol";

import {BSX1000x, IBSX1000x} from "contracts/1000x/BSX1000x.sol";
import {ClearingService, IClearingService} from "contracts/exchange/ClearingService.sol";
import {Exchange, IExchange} from "contracts/exchange/Exchange.sol";
import {OrderBook} from "contracts/exchange/OrderBook.sol";
import {Perp} from "contracts/exchange/Perp.sol";
import {Spot} from "contracts/exchange/Spot.sol";
import {VaultManager} from "contracts/exchange/VaultManager.sol";
import {Access} from "contracts/exchange/access/Access.sol";
import {IERC3009Minimal} from "contracts/exchange/interfaces/external/IERC3009Minimal.sol";
import {Errors} from "contracts/exchange/lib/Errors.sol";
import {MathHelper} from "contracts/exchange/lib/MathHelper.sol";
import {Roles} from "contracts/exchange/lib/Roles.sol";
import {NATIVE_ETH, UNIVERSAL_SIG_VALIDATOR, WETH9} from "contracts/exchange/share/Constants.sol";
import {TxStatus} from "contracts/exchange/share/Enums.sol";

// solhint-disable max-states-count
contract BalanceExchangeTest is Test {
    using stdStorage for StdStorage;
    using Helper for bytes;
    using Helper for uint128;
    using MathHelper for int128;
    using MathHelper for uint128;
    using MathHelper for uint256;

    address private sequencer = makeAddr("sequencer");

    ERC20Simple private collateralToken = new ERC20Simple(6);

    Access private access;
    Exchange private exchange;
    ClearingService private clearingService;
    OrderBook private orderbook;
    Spot private spotEngine;
    Perp private perpEngine;

    BSX1000x private bsx1000;

    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant CREATE_SUBACCOUNT_TYPEHASH = keccak256("CreateSubaccount(address main,address subaccount)");
    bytes32 private constant DELETE_SUBACCOUNT_TYPEHASH = keccak256("DeleteSubaccount(address main,address subaccount)");
    bytes32 public constant TRANSFER_TYPEHASH =
        keccak256("Transfer(address from,address to,address token,uint256 amount,uint256 nonce)");
    bytes32 private constant TRANSFER_TO_BSX1000_TYPEHASH =
        keccak256("TransferToBSX1000(address account,address token,uint256 amount,uint256 nonce)");
    bytes32 private constant WITHDRAW_TYPEHASH =
        keccak256("Withdraw(address sender,address token,uint128 amount,uint64 nonce)");
    bytes32 private constant REGISTER_VAULT_TYPEHASH =
        keccak256("RegisterVault(address vault,address feeRecipient,uint256 profitShareBps)");

    function setUp() public {
        vm.startPrank(sequencer);

        access = new Access();
        stdstore.target(address(access)).sig("hasRole(bytes32,address)").with_key(Roles.ADMIN_ROLE).with_key(sequencer)
            .checked_write(true);
        access.grantRole(Roles.GENERAL_ROLE, sequencer);
        access.grantRole(Roles.BATCH_OPERATOR_ROLE, sequencer);
        access.grantRole(Roles.COLLATERAL_OPERATOR_ROLE, sequencer);
        access.grantRole(Roles.SIGNER_OPERATOR_ROLE, sequencer);

        clearingService = new ClearingService();
        stdstore.target(address(clearingService)).sig("access()").checked_write(address(access));

        spotEngine = new Spot();
        stdstore.target(address(spotEngine)).sig("access()").checked_write(address(access));

        perpEngine = new Perp();
        stdstore.target(address(perpEngine)).sig("access()").checked_write(address(access));

        orderbook = new OrderBook();
        stdstore.target(address(orderbook)).sig("access()").checked_write(address(access));
        stdstore.target(address(orderbook)).sig("getCollateralToken()").checked_write(address(collateralToken));

        exchange = new Exchange();
        bytes memory code = address(new UniversalSigValidator()).code;
        vm.etch(address(UNIVERSAL_SIG_VALIDATOR), code);

        bsx1000 = new BSX1000x();
        stdstore.target(address(bsx1000)).sig("access()").checked_write(address(access));
        stdstore.target(address(bsx1000)).sig("collateralToken()").checked_write(address(collateralToken));

        access.setExchange(address(exchange));
        access.setOrderBook(address(orderbook));
        access.setClearingService(address(clearingService));
        access.setSpotEngine(address(spotEngine));
        access.setPerpEngine(address(perpEngine));
        access.setBsx1000(address(bsx1000));

        stdstore.target(address(exchange)).sig("access()").checked_write(address(access));
        stdstore.target(address(exchange)).sig("book()").checked_write(address(orderbook));
        stdstore.target(address(exchange)).sig("clearingService()").checked_write(address(clearingService));
        stdstore.target(address(exchange)).sig("spotEngine()").checked_write(address(spotEngine));
        stdstore.target(address(exchange)).sig("perpEngine()").checked_write(address(perpEngine));
        exchange.setCanDeposit(true);
        exchange.setCanWithdraw(true);

        exchange.addSupportedToken(address(collateralToken));

        VaultManager vaultManager = new VaultManager();
        stdstore.target(address(vaultManager)).sig("access()").checked_write(address(access));
        access.setVaultManager(address(vaultManager));

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

    function test_deposit_revertsIfRecipientIsVault() public {
        address vault = _registerVault();

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_InvalidAccountType.selector, vault));
        exchange.deposit(vault, address(collateralToken), 100);
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
        address notSupportedToken = address(new ERC20Simple(6));
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

    function test_depositWithAuthorization_revertsIfRecipientIsVault() public {
        address vault = _registerVault();

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_InvalidAccountType.selector, vault));
        exchange.depositWithAuthorization(address(collateralToken), vault, 100, 0, 0, 0, bytes(""));
    }

    function test_depositWithAuthorization_revertsIfDisabledDeposit() public {
        vm.startPrank(sequencer);
        exchange.setCanDeposit(false);

        vm.expectRevert(Errors.Exchange_DisabledDeposit.selector);
        exchange.depositWithAuthorization(address(collateralToken), makeAddr("account"), 100, 0, 0, 0, "");
    }

    function test_depositMaxApproved_succeeds() public {
        address account = makeAddr("account");
        uint128 totalAmount;
        uint8 tokenDecimals = collateralToken.decimals();
        bool earnYield = false;

        vm.startPrank(account);

        for (uint128 i = 1; i < 5; i++) {
            uint128 rawAmount = i * 3000;
            collateralToken.mint(account, rawAmount);
            collateralToken.approve(address(exchange), rawAmount);

            uint128 amount = uint128(rawAmount.convertTo18D(tokenDecimals));
            totalAmount += amount;
            vm.expectEmit(address(exchange));
            emit IExchange.Deposit(address(collateralToken), account, amount, 0);
            exchange.depositMaxApproved(account, address(collateralToken), earnYield);

            assertEq(exchange.balanceOf(account, address(collateralToken)), int128(totalAmount));
            assertEq(spotEngine.getBalance(address(collateralToken), account), int128(totalAmount));
            assertEq(spotEngine.getTotalBalance(address(collateralToken)), totalAmount);
            assertEq(collateralToken.balanceOf(address(exchange)), totalAmount.convertFrom18D(tokenDecimals));
        }
    }

    function test_depositMaxApproved_earnYield_succeeds() public {
        address yieldAsset = _setupYieldAsset();
        // 1 share = 2 tokens
        collateralToken.mint(yieldAsset, 1);

        address user = makeAddr("user");
        uint256 amount = 100e18;
        uint256 mintShares = 50e18;
        bool earnYield = true;

        vm.startPrank(user);
        _prepareDeposit(user, uint128(amount));

        vm.expectEmit(address(exchange));
        emit IExchange.Deposit(address(collateralToken), user, amount, 0);

        vm.expectEmit(address(clearingService));
        emit IClearingService.SwapAssets(
            user,
            0,
            address(collateralToken),
            amount,
            yieldAsset,
            mintShares,
            address(0),
            0,
            IClearingService.SwapType.EarnYieldAsset,
            TxStatus.Success
        );

        exchange.depositMaxApproved(user, address(collateralToken), earnYield);

        assertEq(spotEngine.getBalance(address(collateralToken), user), 0);
        assertEq(spotEngine.getBalance(yieldAsset, user), int256(mintShares));

        assertEq(spotEngine.getTotalBalance(address(collateralToken)), 0);
        assertEq(spotEngine.getTotalBalance(yieldAsset), mintShares);

        assertEq(ERC20Simple(yieldAsset).balanceOf(address(clearingService)), mintShares);
        assertEq(collateralToken.balanceOf(address(exchange)), 0);
    }

    function test_depositAndEarn_succeeds() public {
        address yieldAsset = _setupYieldAsset();
        // 1 share = 2 tokens
        collateralToken.mint(yieldAsset, 1);

        address user = makeAddr("user");
        uint256 amount = 100e18;
        uint256 mintShares = 50e18;

        vm.startPrank(user);
        _prepareDeposit(user, uint128(amount));

        vm.expectEmit(address(exchange));
        emit IExchange.Deposit(address(collateralToken), user, amount, 0);

        vm.expectEmit(address(clearingService));
        emit IClearingService.SwapAssets(
            user,
            0,
            address(collateralToken),
            amount,
            yieldAsset,
            mintShares,
            address(0),
            0,
            IClearingService.SwapType.EarnYieldAsset,
            TxStatus.Success
        );

        exchange.depositAndEarn(address(collateralToken), uint128(amount));

        assertEq(spotEngine.getBalance(address(collateralToken), user), 0);
        assertEq(spotEngine.getBalance(yieldAsset, user), int256(mintShares));

        assertEq(spotEngine.getTotalBalance(address(collateralToken)), 0);
        assertEq(spotEngine.getTotalBalance(yieldAsset), mintShares);

        assertEq(ERC20Simple(yieldAsset).balanceOf(address(clearingService)), mintShares);
        assertEq(collateralToken.balanceOf(address(exchange)), 0);
    }

    function test_depositAndEarn_skipsIfAmountNotEnoughToCoverLoss() public {
        address yieldAsset = _setupYieldAsset();

        address user = makeAddr("user");
        uint256 amount = 100e18;

        // 1 share = 1 tokens
        uint256 loss = 110e18;
        vm.prank(address(clearingService));
        // this function does not change total balance, total_balance is 0
        spotEngine.updateBalance(user, address(collateralToken), -int256(loss));

        vm.startPrank(user);
        _prepareDeposit(user, uint128(amount));

        vm.expectEmit(address(exchange));
        emit IExchange.Deposit(address(collateralToken), user, amount, 0);

        exchange.depositAndEarn(address(collateralToken), uint128(amount));

        assertEq(spotEngine.getBalance(address(collateralToken), user), -10e18);
        assertEq(spotEngine.getBalance(yieldAsset, user), 0);

        assertEq(spotEngine.getTotalBalance(address(collateralToken)), amount);
        assertEq(spotEngine.getTotalBalance(yieldAsset), 0);

        assertEq(ERC20Simple(yieldAsset).balanceOf(address(clearingService)), 0);
        assertEq(
            collateralToken.balanceOf(address(exchange)), uint128(amount).convertFrom18D(collateralToken.decimals())
        );
    }

    function test_depositAndEarn_earnsOnlyNetAmountWhenAccountLoss() public {
        address yieldAsset = _setupYieldAsset();
        // 1 share = 2 tokens
        collateralToken.mint(yieldAsset, 1);

        address user = makeAddr("user");
        uint256 amount = 100e18;

        uint256 loss = 20e18;
        vm.prank(address(clearingService));
        // this function does not change total balance, total_balance is 0
        spotEngine.updateBalance(user, address(collateralToken), -int256(loss));

        uint256 mintShares = 40e18;

        vm.startPrank(user);
        _prepareDeposit(user, uint128(amount));

        vm.expectEmit(address(exchange));
        emit IExchange.Deposit(address(collateralToken), user, amount, 0);

        vm.expectEmit(address(clearingService));
        emit IClearingService.SwapAssets(
            user,
            0,
            address(collateralToken),
            amount - loss,
            yieldAsset,
            mintShares,
            address(0),
            0,
            IClearingService.SwapType.EarnYieldAsset,
            TxStatus.Success
        );

        exchange.depositAndEarn(address(collateralToken), uint128(amount));

        assertEq(spotEngine.getBalance(address(collateralToken), user), 0);
        assertEq(spotEngine.getBalance(yieldAsset, user), int256(mintShares));

        assertEq(spotEngine.getTotalBalance(address(collateralToken)), loss);
        assertEq(spotEngine.getTotalBalance(yieldAsset), mintShares);

        assertEq(ERC20Simple(yieldAsset).balanceOf(address(clearingService)), mintShares);
        assertEq(collateralToken.balanceOf(address(exchange)), uint128(loss).convertFrom18D(collateralToken.decimals()));
    }

    function test_depositAndEarnWithAuthorization_succeeds() public {
        address yieldAsset = _setupYieldAsset();
        // 1 share = 2 tokens
        collateralToken.mint(yieldAsset, 1);

        address user = makeAddr("user");
        uint256 amount = 100e18;
        uint256 mintShares = 50e18;

        collateralToken.mint(address(exchange), uint128(amount).convertFrom18D(collateralToken.decimals()));

        uint8 tokenDecimals = collateralToken.decimals();
        uint256 mockValidTime = block.timestamp;
        bytes32 mockNonce = keccak256(abi.encode(user, mockValidTime));
        bytes memory mockSignature = abi.encode(user, mockValidTime, mockNonce);
        vm.mockCall(
            address(collateralToken),
            abi.encodeWithSelector(
                IERC3009Minimal.receiveWithAuthorization.selector,
                user,
                address(exchange),
                uint128(amount).convertFrom18D(tokenDecimals),
                mockValidTime,
                mockValidTime,
                mockNonce,
                mockSignature
            ),
            abi.encode()
        );

        vm.expectEmit(address(exchange));
        emit IExchange.Deposit(address(collateralToken), user, amount, 0);

        vm.expectEmit(address(clearingService));
        emit IClearingService.SwapAssets(
            user,
            0,
            address(collateralToken),
            amount,
            yieldAsset,
            mintShares,
            address(0),
            0,
            IClearingService.SwapType.EarnYieldAsset,
            TxStatus.Success
        );

        vm.prank(sequencer);
        exchange.depositAndEarnWithAuthorization(
            address(collateralToken), user, uint128(amount), mockValidTime, mockValidTime, mockNonce, mockSignature
        );

        assertEq(spotEngine.getBalance(address(collateralToken), user), 0);
        assertEq(spotEngine.getBalance(yieldAsset, user), int256(mintShares));

        assertEq(spotEngine.getTotalBalance(address(collateralToken)), 0);
        assertEq(spotEngine.getTotalBalance(yieldAsset), mintShares);

        assertEq(ERC20Simple(yieldAsset).balanceOf(address(clearingService)), mintShares);
        assertEq(collateralToken.balanceOf(address(exchange)), 0);
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
                abi.encode(TRANSFER_TO_BSX1000_TYPEHASH, account, address(collateralToken), transferAmount, nonce)
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
            address(collateralToken), account, nonce, transferAmount, balanceAfter, TxStatus.Success
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
                    TRANSFER_TO_BSX1000_TYPEHASH, contractAccount, address(collateralToken), transferAmount, nonce
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
            address(collateralToken), contractAccount, nonce, transferAmount, balanceAfter, TxStatus.Success
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
            keccak256(abi.encode(TRANSFER_TO_BSX1000_TYPEHASH, account, address(collateralToken), amount, nonce))
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

    function test_processBatch_transferToBSX1000_emitsFailedEventIfAccountIsVault() public {
        address vault = _registerVault();
        uint128 amount = 300 * 1e18;
        uint64 nonce = 1;
        bytes memory signature;

        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.TransferToBSX1000,
            abi.encode(IExchange.TransferToBSX1000Params(vault, address(collateralToken), amount, nonce, signature))
        );

        vm.expectEmit(address(exchange));
        emit IExchange.TransferToBSX1000(address(collateralToken), vault, nonce, amount, 0, TxStatus.Failure);

        vm.startPrank(sequencer);
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
            keccak256(abi.encode(TRANSFER_TO_BSX1000_TYPEHASH, account, address(collateralToken), amount, nonce))
        );
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.TransferToBSX1000,
            abi.encode(IExchange.TransferToBSX1000Params(account, address(collateralToken), amount, nonce, signature))
        );
        vm.expectEmit(address(exchange));
        emit IExchange.TransferToBSX1000(address(collateralToken), account, nonce, amount, 0, TxStatus.Failure);
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
            accountKey, keccak256(abi.encode(TRANSFER_TO_BSX1000_TYPEHASH, account, invalidToken, amount, nonce))
        );
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.TransferToBSX1000,
            abi.encode(IExchange.TransferToBSX1000Params(account, invalidToken, amount, nonce, signature))
        );

        vm.expectEmit(address(exchange));
        emit IExchange.TransferToBSX1000(invalidToken, account, nonce, amount, 0, TxStatus.Failure);
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
                abi.encode(TRANSFER_TO_BSX1000_TYPEHASH, account, address(collateralToken), transferAmount, nonce)
            )
        );
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.TransferToBSX1000,
            abi.encode(
                IExchange.TransferToBSX1000Params(account, address(collateralToken), transferAmount, nonce, signature)
            )
        );

        vm.expectEmit(address(exchange));
        emit IExchange.TransferToBSX1000(address(collateralToken), account, nonce, transferAmount, 0, TxStatus.Failure);
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

    function test_processBatch_transferToBSX1000_emitsFailedEventIfZeroAmount() public {
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
                abi.encode(TRANSFER_TO_BSX1000_TYPEHASH, account, address(collateralToken), transferAmount, nonce)
            )
        );
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.TransferToBSX1000,
            abi.encode(
                IExchange.TransferToBSX1000Params(account, address(collateralToken), transferAmount, nonce, signature)
            )
        );

        vm.expectEmit(address(exchange));
        emit IExchange.TransferToBSX1000(address(collateralToken), account, nonce, transferAmount, 0, TxStatus.Failure);
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

    function test_processBatch_withdraw_EOA() public {
        collateralToken.mint(address(exchange), type(uint128).max);

        uint128 amount = 5 * 1e18;
        (address account, uint256 accountKey) = makeAddrAndKey("account");

        vm.prank(address(exchange));
        clearingService.deposit(account, amount, address(collateralToken));

        int256 accountBalanceStateBefore = spotEngine.getBalance(address(collateralToken), account);
        uint256 totalBalanceStateBefore = spotEngine.getTotalBalance(address(collateralToken));

        uint256 exchangeBalanceBefore = collateralToken.balanceOf(address(exchange));
        uint256 accountBalanceBefore = collateralToken.balanceOf(account);

        uint64 nonce = 1;
        bytes memory signature = _signTypedDataHash(
            accountKey, keccak256(abi.encode(WITHDRAW_TYPEHASH, account, address(collateralToken), amount, nonce))
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

        vm.prank(address(exchange));
        clearingService.deposit(contractAccount, amount, address(collateralToken));

        int256 accountBalanceStateBefore = spotEngine.getBalance(address(collateralToken), contractAccount);
        uint256 totalBalanceStateBefore = spotEngine.getTotalBalance(address(collateralToken));

        uint256 exchangeBalanceBefore = collateralToken.balanceOf(address(exchange));
        uint256 accountBalanceBefore = collateralToken.balanceOf(contractAccount);

        uint64 nonce = 1;
        bytes memory signature = _signTypedDataHash(
            ownerKey, keccak256(abi.encode(WITHDRAW_TYPEHASH, contractAccount, address(collateralToken), amount, nonce))
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

        vm.prank(address(exchange));
        clearingService.deposit(account, amount, address(newToken));

        int256 accountBalanceStateBefore = spotEngine.getBalance(address(newToken), account);
        uint256 totalBalanceStateBefore = spotEngine.getTotalBalance(address(newToken));

        uint256 exchangeBalanceBefore = newToken.balanceOf(address(exchange));
        uint256 accountBalanceBefore = newToken.balanceOf(account);

        uint64 nonce = 1;
        bytes memory signature = _signTypedDataHash(
            accountKey, keccak256(abi.encode(WITHDRAW_TYPEHASH, account, address(newToken), amount, nonce))
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
        bytes memory signature =
            _signTypedDataHash(accountKey, keccak256(abi.encode(WITHDRAW_TYPEHASH, account, NATIVE_ETH, amount, nonce)));
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

    function test_processBatch_withdraw_nativeETH_emitsFailedEventIfSmartContract() public {
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
            ownerKey, keccak256(abi.encode(WITHDRAW_TYPEHASH, contractAccount, NATIVE_ETH, amount, nonce))
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

    function test_processBatch_withdraw_emitsFailedEventIfRecipientIsVault() public {
        address vault = _registerVault();
        uint128 amount = 300 * 1e18;
        uint64 nonce = 1;
        uint128 withdrawFee = 1 * 1e16;
        bytes memory signature;

        // deposit to vault
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.Withdraw,
            abi.encode(IExchange.Withdraw(vault, address(collateralToken), amount, nonce, signature, withdrawFee))
        );

        vm.expectEmit(address(exchange));
        emit IExchange.WithdrawFailed(vault, nonce, 0, 0);

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_withdraw_smartContract_emitsFailedEventIfInvalidSignature() public {
        collateralToken.mint(address(exchange), type(uint128).max);

        (address owner, uint256 ownerKey) = makeAddrAndKey("owner");
        address contractAccount = address(new ERC1271(owner));
        uint128 amount = 5 * 1e18;

        vm.prank(address(exchange));
        clearingService.deposit(contractAccount, amount, address(collateralToken));

        int256 accountBalanceStateBefore = spotEngine.getBalance(address(collateralToken), contractAccount);
        uint256 totalBalanceStateBefore = spotEngine.getTotalBalance(address(collateralToken));

        uint256 exchangeBalanceBefore = collateralToken.balanceOf(address(exchange));
        uint256 accountBalanceBefore = collateralToken.balanceOf(contractAccount);

        uint64 nonce = 1;
        bytes memory signature = _signTypedDataHash(
            ownerKey, keccak256(abi.encode(WITHDRAW_TYPEHASH, contractAccount, address(collateralToken), amount, nonce))
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

    function test_processBatch_withdraw_emitsFailedEventIfExceededMaxFee() public {
        vm.startPrank(sequencer);

        (address account, uint256 accountKey) = makeAddrAndKey("account");

        uint64 nonce = 1;
        uint128 amount = 5 * 1e18;
        bytes memory signature = _signTypedDataHash(
            accountKey, keccak256(abi.encode(WITHDRAW_TYPEHASH, account, address(collateralToken), amount, nonce))
        );

        // fee on stable tokens
        nonce++;
        uint128 invalidFee = 1 ether + 1;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.Withdraw,
            abi.encode(IExchange.Withdraw(account, address(collateralToken), amount, nonce, signature, invalidFee))
        );

        vm.expectEmit(address(exchange));
        emit IExchange.WithdrawFailed(account, nonce, 0, 0);

        exchange.processBatch(operation.toArray());

        // fee on weth
        nonce++;
        signature =
            _signTypedDataHash(accountKey, keccak256(abi.encode(WITHDRAW_TYPEHASH, account, WETH9, amount, nonce)));
        invalidFee = 0.001 ether + 1;
        operation = _encodeDataToOperation(
            IExchange.OperationType.Withdraw,
            abi.encode(IExchange.Withdraw(account, WETH9, amount, nonce, signature, invalidFee))
        );

        vm.expectEmit(address(exchange));
        emit IExchange.WithdrawFailed(account, nonce, 0, 0);

        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_withdraw_revertsIfNonceUsed() public {
        collateralToken.mint(address(exchange), type(uint128).max);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        uint128 amount = 5 * 1e18;

        vm.prank(address(exchange));
        clearingService.deposit(account, amount, address(collateralToken));

        vm.startPrank(sequencer);

        uint64 nonce = 1;
        bytes memory signature = _signTypedDataHash(
            accountKey, keccak256(abi.encode(WITHDRAW_TYPEHASH, account, address(collateralToken), amount, nonce))
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

    function test_processBatch_withdraw_emitsFailedEventIfWithdrawAmountExceedBalance() public {
        collateralToken.mint(address(exchange), type(uint128).max);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        uint128 balance = 5 * 1e18;

        vm.prank(address(exchange));
        clearingService.deposit(account, balance, address(collateralToken));

        int256 accountBalanceStateBefore = spotEngine.getBalance(address(collateralToken), account);
        uint256 totalBalanceStateBefore = spotEngine.getTotalBalance(address(collateralToken));

        uint256 exchangeBalanceBefore = collateralToken.balanceOf(address(exchange));
        uint256 accountBalanceBefore = collateralToken.balanceOf(account);

        vm.startPrank(sequencer);

        uint64 nonce = 1;
        uint128 withdrawAmount = balance + 1;
        bytes memory signature = _signTypedDataHash(
            accountKey,
            keccak256(abi.encode(WITHDRAW_TYPEHASH, account, address(collateralToken), withdrawAmount, nonce))
        );
        bytes memory data =
            abi.encode(IExchange.Withdraw(account, address(collateralToken), withdrawAmount, nonce, signature, 0));
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.Withdraw, data);
        vm.expectEmit(address(exchange));
        emit IExchange.WithdrawFailed(account, nonce, 0, 0);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isWithdrawNonceUsed(account, nonce), true);
        assertEq(spotEngine.getBalance(address(collateralToken), account), accountBalanceStateBefore);
        assertEq(spotEngine.getTotalBalance(address(collateralToken)), totalBalanceStateBefore);

        assertEq(collateralToken.balanceOf(account), accountBalanceBefore);
        assertEq(collateralToken.balanceOf(address(exchange)), exchangeBalanceBefore);
    }

    function test_processBatch_transfer_mainToMain_succeeds() public {
        // main -> main
        (address main1, uint256 main1Key) = makeAddrAndKey("main1");
        (address main2,) = makeAddrAndKey("main2");

        uint256 amount = 300e18;
        _deposit(main1, address(collateralToken), amount);

        uint64 nonce = 1;
        uint256 transferAmount1 = 100e18;
        bytes memory signature = _signTypedDataHash(
            main1Key,
            keccak256(abi.encode(TRANSFER_TYPEHASH, main1, main2, address(collateralToken), transferAmount1, nonce))
        );
        bytes memory data = abi.encode(
            IExchange.TransferParams(main1, main2, address(collateralToken), transferAmount1, nonce, signature)
        );
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.Transfer, data);

        vm.expectEmit(address(exchange));
        emit IExchange.Transfer(
            address(collateralToken), main1, main2, main1, nonce, int256(transferAmount1), TxStatus.Success
        );

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isNonceUsed(main1, nonce), true);

        assertEq(spotEngine.getBalance(address(collateralToken), main1), int256(amount - transferAmount1));
        assertEq(spotEngine.getBalance(address(collateralToken), main2), int256(transferAmount1));
        assertEq(spotEngine.getTotalBalance(address(collateralToken)), amount);

        assertEq(collateralToken.balanceOf(main1), 0);
        assertEq(collateralToken.balanceOf(main2), 0);
        assertEq(collateralToken.balanceOf(address(exchange)), amount.convertFromScale(address(collateralToken)));

        // main (has sub) -> main
        (address sub1, uint256 sub1Key) = makeAddrAndKey("sub1");
        _createSubaccount(main1, main1Key, sub1, sub1Key);
        nonce = 2;
        uint256 transferAmount2 = 50e18;
        signature = _signTypedDataHash(
            main1Key,
            keccak256(abi.encode(TRANSFER_TYPEHASH, main1, main2, address(collateralToken), transferAmount2, nonce))
        );
        data = abi.encode(
            IExchange.TransferParams(main1, main2, address(collateralToken), transferAmount2, nonce, signature)
        );
        operation = _encodeDataToOperation(IExchange.OperationType.Transfer, data);

        vm.expectEmit(address(exchange));
        emit IExchange.Transfer(
            address(collateralToken), main1, main2, main1, nonce, int256(transferAmount2), TxStatus.Success
        );

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isNonceUsed(main1, nonce), true);

        assertEq(
            spotEngine.getBalance(address(collateralToken), main1), int256(amount - transferAmount1 - transferAmount2)
        );
        assertEq(spotEngine.getBalance(address(collateralToken), main2), int256(transferAmount1 + transferAmount2));
        assertEq(spotEngine.getTotalBalance(address(collateralToken)), amount);

        assertEq(collateralToken.balanceOf(main1), 0);
        assertEq(collateralToken.balanceOf(main2), 0);
        assertEq(collateralToken.balanceOf(address(exchange)), amount.convertFromScale(address(collateralToken)));
    }

    function test_processBatch_transfer_mainToSub_succeeds() public {
        (address main, uint256 mainKey) = makeAddrAndKey("main");
        (address sub, uint256 subKey) = makeAddrAndKey("sub");
        _createSubaccount(main, mainKey, sub, subKey);

        uint256 amount = 300e18;
        _deposit(main, address(collateralToken), amount);

        uint64 nonce = 1;
        uint256 transferAmount = 100e18;
        bytes memory signature = _signTypedDataHash(
            mainKey,
            keccak256(abi.encode(TRANSFER_TYPEHASH, main, sub, address(collateralToken), transferAmount, nonce))
        );
        bytes memory data =
            abi.encode(IExchange.TransferParams(main, sub, address(collateralToken), transferAmount, nonce, signature));
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.Transfer, data);

        vm.expectEmit(address(exchange));
        emit IExchange.Transfer(
            address(collateralToken), main, sub, main, nonce, int256(transferAmount), TxStatus.Success
        );

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isNonceUsed(main, nonce), true);

        assertEq(spotEngine.getBalance(address(collateralToken), main), int256(amount - transferAmount));
        assertEq(spotEngine.getBalance(address(collateralToken), sub), int256(transferAmount));
        assertEq(spotEngine.getTotalBalance(address(collateralToken)), amount);

        assertEq(collateralToken.balanceOf(main), 0);
        assertEq(collateralToken.balanceOf(sub), 0);
        assertEq(collateralToken.balanceOf(address(exchange)), amount.convertFromScale(address(collateralToken)));
    }

    function test_processBatch_transfer_subToMain_succeeds() public {
        (address main, uint256 mainKey) = makeAddrAndKey("main");
        (address sub, uint256 subKey) = makeAddrAndKey("sub");
        _createSubaccount(main, mainKey, sub, subKey);

        uint256 amount = 300e18;
        _deposit(sub, address(collateralToken), amount);

        uint64 nonce = 1;
        uint256 transferAmount = 100e18;
        bytes memory signature = _signTypedDataHash(
            mainKey,
            keccak256(abi.encode(TRANSFER_TYPEHASH, sub, main, address(collateralToken), transferAmount, nonce))
        );
        bytes memory data =
            abi.encode(IExchange.TransferParams(sub, main, address(collateralToken), transferAmount, nonce, signature));
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.Transfer, data);

        vm.expectEmit(address(exchange));
        emit IExchange.Transfer(
            address(collateralToken), sub, main, main, nonce, int256(transferAmount), TxStatus.Success
        );

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isNonceUsed(main, nonce), true);

        assertEq(spotEngine.getBalance(address(collateralToken), main), int256(transferAmount));
        assertEq(spotEngine.getBalance(address(collateralToken), sub), int256(amount - transferAmount));
        assertEq(spotEngine.getTotalBalance(address(collateralToken)), amount);

        assertEq(collateralToken.balanceOf(main), 0);
        assertEq(collateralToken.balanceOf(sub), 0);
        assertEq(collateralToken.balanceOf(address(exchange)), amount.convertFromScale(address(collateralToken)));
    }

    function test_processBatch_transfer_subToSub_succeeds() public {
        (address main, uint256 mainKey) = makeAddrAndKey("main");
        (address sub1, uint256 sub1Key) = makeAddrAndKey("sub1");
        (address sub2, uint256 sub2Key) = makeAddrAndKey("sub2");

        _createSubaccount(main, mainKey, sub1, sub1Key);
        _createSubaccount(main, mainKey, sub2, sub2Key);

        uint256 amount = 300e18;
        _deposit(sub1, address(collateralToken), amount);

        uint64 nonce = 1;
        uint256 transferAmount = 100e18;
        bytes memory signature = _signTypedDataHash(
            mainKey,
            keccak256(abi.encode(TRANSFER_TYPEHASH, sub1, sub2, address(collateralToken), transferAmount, nonce))
        );
        bytes memory data =
            abi.encode(IExchange.TransferParams(sub1, sub2, address(collateralToken), transferAmount, nonce, signature));
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.Transfer, data);

        vm.expectEmit(address(exchange));
        emit IExchange.Transfer(
            address(collateralToken), sub1, sub2, main, nonce, int256(transferAmount), TxStatus.Success
        );

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isNonceUsed(main, nonce), true);

        assertEq(spotEngine.getBalance(address(collateralToken), sub1), int256(amount - transferAmount));
        assertEq(spotEngine.getBalance(address(collateralToken), sub2), int256(transferAmount));
        assertEq(spotEngine.getTotalBalance(address(collateralToken)), amount);

        assertEq(collateralToken.balanceOf(sub1), 0);
        assertEq(collateralToken.balanceOf(sub2), 0);
        assertEq(collateralToken.balanceOf(address(exchange)), amount.convertFromScale(address(collateralToken)));
    }

    function test_processBatch_transfer_revertsIfNonceUsed() public {
        (address main1, uint256 main1Key) = makeAddrAndKey("main1");
        address main2 = makeAddr("main2");

        uint256 amount = 300e18;
        _deposit(main1, address(collateralToken), amount);

        uint64 nonce = 1;
        uint256 transferAmount1 = 100e18;
        bytes memory signature = _signTypedDataHash(
            main1Key,
            keccak256(abi.encode(TRANSFER_TYPEHASH, main1, main2, address(collateralToken), transferAmount1, nonce))
        );
        bytes memory data = abi.encode(
            IExchange.TransferParams(main1, main2, address(collateralToken), transferAmount1, nonce, signature)
        );
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.Transfer, data);

        vm.expectEmit(address(exchange));
        emit IExchange.Transfer(
            address(collateralToken), main1, main2, main1, nonce, int256(transferAmount1), TxStatus.Success
        );

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        operation = _encodeDataToOperation(IExchange.OperationType.Transfer, data);
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_NonceUsed.selector, main1, nonce));
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_transfer_emitsFailedIfTransferNotAllowed() public {
        (address main1, uint256 main1Key) = makeAddrAndKey("main1");
        (address sub1, uint256 sub1Key) = makeAddrAndKey("sub1");
        _createSubaccount(main1, main1Key, sub1, sub1Key);

        (address main2, uint256 main2Key) = makeAddrAndKey("main2");
        (address sub2, uint256 sub2Key) = makeAddrAndKey("sub2");
        _createSubaccount(main2, main2Key, sub2, sub2Key);

        // deposit to all accounts
        _deposit(main1, address(collateralToken), 300e18);
        _deposit(sub1, address(collateralToken), 300e18);
        _deposit(main2, address(collateralToken), 300e18);
        _deposit(sub2, address(collateralToken), 300e18);

        uint64 nonce;
        uint256 transferAmount = 100e18;
        bytes memory signature;
        bytes memory data;
        bytes memory operation;

        // main1 -> sub2
        nonce++;
        signature = _signTypedDataHash(
            main1Key,
            keccak256(abi.encode(TRANSFER_TYPEHASH, main1, sub2, address(collateralToken), transferAmount, nonce))
        );
        data = abi.encode(
            IExchange.TransferParams(main1, sub2, address(collateralToken), transferAmount, nonce, signature)
        );
        operation = _encodeDataToOperation(IExchange.OperationType.Transfer, data);

        vm.expectEmit(address(exchange));
        emit IExchange.Transfer(
            address(collateralToken), main1, sub2, address(0), nonce, int256(transferAmount), TxStatus.Failure
        );

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        // sub1 -> main2
        nonce++;
        signature = _signTypedDataHash(
            main1Key,
            keccak256(abi.encode(TRANSFER_TYPEHASH, sub1, main2, address(collateralToken), transferAmount, nonce))
        );
        data = abi.encode(
            IExchange.TransferParams(sub1, main2, address(collateralToken), transferAmount, nonce, signature)
        );
        operation = _encodeDataToOperation(IExchange.OperationType.Transfer, data);

        vm.expectEmit(address(exchange));
        emit IExchange.Transfer(
            address(collateralToken), sub1, main2, address(0), nonce, int256(transferAmount), TxStatus.Failure
        );

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        // sub1 -> sub2
        nonce++;
        signature = _signTypedDataHash(
            main1Key,
            keccak256(abi.encode(TRANSFER_TYPEHASH, sub1, sub2, address(collateralToken), transferAmount, nonce))
        );
        data =
            abi.encode(IExchange.TransferParams(sub1, sub2, address(collateralToken), transferAmount, nonce, signature));
        operation = _encodeDataToOperation(IExchange.OperationType.Transfer, data);

        vm.expectEmit(address(exchange));
        emit IExchange.Transfer(
            address(collateralToken), sub1, sub2, address(0), nonce, int256(transferAmount), TxStatus.Failure
        );

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_transfer_emitsFailedIfSelfTransfer() public {
        (address main, uint256 mainKey) = makeAddrAndKey("main");

        uint256 amount = 300e18;
        _deposit(main, address(collateralToken), amount);

        uint64 nonce = 1;
        uint256 transferAmount = 100e18;
        bytes memory signature = _signTypedDataHash(
            mainKey,
            keccak256(abi.encode(TRANSFER_TYPEHASH, main, main, address(collateralToken), transferAmount, nonce))
        );
        bytes memory data =
            abi.encode(IExchange.TransferParams(main, main, address(collateralToken), transferAmount, nonce, signature));
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.Transfer, data);

        vm.expectEmit(address(exchange));
        emit IExchange.Transfer(
            address(collateralToken), main, main, address(0), nonce, int256(transferAmount), TxStatus.Failure
        );

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_transfer_emitsFailedIfTransferToVault() public {
        (address main, uint256 mainKey) = makeAddrAndKey("main");
        address vault = _registerVault();

        // deposit to main and vault
        _deposit(main, address(collateralToken), 300e18);
        _deposit(vault, address(collateralToken), 300e18);

        uint256 transferAmount = 100e18;
        bytes memory signature;

        // main -> vault
        uint64 nonce = 1;
        signature = _signTypedDataHash(
            mainKey,
            keccak256(abi.encode(TRANSFER_TYPEHASH, main, vault, address(collateralToken), transferAmount, nonce))
        );
        bytes memory data = abi.encode(
            IExchange.TransferParams(main, vault, address(collateralToken), transferAmount, nonce, signature)
        );
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.Transfer, data);

        vm.expectEmit(address(exchange));
        emit IExchange.Transfer(
            address(collateralToken), main, vault, address(0), nonce, int256(transferAmount), TxStatus.Failure
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        // vault -> main
        nonce = 2;
        signature = _signTypedDataHash(
            mainKey,
            keccak256(abi.encode(TRANSFER_TYPEHASH, vault, main, address(collateralToken), transferAmount, nonce))
        );
        data = abi.encode(
            IExchange.TransferParams(vault, main, address(collateralToken), transferAmount, nonce, signature)
        );
        operation = _encodeDataToOperation(IExchange.OperationType.Transfer, data);

        vm.expectEmit(address(exchange));
        emit IExchange.Transfer(
            address(collateralToken), vault, main, address(0), nonce, int256(transferAmount), TxStatus.Failure
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_transfer_emitsFailedIfTransferToDeletedAccount() public {
        (address main, uint256 mainKey) = makeAddrAndKey("main");
        (address sub, uint256 subKey) = makeAddrAndKey("sub");
        _createSubaccount(main, mainKey, sub, subKey);

        // delete subaccount
        bytes32 structHash = keccak256(abi.encode(DELETE_SUBACCOUNT_TYPEHASH, main, sub));
        bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
        bytes memory deleteSubacountData = abi.encode(IExchange.DeleteSubaccountParams(main, sub, mainSignature));
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.DeleteSubaccount, deleteSubacountData);
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        // deposit to main and sub
        _deposit(main, address(collateralToken), 300e18);
        _deposit(sub, address(collateralToken), 300e18);

        uint256 transferAmount = 100e18;
        bytes memory signature;
        bytes memory data;

        // main -> deleted subaccount
        uint64 nonce = 1;
        signature = _signTypedDataHash(
            mainKey,
            keccak256(abi.encode(TRANSFER_TYPEHASH, main, sub, address(collateralToken), transferAmount, nonce))
        );
        data =
            abi.encode(IExchange.TransferParams(main, sub, address(collateralToken), transferAmount, nonce, signature));
        operation = _encodeDataToOperation(IExchange.OperationType.Transfer, data);
        vm.expectEmit(address(exchange));
        emit IExchange.Transfer(
            address(collateralToken), main, sub, address(0), nonce, int256(transferAmount), TxStatus.Failure
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        // deleted subaccount -> main
        nonce = 2;
        signature = _signTypedDataHash(
            mainKey,
            keccak256(abi.encode(TRANSFER_TYPEHASH, sub, main, address(collateralToken), transferAmount, nonce))
        );
        data =
            abi.encode(IExchange.TransferParams(sub, main, address(collateralToken), transferAmount, nonce, signature));
        operation = _encodeDataToOperation(IExchange.OperationType.Transfer, data);
        vm.expectEmit(address(exchange));
        emit IExchange.Transfer(
            address(collateralToken), sub, main, address(0), nonce, int256(transferAmount), TxStatus.Failure
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_transfer_emitsFailedIfInsufficientBalance() public {
        (address main, uint256 mainKey) = makeAddrAndKey("main");
        (address sub, uint256 subKey) = makeAddrAndKey("sub");
        _createSubaccount(main, mainKey, sub, subKey);

        // deposit to main and sub
        _deposit(main, address(collateralToken), 10e18);
        _deposit(main, address(collateralToken), 10e18);

        uint256 transferAmount = 100e18;
        uint256 nonce;
        bytes memory data;
        bytes memory operation;

        // main -> sub
        nonce++;
        bytes memory signature = _signTypedDataHash(
            mainKey,
            keccak256(abi.encode(TRANSFER_TYPEHASH, main, sub, address(collateralToken), transferAmount, nonce))
        );
        data =
            abi.encode(IExchange.TransferParams(main, sub, address(collateralToken), transferAmount, nonce, signature));
        operation = _encodeDataToOperation(IExchange.OperationType.Transfer, data);

        vm.expectEmit(address(exchange));
        emit IExchange.Transfer(
            address(collateralToken), main, sub, address(0), nonce, int256(transferAmount), TxStatus.Failure
        );

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        // sub -> main
        nonce++;
        signature = _signTypedDataHash(
            subKey, keccak256(abi.encode(TRANSFER_TYPEHASH, sub, main, address(collateralToken), transferAmount, nonce))
        );
        data =
            abi.encode(IExchange.TransferParams(sub, main, address(collateralToken), transferAmount, nonce, signature));
        operation = _encodeDataToOperation(IExchange.OperationType.Transfer, data);

        vm.expectEmit(address(exchange));
        emit IExchange.Transfer(
            address(collateralToken), sub, main, address(0), nonce, int256(transferAmount), TxStatus.Failure
        );

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_transfer_emitsFailedIfInvalidSignature() public {
        (address main, uint256 mainKey) = makeAddrAndKey("main");
        (address sub, uint256 subKey) = makeAddrAndKey("sub");
        _createSubaccount(main, mainKey, sub, subKey);

        // deposit to main and sub
        _deposit(main, address(collateralToken), 300e18);
        _deposit(sub, address(collateralToken), 300e18);

        uint256 transferAmount = 100e18;
        uint256 nonce;
        bytes memory data;
        bytes memory operation;

        // main -> sub
        nonce++;
        bytes memory invalidSignature = _signTypedDataHash(
            uint256(123),
            keccak256(abi.encode(TRANSFER_TYPEHASH, main, sub, address(collateralToken), transferAmount, nonce))
        );
        data = abi.encode(
            IExchange.TransferParams(main, sub, address(collateralToken), transferAmount, nonce, invalidSignature)
        );
        operation = _encodeDataToOperation(IExchange.OperationType.Transfer, data);

        vm.expectEmit(address(exchange));
        emit IExchange.Transfer(
            address(collateralToken), main, sub, address(0), nonce, int256(transferAmount), TxStatus.Failure
        );

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        // sub -> main
        nonce++;
        invalidSignature = _signTypedDataHash(
            uint256(456),
            keccak256(abi.encode(TRANSFER_TYPEHASH, sub, main, address(collateralToken), transferAmount, nonce))
        );
        data = abi.encode(
            IExchange.TransferParams(sub, main, address(collateralToken), transferAmount, nonce, invalidSignature)
        );
        operation = _encodeDataToOperation(IExchange.OperationType.Transfer, data);

        vm.expectEmit(address(exchange));
        emit IExchange.Transfer(
            address(collateralToken), sub, main, address(0), nonce, int256(transferAmount), TxStatus.Failure
        );

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
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
        bytes32 role = Roles.GENERAL_ROLE;

        vm.startPrank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        exchange.setCanDeposit(true);
    }

    function _createSubaccount(address main, uint256 mainKey, address subaccount, uint256 subKey) private {
        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
        bytes memory subSignature = _signTypedDataHash(subKey, structHash);

        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);
    }

    function _deposit(address account, address token, uint256 amount) private {
        vm.prank(address(exchange));
        clearingService.deposit(account, amount, token);
        ERC20Simple(token).mint(address(exchange), amount.convertFromScale(token));
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

    function _setupYieldAsset() private returns (address yieldAsset) {
        yieldAsset = address(new MockERC4626(collateralToken));

        vm.prank(sequencer);
        clearingService.addYieldAsset(address(collateralToken), yieldAsset);
    }

    function _encodeDataToOperation(IExchange.OperationType operationType, bytes memory data)
        private
        view
        returns (bytes memory)
    {
        uint32 transactionId = exchange.executedTransactionCounter();
        return abi.encodePacked(operationType, transactionId, data);
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

    function _maxZeroScaledAmount() private view returns (uint128) {
        return uint128(uint128(1).convertTo18D(collateralToken.decimals()) - 1);
    }
}

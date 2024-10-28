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

import {ClearingService} from "contracts/exchange/ClearingService.sol";
import {Exchange, IExchange} from "contracts/exchange/Exchange.sol";
import {IOrderBook, OrderBook} from "contracts/exchange/OrderBook.sol";
import {IPerp, Perp} from "contracts/exchange/Perp.sol";
import {ISpot, Spot} from "contracts/exchange/Spot.sol";
import {Access} from "contracts/exchange/access/Access.sol";
import {IERC3009Minimal} from "contracts/exchange/interfaces/external/IERC3009Minimal.sol";
import {Errors} from "contracts/exchange/lib/Errors.sol";
import {LibOrder} from "contracts/exchange/lib/LibOrder.sol";
import {MathHelper} from "contracts/exchange/lib/MathHelper.sol";
import {Percentage} from "contracts/exchange/lib/Percentage.sol";
import {MAX_REBATE_RATE, NATIVE_ETH, WETH9} from "contracts/exchange/share/Constants.sol";
import {OrderSide} from "contracts/exchange/share/Enums.sol";

// solhint-disable max-states-count
contract ExchangeTest is Test {
    using stdStorage for StdStorage;
    using Helper for bytes;
    using Helper for uint128;
    using MathHelper for int128;
    using MathHelper for uint128;
    using Percentage for uint128;

    address private sequencer = makeAddr("sequencer");
    address private feeRecipient = makeAddr("feeRecipient");

    address private maker;
    uint256 private makerKey;
    address private makerSigner;
    uint256 private makerSignerKey;
    address private taker;
    uint256 private takerKey;
    address private takerSigner;
    uint256 private takerSignerKey;

    ERC20Simple private collateralToken = new ERC20Simple(6);

    Access private access;
    Exchange private exchange;
    ClearingService private clearingService;
    OrderBook private orderbook;
    Perp private perpEngine;
    Spot private spotEngine;

    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    struct WrappedOrder {
        uint8 productId;
        uint128 size;
        uint128 price;
        bool isLiquidated;
        IOrderBook.Fee fee;
        uint64 makerNonce;
        OrderSide makerSide;
        uint64 takerNonce;
        OrderSide takerSide;
        uint128 sequencerFee;
    }

    struct ReferralRebate {
        address makerReferrer;
        address takerReferrer;
        uint16 makerReferrerRebateRate;
        uint16 takerReferrerRebateRate;
    }

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

        perpEngine = new Perp();
        stdstore.target(address(perpEngine)).sig("access()").checked_write(address(access));

        spotEngine = new Spot();
        stdstore.target(address(spotEngine)).sig("access()").checked_write(address(access));

        orderbook = new OrderBook();
        stdstore.target(address(orderbook)).sig("clearingService()").checked_write(address(clearingService));
        stdstore.target(address(orderbook)).sig("spotEngine()").checked_write(address(spotEngine));
        stdstore.target(address(orderbook)).sig("perpEngine()").checked_write(address(perpEngine));
        stdstore.target(address(orderbook)).sig("access()").checked_write(address(access));
        stdstore.target(address(orderbook)).sig("getCollateralToken()").checked_write(address(collateralToken));

        exchange = new Exchange();
        bytes memory code = address(new UniversalSigValidator()).code;
        vm.etch(address(exchange.UNIVERSAL_SIG_VALIDATOR()), code);

        access.setExchange(address(exchange));
        access.setClearingService(address(clearingService));
        access.setOrderBook(address(orderbook));
        access.setSpotEngine(address(spotEngine));

        stdstore.target(address(exchange)).sig("access()").checked_write(address(access));
        stdstore.target(address(exchange)).sig("book()").checked_write(address(orderbook));
        stdstore.target(address(exchange)).sig("clearingService()").checked_write(address(clearingService));
        stdstore.target(address(exchange)).sig("spotEngine()").checked_write(address(spotEngine));
        stdstore.target(address(exchange)).sig("perpEngine()").checked_write(address(perpEngine));
        exchange.updateFeeRecipientAddress(feeRecipient);
        exchange.setCanDeposit(true);
        exchange.setCanWithdraw(true);

        exchange.addSupportedToken(address(collateralToken));

        _accountSetup();

        vm.stopPrank();
    }

    function test_addSupportedToken() public {
        vm.startPrank(sequencer);

        uint256 len = 5;
        for (uint8 i = 0; i < len; i++) {
            address supportedToken = makeAddr(string(abi.encodePacked("supportedToken", i)));
            exchange.addSupportedToken(supportedToken);
            assertEq(exchange.isSupportedToken(supportedToken), true);
        }

        address[] memory supportedTokenList = exchange.getSupportedTokenList();
        uint256 startId = supportedTokenList.length - len;
        for (uint8 i = 0; i < len; i++) {
            address supportedToken = makeAddr(string(abi.encodePacked("supportedToken", i)));
            assertEq(supportedTokenList[startId + i], supportedToken);
        }
    }

    function test_addSupportedToken_revertsIfAlreadyAdded() public {
        vm.startPrank(sequencer);

        address supportedToken = makeAddr("supportedToken");
        exchange.addSupportedToken(supportedToken);
        assertEq(exchange.isSupportedToken(supportedToken), true);

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_TokenAlreadySupported.selector, supportedToken));
        exchange.addSupportedToken(supportedToken);
    }

    function test_addSupportedToken_revertsWhenUnauthorized() public {
        address malicious = makeAddr("malicious");
        bytes32 role = access.GENERAL_ROLE();

        vm.startPrank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        exchange.addSupportedToken(makeAddr("token"));
    }

    function test_removeSupportedToken() public {
        vm.startPrank(sequencer);

        address supportedToken = makeAddr("supportedToken");
        exchange.addSupportedToken(supportedToken);
        assertEq(exchange.isSupportedToken(supportedToken), true);

        exchange.removeSupportedToken(supportedToken);
        assertEq(exchange.isSupportedToken(supportedToken), false);
    }

    function test_removeSupportedToken_revertsIfNotAdded() public {
        vm.startPrank(sequencer);

        address notSupportedToken = makeAddr("notSupportedToken");
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_TokenNotSupported.selector, notSupportedToken));
        exchange.removeSupportedToken(notSupportedToken);
    }

    function test_removeSupportedToken_revertsWhenUnauthorized() public {
        address supportedToken = makeAddr("supportedToken");
        vm.prank(sequencer);
        exchange.addSupportedToken(supportedToken);
        assertEq(exchange.isSupportedToken(supportedToken), true);

        address malicious = makeAddr("malicious");
        bytes32 role = access.GENERAL_ROLE();

        vm.startPrank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        exchange.removeSupportedToken(supportedToken);
    }

    function test_updateFeeRecipient() public {
        vm.startPrank(sequencer);

        address newFeeRecipient = makeAddr("newFeeRecipient");
        exchange.updateFeeRecipientAddress(newFeeRecipient);
        assertEq(exchange.feeRecipientAddress(), newFeeRecipient);
    }

    function test_updateFeeRecipient_revertsWhenUnauthorized() public {
        address malicious = makeAddr("malicious");
        bytes32 role = access.GENERAL_ROLE();

        vm.startPrank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        exchange.updateFeeRecipientAddress(makeAddr("newFeeRecipient"));
    }

    function test_updateFeeRecipient_revertsIfZeroAddr() public {
        vm.startPrank(sequencer);

        vm.expectRevert(Errors.ZeroAddress.selector);
        exchange.updateFeeRecipientAddress(address(0));
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

    function test_processBatch_addSigningWallet_EOA() public {
        vm.startPrank(sequencer);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");

        string memory message = "message";
        uint64 nonce = 1;

        bytes32 accountStructHash =
            keccak256(abi.encode(exchange.REGISTER_TYPEHASH(), signer, keccak256(abi.encodePacked(message)), nonce));
        bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

        bytes32 signerStructHash = keccak256(abi.encode(exchange.SIGN_KEY_TYPEHASH(), account));
        bytes memory signerSignature = _signTypedDataHash(signerKey, signerStructHash);

        bytes memory addSigningWalletData =
            abi.encode(IExchange.AddSigningWallet(account, signer, message, nonce, accountSignature, signerSignature));
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.AddSigningWallet, addSigningWalletData);

        vm.expectEmit(address(exchange));
        emit IExchange.RegisterSigner(account, signer, nonce);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isSigningWallet(account, signer), true);
        assertEq(exchange.isRegisterSignerNonceUsed(account, nonce), true);
    }

    function test_processBatch_addSigningWallet_smartContract() public {
        vm.startPrank(sequencer);

        (address owner, uint256 ownerKey) = makeAddrAndKey("owner");
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");

        address contractAccount = address(new ERC1271(owner));

        string memory message = "message";
        uint64 nonce = 1;

        bytes32 contractAccountStructHash =
            keccak256(abi.encode(exchange.REGISTER_TYPEHASH(), signer, keccak256(abi.encodePacked(message)), nonce));
        bytes memory ownerSignature = _signTypedDataHash(ownerKey, contractAccountStructHash);

        bytes32 signerStructHash = keccak256(abi.encode(exchange.SIGN_KEY_TYPEHASH(), contractAccount));
        bytes memory signerSignature = _signTypedDataHash(signerKey, signerStructHash);

        bytes memory addSigningWalletData = abi.encode(
            IExchange.AddSigningWallet(contractAccount, signer, message, nonce, ownerSignature, signerSignature)
        );
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.AddSigningWallet, addSigningWalletData);

        vm.expectEmit(address(exchange));
        emit IExchange.RegisterSigner(contractAccount, signer, nonce);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isSigningWallet(contractAccount, signer), true);
        assertEq(exchange.isRegisterSignerNonceUsed(contractAccount, nonce), true);
        assertEq(exchange.isSigningWallet(owner, signer), false);
    }

    function test_processBatch_addSigningWallet_revertsIfInvalidAccountSignature() public {
        vm.startPrank(sequencer);

        address account = makeAddr("account");
        (, uint256 maliciousAccountKey) = makeAddrAndKey("maliciousAccount");
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");

        string memory message = "message";
        uint64 nonce = 1;

        // signed by malicious account
        bytes memory maliciousAccountSignature = _signTypedDataHash(
            maliciousAccountKey,
            keccak256(abi.encode(exchange.REGISTER_TYPEHASH(), signer, keccak256(abi.encodePacked(message)), 1))
        );

        bytes32 signerStructHash = keccak256(abi.encode(exchange.SIGN_KEY_TYPEHASH(), account));
        bytes memory signerSignature = _signTypedDataHash(signerKey, signerStructHash);

        bytes memory addSigningWalletData = abi.encode(
            IExchange.AddSigningWallet(account, signer, message, nonce, maliciousAccountSignature, signerSignature)
        );
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.AddSigningWallet, addSigningWalletData);

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_InvalidSignature.selector, account));
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_addSigningWallet_revertsIfInvalidSignerSignature() public {
        vm.startPrank(sequencer);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        address signer = makeAddr("signer");
        (address maliciousSigner, uint256 maliciousSignerKey) = makeAddrAndKey("maliciousSigner");

        string memory message = "message";
        uint64 nonce = 1;

        bytes32 accountStructHash =
            keccak256(abi.encode(exchange.REGISTER_TYPEHASH(), signer, keccak256(abi.encodePacked(message)), nonce));
        bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

        // signed by malicious signer
        bytes32 signerStructHash = keccak256(abi.encode(exchange.SIGN_KEY_TYPEHASH(), account));
        bytes memory maliciousSignerSignature = _signTypedDataHash(maliciousSignerKey, signerStructHash);

        bytes memory addSigningWalletData = abi.encode(
            IExchange.AddSigningWallet(account, signer, message, nonce, accountSignature, maliciousSignerSignature)
        );
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.AddSigningWallet, addSigningWalletData);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.Exchange_InvalidSignerSignature.selector, maliciousSigner, signer)
        );
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_addSigningWallet_revertsIfNonceUsed() public {
        vm.startPrank(sequencer);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");

        string memory message = "message";
        uint64 nonce = 1;

        bytes32 accountStructHash =
            keccak256(abi.encode(exchange.REGISTER_TYPEHASH(), signer, keccak256(abi.encodePacked(message)), nonce));
        bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

        bytes32 signerStructHash = keccak256(abi.encode(exchange.SIGN_KEY_TYPEHASH(), account));
        bytes memory signerSignature = _signTypedDataHash(signerKey, signerStructHash);

        bytes memory addSigningWalletData =
            abi.encode(IExchange.AddSigningWallet(account, signer, message, nonce, accountSignature, signerSignature));
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.AddSigningWallet, addSigningWalletData);

        vm.expectEmit(address(exchange));
        emit IExchange.RegisterSigner(account, signer, nonce);
        exchange.processBatch(operation.toArray());

        operation = _encodeDataToOperation(IExchange.OperationType.AddSigningWallet, addSigningWalletData);
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_AddSigningWallet_UsedNonce.selector, account, nonce));
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_matchOrders() public {
        vm.startPrank(sequencer);

        WrappedOrder memory generalOrder;
        generalOrder.isLiquidated = false;
        generalOrder.productId = 1;
        generalOrder.size = 5 * 1e18;
        generalOrder.price = 75_000 * 1e18;
        generalOrder.makerNonce = 2;
        generalOrder.takerNonce = 3;
        generalOrder.makerSide = OrderSide.BUY;
        generalOrder.takerSide = OrderSide.SELL;
        generalOrder.fee = IOrderBook.Fee({maker: 2 * 1e12, taker: 3 * 1e12, referralRebate: 0, liquidationPenalty: 0});

        bytes memory operation;
        uint128 sequencerFee = 5 * 1e12;

        // avoid "Stack too deep"
        {
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                LibOrder.Order({
                    sender: maker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.makerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.makerSide
                }),
                generalOrder.isLiquidated,
                generalOrder.fee.maker
            );
            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                LibOrder.Order({
                    sender: taker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.takerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.takerSide
                }),
                generalOrder.isLiquidated,
                generalOrder.fee.taker
            );

            operation = _encodeDataToOperation(
                IExchange.OperationType.MatchOrders,
                abi.encodePacked(makerEncodedOrder, takerEncodedOrder, sequencerFee)
            );
        }

        vm.expectEmit();
        emit IOrderBook.OrderMatched(
            generalOrder.productId,
            maker,
            taker,
            generalOrder.makerSide,
            generalOrder.makerNonce,
            generalOrder.takerNonce,
            generalOrder.size,
            generalOrder.price,
            generalOrder.fee,
            generalOrder.isLiquidated
        );
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_matchOrders_revertsIfLiquidatedOrders() public {
        vm.startPrank(sequencer);

        uint8 productId = 1;

        bool[2] memory isLiquidated = [true, false];

        for (uint256 i = 0; i < isLiquidated.length; i++) {
            bool makerIsLiquidated = isLiquidated[i];
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                LibOrder.Order({
                    sender: maker,
                    size: 0,
                    price: 0,
                    nonce: 50,
                    productIndex: productId,
                    orderSide: OrderSide.BUY
                }),
                makerIsLiquidated,
                0
            );

            bool takerIsLiquidated = !makerIsLiquidated;
            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                LibOrder.Order({
                    sender: taker,
                    size: 0,
                    price: 0,
                    nonce: 60,
                    productIndex: productId,
                    orderSide: OrderSide.SELL
                }),
                takerIsLiquidated,
                0
            );

            uint128 sequencerFee = 0;
            bytes memory operation = _encodeDataToOperation(
                IExchange.OperationType.MatchOrders,
                abi.encodePacked(makerEncodedOrder, takerEncodedOrder, sequencerFee)
            );

            vm.expectRevert(
                abi.encodeWithSelector(Errors.Exchange_LiquidatedOrder.selector, exchange.executedTransactionCounter())
            );
            exchange.processBatch(operation.toArray());
        }
    }

    function test_processBatch_matchOrders_revertsIfProductIdMismatch() public {
        vm.startPrank(sequencer);

        bool isLiquidated = false;
        uint8 makerProductId = 1;
        bytes memory makerEncodedOrder = _encodeOrder(
            makerSignerKey,
            LibOrder.Order({
                sender: maker,
                size: 0,
                price: 0,
                nonce: 66,
                productIndex: makerProductId,
                orderSide: OrderSide.BUY
            }),
            isLiquidated,
            0
        );

        uint8 takerProductId = 2;
        bytes memory takerEncodedOrder = _encodeOrder(
            takerSignerKey,
            LibOrder.Order({
                sender: taker,
                size: 0,
                price: 0,
                nonce: 77,
                productIndex: takerProductId,
                orderSide: OrderSide.SELL
            }),
            isLiquidated,
            0
        );

        uint128 sequencerFee = 0;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.MatchOrders, abi.encodePacked(makerEncodedOrder, takerEncodedOrder, sequencerFee)
        );

        vm.expectRevert(Errors.Exchange_ProductIdMismatch.selector);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_matchOrders_revertsIfUnauthorizedSigner() public {
        vm.startPrank(sequencer);

        (address maliciousSigner, uint256 maliciousSignerKey) = makeAddrAndKey("maliciousSigner");

        bool isLiquidated = false;
        uint8 productId = 1;
        address[2] memory accounts = [maker, taker];

        for (uint256 i = 0; i < 2; i++) {
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                LibOrder.Order({
                    sender: maker,
                    size: 10,
                    price: 20,
                    nonce: 66,
                    productIndex: productId,
                    orderSide: OrderSide.BUY
                }),
                isLiquidated,
                0
            );
            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                LibOrder.Order({
                    sender: taker,
                    size: 10,
                    price: 20,
                    nonce: 77,
                    productIndex: productId,
                    orderSide: OrderSide.SELL
                }),
                isLiquidated,
                0
            );

            address account = accounts[i];
            if (account == maker) {
                makerEncodedOrder = _encodeOrder(
                    maliciousSignerKey,
                    LibOrder.Order({
                        sender: maker,
                        size: 0,
                        price: 0,
                        nonce: 66,
                        productIndex: productId,
                        orderSide: OrderSide.BUY
                    }),
                    isLiquidated,
                    0
                );
            } else {
                takerEncodedOrder = _encodeOrder(
                    maliciousSignerKey,
                    LibOrder.Order({
                        sender: taker,
                        size: 0,
                        price: 0,
                        nonce: 77,
                        productIndex: productId,
                        orderSide: OrderSide.SELL
                    }),
                    isLiquidated,
                    0
                );
            }

            uint128 sequencerFee = 0;
            bytes memory operation = _encodeDataToOperation(
                IExchange.OperationType.MatchOrders,
                abi.encodePacked(makerEncodedOrder, takerEncodedOrder, sequencerFee)
            );

            vm.expectRevert(
                abi.encodeWithSelector(Errors.Exchange_UnauthorizedSigner.selector, account, maliciousSigner)
            );
            exchange.processBatch(operation.toArray());
        }
    }

    function test_processBatch_matchOrders_revertsIfInvalidSignerSignature() public {
        vm.startPrank(sequencer);

        (address maliciousSigner, uint256 maliciousSignerKey) = makeAddrAndKey("maliciousSigner");

        uint8 productId = 1;
        bool isLiquidated = false;
        address[2] memory signers = [makerSigner, takerSigner];

        for (uint256 i = 0; i < 2; i++) {
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                LibOrder.Order({
                    sender: maker,
                    size: 10,
                    price: 20,
                    nonce: 77,
                    productIndex: productId,
                    orderSide: OrderSide.BUY
                }),
                isLiquidated,
                0
            );
            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                LibOrder.Order({
                    sender: taker,
                    size: 10,
                    price: 20,
                    nonce: 77,
                    productIndex: productId,
                    orderSide: OrderSide.SELL
                }),
                isLiquidated,
                0
            );

            address expectedSigner = signers[i];
            if (expectedSigner == makerSigner) {
                makerEncodedOrder = _encodeOrderWithSigner(
                    makerSigner,
                    maliciousSignerKey,
                    LibOrder.Order({
                        sender: maker,
                        size: 0,
                        price: 0,
                        nonce: 33,
                        productIndex: productId,
                        orderSide: OrderSide.BUY
                    }),
                    isLiquidated,
                    0
                );
            } else {
                takerEncodedOrder = _encodeOrderWithSigner(
                    takerSigner,
                    maliciousSignerKey,
                    LibOrder.Order({
                        sender: taker,
                        size: 0,
                        price: 0,
                        nonce: 88,
                        productIndex: productId,
                        orderSide: OrderSide.SELL
                    }),
                    isLiquidated,
                    0
                );
            }

            bytes memory operation = _encodeDataToOperation(
                IExchange.OperationType.MatchOrders, abi.encodePacked(makerEncodedOrder, takerEncodedOrder, uint128(0))
            );

            vm.expectRevert(
                abi.encodeWithSelector(Errors.Exchange_InvalidSignerSignature.selector, maliciousSigner, expectedSigner)
            );
            exchange.processBatch(operation.toArray());
        }
    }

    function test_processBatch_matchLiquidatedOrders() public {
        vm.startPrank(sequencer);

        WrappedOrder memory generalOrder;
        generalOrder.isLiquidated = true;
        generalOrder.productId = 1;
        generalOrder.size = 5 * 1e18;
        generalOrder.price = 75_000 * 1e18;
        generalOrder.makerNonce = 70;
        generalOrder.takerNonce = 30;
        generalOrder.makerSide = OrderSide.BUY;
        generalOrder.takerSide = OrderSide.SELL;
        generalOrder.fee =
            IOrderBook.Fee({maker: 2 * 1e12, taker: 3 * 1e12, referralRebate: 0, liquidationPenalty: 4e14});
        bytes memory operation;
        uint128 sequencerFee = 5 * 1e12;

        // avoid "Stack too deep"
        {
            bool makerIsLiquidated = false;
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                LibOrder.Order({
                    sender: maker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.makerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.makerSide
                }),
                makerIsLiquidated,
                generalOrder.fee.maker
            );
            bytes memory takerEncodedOrder = _encodeLiquidatedOrder(
                LibOrder.Order({
                    sender: taker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.takerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.takerSide
                }),
                generalOrder.isLiquidated,
                generalOrder.fee.taker
            );

            ReferralRebate memory referralRebate;
            bytes memory referralRebateData = abi.encodePacked(
                referralRebate.makerReferrer,
                referralRebate.makerReferrerRebateRate,
                referralRebate.takerReferrer,
                referralRebate.takerReferrerRebateRate
            );

            operation = _encodeDataToOperation(
                IExchange.OperationType.MatchLiquidationOrders,
                abi.encodePacked(
                    makerEncodedOrder,
                    takerEncodedOrder,
                    sequencerFee,
                    referralRebateData,
                    generalOrder.fee.liquidationPenalty
                )
            );
        }

        vm.expectEmit();
        emit IOrderBook.OrderMatched(
            generalOrder.productId,
            maker,
            taker,
            generalOrder.makerSide,
            generalOrder.makerNonce,
            generalOrder.takerNonce,
            generalOrder.size,
            generalOrder.price,
            generalOrder.fee,
            generalOrder.isLiquidated
        );
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_matchLiquidatedOrders_revertsIfNotLiquidatedOrder() public {
        vm.startPrank(sequencer);

        uint8 productId = 1;

        bool makerIsLiquidated = false;
        bytes memory makerEncodedOrder = _encodeOrder(
            makerSignerKey,
            LibOrder.Order({
                sender: maker,
                size: 0,
                price: 0,
                nonce: 50,
                productIndex: productId,
                orderSide: OrderSide.BUY
            }),
            makerIsLiquidated,
            0
        );

        bool takerIsLiquidated = false;
        bytes memory takerEncodedOrder = _encodeLiquidatedOrder(
            LibOrder.Order({
                sender: taker,
                size: 0,
                price: 0,
                nonce: 60,
                productIndex: productId,
                orderSide: OrderSide.SELL
            }),
            takerIsLiquidated,
            0
        );

        uint128 sequencerFee = 0;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.MatchLiquidationOrders,
            abi.encodePacked(makerEncodedOrder, takerEncodedOrder, sequencerFee)
        );

        vm.expectRevert(
            abi.encodeWithSelector(Errors.Exchange_NotLiquidatedOrder.selector, exchange.executedTransactionCounter())
        );
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_matchLiquidatedOrders_revertsIfMakerIsiquidatedOrder() public {
        vm.startPrank(sequencer);

        uint8 productId = 1;

        bool makerIsLiquidated = true;
        bytes memory makerEncodedOrder = _encodeOrder(
            makerSignerKey,
            LibOrder.Order({
                sender: maker,
                size: 0,
                price: 0,
                nonce: 50,
                productIndex: productId,
                orderSide: OrderSide.BUY
            }),
            makerIsLiquidated,
            0
        );

        bool takerIsLiquidated = true;
        bytes memory takerEncodedOrder = _encodeLiquidatedOrder(
            LibOrder.Order({
                sender: taker,
                size: 0,
                price: 0,
                nonce: 60,
                productIndex: productId,
                orderSide: OrderSide.SELL
            }),
            takerIsLiquidated,
            0
        );

        uint128 sequencerFee = 0;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.MatchLiquidationOrders,
            abi.encodePacked(makerEncodedOrder, takerEncodedOrder, sequencerFee)
        );

        vm.expectRevert(
            abi.encodeWithSelector(Errors.Exchange_MakerLiquidatedOrder.selector, exchange.executedTransactionCounter())
        );
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_matchLiquidatedOrders_revertsIfProductIdMismatch() public {
        vm.startPrank(sequencer);

        bool isLiquidated = true;

        uint8 makerProductId = 1;
        bool makerIsLiquidated = false;
        bytes memory makerEncodedOrder = _encodeOrder(
            makerSignerKey,
            LibOrder.Order({
                sender: maker,
                size: 0,
                price: 0,
                nonce: 66,
                productIndex: makerProductId,
                orderSide: OrderSide.BUY
            }),
            makerIsLiquidated,
            0
        );

        uint8 takerProductId = 2;
        bytes memory takerEncodedOrder = _encodeLiquidatedOrder(
            LibOrder.Order({
                sender: taker,
                size: 0,
                price: 0,
                nonce: 77,
                productIndex: takerProductId,
                orderSide: OrderSide.SELL
            }),
            isLiquidated,
            0
        );

        uint128 sequencerFee = 0;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.MatchLiquidationOrders,
            abi.encodePacked(makerEncodedOrder, takerEncodedOrder, sequencerFee)
        );

        vm.expectRevert(Errors.Exchange_ProductIdMismatch.selector);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_matchLiquidatedOrders_revertsIfUnauthorizedSigner() public {
        vm.startPrank(sequencer);

        (address maliciousSigner, uint256 maliciousSignerKey) = makeAddrAndKey("maliciousSigner");

        bool isLiquidated = true;
        uint8 productId = 1;

        bool makerIsLiquidated = false;
        bytes memory makerEncodedOrder = _encodeOrder(
            maliciousSignerKey,
            LibOrder.Order({
                sender: maker,
                size: 0,
                price: 0,
                nonce: 66,
                productIndex: productId,
                orderSide: OrderSide.BUY
            }),
            makerIsLiquidated,
            0
        );
        bytes memory takerEncodedOrder = _encodeLiquidatedOrder(
            LibOrder.Order({
                sender: taker,
                size: 0,
                price: 0,
                nonce: 77,
                productIndex: productId,
                orderSide: OrderSide.SELL
            }),
            isLiquidated,
            0
        );

        uint128 sequencerFee = 0;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.MatchLiquidationOrders,
            abi.encodePacked(makerEncodedOrder, takerEncodedOrder, sequencerFee)
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_UnauthorizedSigner.selector, maker, maliciousSigner));
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_matchLiquidatedOrders_revertsIfInvalidSignerSignature() public {
        vm.startPrank(sequencer);

        (address maliciousSigner, uint256 maliciousSignerKey) = makeAddrAndKey("maliciousSigner");

        uint8 productId = 1;
        bool isLiquidated = true;

        bool makerIsLiquidated = false;
        bytes memory makerEncodedOrder = _encodeOrderWithSigner(
            makerSigner,
            maliciousSignerKey,
            LibOrder.Order({
                sender: maker,
                size: 0,
                price: 0,
                nonce: 77,
                productIndex: productId,
                orderSide: OrderSide.BUY
            }),
            makerIsLiquidated,
            0
        );
        bytes memory takerEncodedOrder = _encodeLiquidatedOrder(
            LibOrder.Order({
                sender: taker,
                size: 0,
                price: 0,
                nonce: 77,
                productIndex: productId,
                orderSide: OrderSide.SELL
            }),
            isLiquidated,
            0
        );

        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.MatchLiquidationOrders,
            abi.encodePacked(makerEncodedOrder, takerEncodedOrder, uint128(0))
        );

        vm.expectRevert(
            abi.encodeWithSelector(Errors.Exchange_InvalidSignerSignature.selector, maliciousSigner, makerSigner)
        );
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_matchOrders_referralRebate() public {
        vm.startPrank(sequencer);

        WrappedOrder memory generalOrder;
        generalOrder.isLiquidated = false;
        generalOrder.productId = 1;
        generalOrder.size = 5 * 1e18;
        generalOrder.price = 75_000 * 1e18;
        generalOrder.makerNonce = 66;
        generalOrder.takerNonce = 77;
        generalOrder.makerSide = OrderSide.BUY;
        generalOrder.takerSide = OrderSide.SELL;
        generalOrder.fee = IOrderBook.Fee({maker: 2 * 1e12, taker: 3 * 1e12, referralRebate: 0, liquidationPenalty: 0});

        bytes memory makerEncodedOrder = _encodeOrder(
            makerSignerKey,
            LibOrder.Order({
                sender: maker,
                size: generalOrder.size,
                price: generalOrder.price,
                nonce: generalOrder.makerNonce,
                productIndex: generalOrder.productId,
                orderSide: generalOrder.makerSide
            }),
            generalOrder.isLiquidated,
            generalOrder.fee.maker
        );

        bytes memory takerEncodedOrder = _encodeOrder(
            takerSignerKey,
            LibOrder.Order({
                sender: taker,
                size: generalOrder.size,
                price: generalOrder.price,
                nonce: generalOrder.takerNonce,
                productIndex: generalOrder.productId,
                orderSide: generalOrder.takerSide
            }),
            generalOrder.isLiquidated,
            generalOrder.fee.taker
        );

        ReferralRebate memory referralRebate = ReferralRebate({
            makerReferrer: makeAddr("makerReferrer"),
            makerReferrerRebateRate: 1000, // 10%
            takerReferrer: makeAddr("takerReferrer"),
            takerReferrerRebateRate: 500 // 5%
        });
        bytes memory referralRebateData = abi.encodePacked(
            referralRebate.makerReferrer,
            referralRebate.makerReferrerRebateRate,
            referralRebate.takerReferrer,
            referralRebate.takerReferrerRebateRate
        );

        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.MatchOrders,
            abi.encodePacked(makerEncodedOrder, takerEncodedOrder, generalOrder.sequencerFee, referralRebateData)
        );

        generalOrder.fee.referralRebate = uint128(generalOrder.fee.maker).calculatePercentage(
            referralRebate.makerReferrerRebateRate
        ) + uint128(generalOrder.fee.taker).calculatePercentage(referralRebate.takerReferrerRebateRate);

        vm.expectEmit(address(exchange));
        emit IExchange.RebateReferrer(
            referralRebate.makerReferrer,
            uint128(generalOrder.fee.maker).calculatePercentage(referralRebate.makerReferrerRebateRate)
        );
        emit IExchange.RebateReferrer(
            referralRebate.takerReferrer,
            uint128(generalOrder.fee.taker).calculatePercentage(referralRebate.takerReferrerRebateRate)
        );
        vm.expectEmit(address(orderbook));
        emit IOrderBook.OrderMatched(
            generalOrder.productId,
            maker,
            taker,
            generalOrder.makerSide,
            generalOrder.makerNonce,
            generalOrder.takerNonce,
            generalOrder.size,
            generalOrder.price,
            generalOrder.fee,
            generalOrder.isLiquidated
        );
        exchange.processBatch(operation.toArray());

        int256 makerReferrerBalance = exchange.balanceOf(referralRebate.makerReferrer, address(collateralToken));
        int256 takerReferrerBalance = exchange.balanceOf(referralRebate.takerReferrer, address(collateralToken));
        assertEq(
            uint256(makerReferrerBalance),
            uint128(generalOrder.fee.maker).calculatePercentage(referralRebate.makerReferrerRebateRate)
        );
        assertEq(
            uint256(takerReferrerBalance),
            uint128(generalOrder.fee.taker).calculatePercentage(referralRebate.takerReferrerRebateRate)
        );

        int128 tradingFees = orderbook.getTradingFees();
        assertEq(tradingFees, generalOrder.fee.maker + generalOrder.fee.taker - int128(generalOrder.fee.referralRebate));

        IPerp.Balance memory makerPerpBalance = perpEngine.getOpenPosition(maker, generalOrder.productId);
        IPerp.Balance memory takerPerpBalance = perpEngine.getOpenPosition(taker, generalOrder.productId);

        // maker goes long
        assertEq(makerPerpBalance.size, int128(generalOrder.size));
        assertEq(
            makerPerpBalance.quoteBalance,
            -int128(generalOrder.size).mul18D(int128(generalOrder.price)) - generalOrder.fee.maker
        );

        // taker goes short
        assertEq(takerPerpBalance.size, -int128(generalOrder.size));
        assertEq(
            takerPerpBalance.quoteBalance,
            int128(generalOrder.size).mul18D(int128(generalOrder.price)) - generalOrder.fee.taker
        );
    }

    function test_processBatch_matchLiquidatedOrders_referralRebate() public {
        vm.startPrank(sequencer);

        WrappedOrder memory generalOrder;
        generalOrder.isLiquidated = true;
        generalOrder.productId = 1;
        generalOrder.size = 5 * 1e18;
        generalOrder.price = 75_000 * 1e18;
        generalOrder.makerNonce = 66;
        generalOrder.takerNonce = 77;
        generalOrder.makerSide = OrderSide.BUY;
        generalOrder.takerSide = OrderSide.SELL;
        generalOrder.fee =
            IOrderBook.Fee({maker: 2 * 1e12, taker: 3 * 1e12, referralRebate: 0, liquidationPenalty: 4e12});

        ReferralRebate memory referralRebate;
        bytes memory operation;

        {
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                LibOrder.Order({
                    sender: maker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.makerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.makerSide
                }),
                false,
                generalOrder.fee.maker
            );

            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                LibOrder.Order({
                    sender: taker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.takerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.takerSide
                }),
                generalOrder.isLiquidated,
                generalOrder.fee.taker
            );

            referralRebate = ReferralRebate({
                makerReferrer: makeAddr("makerReferrer"),
                makerReferrerRebateRate: 1000, // 10%
                takerReferrer: makeAddr("takerReferrer"),
                takerReferrerRebateRate: 500 // 5%
            });
            bytes memory referralRebateData = abi.encodePacked(
                referralRebate.makerReferrer,
                referralRebate.makerReferrerRebateRate,
                referralRebate.takerReferrer,
                referralRebate.takerReferrerRebateRate
            );

            operation = _encodeDataToOperation(
                IExchange.OperationType.MatchLiquidationOrders,
                abi.encodePacked(
                    makerEncodedOrder,
                    takerEncodedOrder,
                    generalOrder.sequencerFee,
                    referralRebateData,
                    generalOrder.fee.liquidationPenalty
                )
            );
        }

        generalOrder.fee.referralRebate = uint128(generalOrder.fee.maker).calculatePercentage(
            referralRebate.makerReferrerRebateRate
        ) + uint128(generalOrder.fee.taker).calculatePercentage(referralRebate.takerReferrerRebateRate);

        uint256 insuranceFundBefore = clearingService.getInsuranceFundBalance();

        vm.expectEmit(address(exchange));
        emit IExchange.RebateReferrer(
            referralRebate.makerReferrer,
            uint128(generalOrder.fee.maker).calculatePercentage(referralRebate.makerReferrerRebateRate)
        );
        emit IExchange.RebateReferrer(
            referralRebate.takerReferrer,
            uint128(generalOrder.fee.taker).calculatePercentage(referralRebate.takerReferrerRebateRate)
        );
        vm.expectEmit(address(orderbook));
        emit IOrderBook.OrderMatched(
            generalOrder.productId,
            maker,
            taker,
            generalOrder.makerSide,
            generalOrder.makerNonce,
            generalOrder.takerNonce,
            generalOrder.size,
            generalOrder.price,
            generalOrder.fee,
            generalOrder.isLiquidated
        );
        exchange.processBatch(operation.toArray());

        int256 makerReferrerBalance = exchange.balanceOf(referralRebate.makerReferrer, address(collateralToken));
        int256 takerReferrerBalance = exchange.balanceOf(referralRebate.takerReferrer, address(collateralToken));
        assertEq(
            uint256(makerReferrerBalance),
            uint128(generalOrder.fee.maker).calculatePercentage(referralRebate.makerReferrerRebateRate)
        );
        assertEq(
            uint256(takerReferrerBalance),
            uint128(generalOrder.fee.taker).calculatePercentage(referralRebate.takerReferrerRebateRate)
        );

        assertEq(
            orderbook.getTradingFees(),
            generalOrder.fee.maker + generalOrder.fee.taker - int128(generalOrder.fee.referralRebate)
        );

        IPerp.Balance memory makerPerpBalance = perpEngine.getOpenPosition(maker, generalOrder.productId);
        IPerp.Balance memory takerPerpBalance = perpEngine.getOpenPosition(taker, generalOrder.productId);

        // maker goes long
        assertEq(makerPerpBalance.size, int128(generalOrder.size));
        assertEq(
            makerPerpBalance.quoteBalance,
            -int128(generalOrder.size).mul18D(int128(generalOrder.price)) - generalOrder.fee.maker
        );

        // taker goes short
        uint256 liquidationFee = clearingService.getInsuranceFundBalance() - insuranceFundBefore;
        assertEq(takerPerpBalance.size, -int128(generalOrder.size));
        assertEq(
            takerPerpBalance.quoteBalance,
            int128(generalOrder.size).mul18D(int128(generalOrder.price)) - generalOrder.fee.taker
                - int256(liquidationFee)
        );
    }

    function test_processBatch_matchOrders_referralRebate_revertsIfExceedMaxRebateRate() public {
        vm.startPrank(sequencer);

        WrappedOrder memory generalOrder;
        generalOrder.isLiquidated = false;
        generalOrder.productId = 1;
        generalOrder.size = 5 * 1e18;
        generalOrder.price = 75_000 * 1e18;
        generalOrder.makerNonce = 66;
        generalOrder.takerNonce = 77;
        generalOrder.makerSide = OrderSide.BUY;
        generalOrder.takerSide = OrderSide.SELL;
        generalOrder.fee = IOrderBook.Fee({maker: 2 * 1e12, taker: 3 * 1e12, referralRebate: 0, liquidationPenalty: 0});

        bytes memory makerEncodedOrder = _encodeOrder(
            makerSignerKey,
            LibOrder.Order({
                sender: maker,
                size: generalOrder.size,
                price: generalOrder.price,
                nonce: generalOrder.makerNonce,
                productIndex: generalOrder.productId,
                orderSide: generalOrder.makerSide
            }),
            generalOrder.isLiquidated,
            generalOrder.fee.maker
        );

        bytes memory takerEncodedOrder = _encodeOrder(
            takerSignerKey,
            LibOrder.Order({
                sender: taker,
                size: generalOrder.size,
                price: generalOrder.price,
                nonce: generalOrder.takerNonce,
                productIndex: generalOrder.productId,
                orderSide: generalOrder.takerSide
            }),
            generalOrder.isLiquidated,
            generalOrder.fee.taker
        );

        ReferralRebate memory referralRebate = ReferralRebate({
            makerReferrer: makeAddr("makerReferrer"),
            makerReferrerRebateRate: 0,
            takerReferrer: makeAddr("takerReferrer"),
            takerReferrerRebateRate: 0
        });

        for (uint256 i = 0; i < 2; i++) {
            uint16 invalidRebateRate = MAX_REBATE_RATE + 1;
            if (i == 0) {
                referralRebate.makerReferrerRebateRate = invalidRebateRate;
                referralRebate.takerReferrerRebateRate = 0;
            } else {
                referralRebate.makerReferrerRebateRate = 0;
                referralRebate.takerReferrerRebateRate = invalidRebateRate;
            }

            bytes memory referralRebateData = abi.encodePacked(
                referralRebate.makerReferrer,
                referralRebate.makerReferrerRebateRate,
                referralRebate.takerReferrer,
                referralRebate.takerReferrerRebateRate
            );

            bytes memory operation = _encodeDataToOperation(
                IExchange.OperationType.MatchOrders,
                abi.encodePacked(makerEncodedOrder, takerEncodedOrder, generalOrder.sequencerFee, referralRebateData)
            );

            vm.expectRevert(
                abi.encodeWithSelector(
                    Errors.Exchange_ExceededMaxRebateRate.selector, invalidRebateRate, MAX_REBATE_RATE
                )
            );
            exchange.processBatch(operation.toArray());
        }
    }

    function test_processBatch_mathOrders_rebateMaker() public {
        vm.startPrank(sequencer);

        WrappedOrder memory generalOrder;
        generalOrder.isLiquidated = false;
        generalOrder.productId = 1;
        generalOrder.size = 5 * 1e18;
        generalOrder.price = 75_000 * 1e18;
        generalOrder.makerNonce = 66;
        generalOrder.takerNonce = 77;
        generalOrder.makerSide = OrderSide.BUY;
        generalOrder.takerSide = OrderSide.SELL;
        generalOrder.sequencerFee = 3 * 1e12;

        int128 rebateMaker = -2 * 1e12;
        generalOrder.fee =
            IOrderBook.Fee({maker: rebateMaker, taker: 3 * 1e12, referralRebate: 0, liquidationPenalty: 0});

        ReferralRebate memory referralRebate = ReferralRebate({
            makerReferrer: makeAddr("makerReferrer"),
            makerReferrerRebateRate: 1000, // 10%
            takerReferrer: makeAddr("takerReferrer"),
            takerReferrerRebateRate: 500 // 5%
        });
        bytes memory operation;
        {
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                LibOrder.Order({
                    sender: maker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.makerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.makerSide
                }),
                generalOrder.isLiquidated,
                rebateMaker
            );

            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                LibOrder.Order({
                    sender: taker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.takerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.takerSide
                }),
                generalOrder.isLiquidated,
                generalOrder.fee.taker
            );

            bytes memory referralRebateData = abi.encodePacked(
                referralRebate.makerReferrer,
                referralRebate.makerReferrerRebateRate,
                referralRebate.takerReferrer,
                referralRebate.takerReferrerRebateRate
            );

            operation = _encodeDataToOperation(
                IExchange.OperationType.MatchOrders,
                abi.encodePacked(makerEncodedOrder, takerEncodedOrder, generalOrder.sequencerFee, referralRebateData)
            );

            // referrer rebate for only taker
            generalOrder.fee.referralRebate =
                uint128(generalOrder.fee.taker).calculatePercentage(referralRebate.takerReferrerRebateRate);
        }

        // not charge maker fee
        generalOrder.fee.maker = 0;

        vm.expectEmit(address(exchange));
        emit IExchange.RebateMaker(maker, uint128(-rebateMaker));
        vm.expectEmit(address(orderbook));
        emit IOrderBook.OrderMatched(
            generalOrder.productId,
            maker,
            taker,
            generalOrder.makerSide,
            generalOrder.makerNonce,
            generalOrder.takerNonce,
            generalOrder.size,
            generalOrder.price,
            generalOrder.fee,
            generalOrder.isLiquidated
        );
        exchange.processBatch(operation.toArray());

        int256 makerReferrerBalance = exchange.balanceOf(referralRebate.makerReferrer, address(collateralToken));
        int256 takerReferrerBalance = exchange.balanceOf(referralRebate.takerReferrer, address(collateralToken));
        assertEq(uint256(makerReferrerBalance), 0);
        assertEq(
            uint256(takerReferrerBalance),
            uint128(generalOrder.fee.taker).calculatePercentage(referralRebate.takerReferrerRebateRate)
        );

        int128 tradingFees = orderbook.getTradingFees();
        assertEq(tradingFees, generalOrder.fee.taker - int128(generalOrder.fee.referralRebate));

        IPerp.Balance memory makerPerpBalance = perpEngine.getOpenPosition(maker, generalOrder.productId);
        IPerp.Balance memory takerPerpBalance = perpEngine.getOpenPosition(taker, generalOrder.productId);

        // maker goes long
        assertEq(makerPerpBalance.size, int128(generalOrder.size));
        assertEq(makerPerpBalance.quoteBalance, -int128(generalOrder.size).mul18D(int128(generalOrder.price)));

        // taker goes short
        assertEq(takerPerpBalance.size, -int128(generalOrder.size));
        assertEq(
            takerPerpBalance.quoteBalance,
            int128(generalOrder.size).mul18D(int128(generalOrder.price)) - generalOrder.fee.taker
                - int128(generalOrder.sequencerFee)
        );

        // rebate fee to Maker account
        assertEq(exchange.balanceOf(maker, address(collateralToken)), -rebateMaker);
    }

    function test_processBatch_matchLiquidatedOrders_rebateMaker() public {
        vm.startPrank(sequencer);

        WrappedOrder memory generalOrder;
        generalOrder.isLiquidated = true;
        generalOrder.productId = 1;
        generalOrder.size = 5 * 1e18;
        generalOrder.price = 75_000 * 1e18;
        generalOrder.makerNonce = 66;
        generalOrder.takerNonce = 77;
        generalOrder.makerSide = OrderSide.BUY;
        generalOrder.takerSide = OrderSide.SELL;
        generalOrder.sequencerFee = 5 * 1e12;

        int128 rebateMaker = -2 * 1e12;
        generalOrder.fee =
            IOrderBook.Fee({maker: rebateMaker, taker: 3 * 1e12, referralRebate: 0, liquidationPenalty: 4e12});

        ReferralRebate memory referralRebate = ReferralRebate({
            makerReferrer: makeAddr("makerReferrer"),
            makerReferrerRebateRate: 1000, // 10%
            takerReferrer: makeAddr("takerReferrer"),
            takerReferrerRebateRate: 500 // 5%
        });
        bytes memory operation;

        {
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                LibOrder.Order({
                    sender: maker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.makerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.makerSide
                }),
                false,
                rebateMaker
            );

            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                LibOrder.Order({
                    sender: taker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.takerNonce,
                    productIndex: generalOrder.productId,
                    orderSide: generalOrder.takerSide
                }),
                generalOrder.isLiquidated,
                generalOrder.fee.taker
            );

            bytes memory referralRebateData = abi.encodePacked(
                referralRebate.makerReferrer,
                referralRebate.makerReferrerRebateRate,
                referralRebate.takerReferrer,
                referralRebate.takerReferrerRebateRate
            );

            operation = _encodeDataToOperation(
                IExchange.OperationType.MatchLiquidationOrders,
                abi.encodePacked(
                    makerEncodedOrder,
                    takerEncodedOrder,
                    generalOrder.sequencerFee,
                    referralRebateData,
                    generalOrder.fee.liquidationPenalty
                )
            );

            // referrer rebate for only taker
            generalOrder.fee.referralRebate =
                uint128(generalOrder.fee.taker).calculatePercentage(referralRebate.takerReferrerRebateRate);
        }
        uint256 insuranceFundBefore = clearingService.getInsuranceFundBalance();

        // not charge maker fee
        generalOrder.fee.maker = 0;

        vm.expectEmit();
        emit IOrderBook.OrderMatched(
            generalOrder.productId,
            maker,
            taker,
            generalOrder.makerSide,
            generalOrder.makerNonce,
            generalOrder.takerNonce,
            generalOrder.size,
            generalOrder.price,
            generalOrder.fee,
            generalOrder.isLiquidated
        );
        exchange.processBatch(operation.toArray());

        assertEq(uint256(exchange.balanceOf(referralRebate.makerReferrer, address(collateralToken))), 0);
        assertEq(
            uint256(exchange.balanceOf(referralRebate.takerReferrer, address(collateralToken))),
            uint128(generalOrder.fee.taker).calculatePercentage(referralRebate.takerReferrerRebateRate)
        );

        int128 tradingFees = orderbook.getTradingFees();
        assertEq(tradingFees, generalOrder.fee.taker - int128(generalOrder.fee.referralRebate));

        IPerp.Balance memory makerPerpBalance = perpEngine.getOpenPosition(maker, generalOrder.productId);
        IPerp.Balance memory takerPerpBalance = perpEngine.getOpenPosition(taker, generalOrder.productId);

        // maker goes long
        assertEq(makerPerpBalance.size, int128(generalOrder.size));
        assertEq(makerPerpBalance.quoteBalance, -int128(generalOrder.size).mul18D(int128(generalOrder.price)));

        // taker goes short
        uint256 liquidationFee = clearingService.getInsuranceFundBalance() - insuranceFundBefore;
        assertEq(takerPerpBalance.size, -int128(generalOrder.size));
        assertEq(
            takerPerpBalance.quoteBalance,
            int128(generalOrder.size).mul18D(int128(generalOrder.price)) - generalOrder.fee.taker
                - int128(generalOrder.sequencerFee) - int256(liquidationFee)
        );

        // rebate fee to Maker account
        assertEq(exchange.balanceOf(maker, address(collateralToken)), -rebateMaker);
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

        address account = makeAddr("account");

        // fee on stable tokens
        uint128 invalidFee = 1 ether + 1;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.Withdraw,
            abi.encode(IExchange.Withdraw(account, address(collateralToken), 100, 0, "", invalidFee))
        );
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_ExceededMaxWithdrawFee.selector, invalidFee, 1 ether));
        exchange.processBatch(operation.toArray());

        // fee on weth
        invalidFee = 0.001 ether + 1;
        operation = _encodeDataToOperation(
            IExchange.OperationType.Withdraw, abi.encode(IExchange.Withdraw(account, WETH9, 100, 0, "", invalidFee))
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

    function test_processBatch_coverLossWithInsuranceFund() public {
        address account = makeAddr("account");
        uint128 loss = 5 * 1e18;
        uint128 insuranceFund = 100 * 1e18;

        {
            vm.startPrank(address(exchange));
            ISpot.AccountDelta[] memory deltas = new ISpot.AccountDelta[](1);
            deltas[0] = ISpot.AccountDelta({token: address(collateralToken), account: account, amount: -int128(loss)});
            spotEngine.modifyAccount(deltas);
            clearingService.depositInsuranceFund(insuranceFund);
            vm.stopPrank();
        }

        bytes memory operation =
            _encodeDataToOperation(IExchange.OperationType.CoverLossByInsuranceFund, abi.encode(account, loss));

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(spotEngine.getBalance(account, address(collateralToken)), 0);
        assertEq(clearingService.getInsuranceFundBalance(), insuranceFund - loss);
    }

    function test_processBatch_cumulateFundingRate() public {
        vm.startPrank(sequencer);

        uint8 productId = 2;
        int128 premiumRate = -15 * 1e16;
        uint256 fundingRateId = exchange.lastFundingRateUpdate() + 1;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.UpdateFundingRate, abi.encode(productId, premiumRate, fundingRateId)
        );

        int128 cumulativeFundingRate = perpEngine.getFundingRate(productId).cumulativeFunding18D;
        cumulativeFundingRate += premiumRate;
        vm.expectEmit(address(exchange));
        emit IExchange.UpdateFundingRate(productId, premiumRate, cumulativeFundingRate);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_cumulateFundingRate_revertsIfInvalidFundingRateId() public {
        vm.startPrank(sequencer);

        uint8 productId = 2;
        int128 premiumRate = -15 * 1e16;

        uint256 fundingRateId = 500;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.UpdateFundingRate, abi.encode(productId, premiumRate, fundingRateId)
        );
        exchange.processBatch(operation.toArray());

        for (uint256 i = 0; i < 5; i++) {
            uint256 invalidFundingRateId = fundingRateId - i;
            bytes memory op = _encodeDataToOperation(
                IExchange.OperationType.UpdateFundingRate, abi.encode(productId, premiumRate, invalidFundingRateId)
            );

            vm.expectRevert(
                abi.encodeWithSelector(
                    Errors.Exchange_InvalidFundingRateSequenceNumber.selector,
                    invalidFundingRateId,
                    exchange.lastFundingRateUpdate()
                )
            );
            exchange.processBatch(op.toArray());
        }
    }

    function test_processBatch_revertsWhenTransactionIdMismatch() public {
        vm.startPrank(sequencer);

        bytes[] memory data = new bytes[](1);
        uint8 mockOperationType = 0;
        uint32 currentTransactionId = exchange.executedTransactionCounter();
        uint32 mismatchTransactionId = currentTransactionId + 1;
        data[0] = abi.encodePacked(mockOperationType, mismatchTransactionId);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.Exchange_InvalidTransactionId.selector, mismatchTransactionId, currentTransactionId
            )
        );
        exchange.processBatch(data);
    }

    function test_processBatch_revertsIfInvalidOperationType() public {
        vm.startPrank(sequencer);

        bytes memory invalidOperation = _encodeDataToOperation(IExchange.OperationType.Invalid, abi.encodePacked());

        vm.expectRevert(Errors.Exchange_InvalidOperationType.selector);
        exchange.processBatch(invalidOperation.toArray());
    }

    function test_processBatch_revertsWhenUnauthorized() public {
        address malicious = makeAddr("malicious");
        bytes32 role = access.BATCH_OPERATOR_ROLE();

        vm.startPrank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        bytes[] memory data = new bytes[](0);
        exchange.processBatch(data);
    }

    function test_processBatch_revertsWhenPaused() public {
        vm.startPrank(sequencer);
        exchange.setPauseBatchProcess(true);

        vm.expectRevert(Errors.Exchange_PausedProcessBatch.selector);
        bytes[] memory data = new bytes[](0);
        exchange.processBatch(data);
    }

    function test_registerSigningWallet_EOA() public {
        vm.startPrank(sequencer);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");

        string memory message = "message";
        uint64 nonce = 1;

        bytes32 accountStructHash =
            keccak256(abi.encode(exchange.REGISTER_TYPEHASH(), signer, keccak256(abi.encodePacked(message)), nonce));
        bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

        bytes32 signerStructHash = keccak256(abi.encode(exchange.SIGN_KEY_TYPEHASH(), account));
        bytes memory signerSignature = _signTypedDataHash(signerKey, signerStructHash);

        vm.expectEmit(address(exchange));
        emit IExchange.RegisterSigner(account, signer, nonce);
        exchange.registerSigningWallet(account, signer, message, nonce, accountSignature, signerSignature);

        assertEq(exchange.isSigningWallet(account, signer), true);
        assertEq(exchange.isRegisterSignerNonceUsed(account, nonce), true);
    }

    function test_registerSigningWallet_smartContract() public {
        vm.startPrank(sequencer);

        (address owner, uint256 ownerKey) = makeAddrAndKey("owner");
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");

        address contractAccount = address(new ERC1271(owner));

        string memory message = "message";
        uint64 nonce = 1;

        bytes32 contractAccountStructHash =
            keccak256(abi.encode(exchange.REGISTER_TYPEHASH(), signer, keccak256(abi.encodePacked(message)), nonce));
        bytes memory ownerSignature = _signTypedDataHash(ownerKey, contractAccountStructHash);

        bytes32 signerStructHash = keccak256(abi.encode(exchange.SIGN_KEY_TYPEHASH(), contractAccount));
        bytes memory signerSignature = _signTypedDataHash(signerKey, signerStructHash);

        vm.expectEmit(address(exchange));
        emit IExchange.RegisterSigner(contractAccount, signer, nonce);
        exchange.registerSigningWallet(contractAccount, signer, message, nonce, ownerSignature, signerSignature);

        assertEq(exchange.isSigningWallet(contractAccount, signer), true);
        assertEq(exchange.isRegisterSignerNonceUsed(contractAccount, nonce), true);
        assertEq(exchange.isSigningWallet(owner, signer), false);
    }

    function test_registerSigningWallet_revertsIfInvalidAccountSignature() public {
        vm.startPrank(sequencer);

        address account = makeAddr("account");
        (, uint256 maliciousAccountKey) = makeAddrAndKey("maliciousAccount");
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");

        string memory message = "message";
        uint64 nonce = 1;

        // signed by malicious account
        bytes memory maliciousAccountSignature = _signTypedDataHash(
            maliciousAccountKey,
            keccak256(abi.encode(exchange.REGISTER_TYPEHASH(), signer, keccak256(abi.encodePacked(message)), 1))
        );

        bytes32 signerStructHash = keccak256(abi.encode(exchange.SIGN_KEY_TYPEHASH(), account));
        bytes memory signerSignature = _signTypedDataHash(signerKey, signerStructHash);

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_InvalidSignature.selector, account));
        exchange.registerSigningWallet(account, signer, message, nonce, maliciousAccountSignature, signerSignature);
    }

    function test_registerSigningWallet_revertsIfInvalidSignerSignature() public {
        vm.startPrank(sequencer);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        address signer = makeAddr("signer");
        (address maliciousSigner, uint256 maliciousSignerKey) = makeAddrAndKey("maliciousSigner");

        string memory message = "message";
        uint64 nonce = 1;

        bytes32 accountStructHash =
            keccak256(abi.encode(exchange.REGISTER_TYPEHASH(), signer, keccak256(abi.encodePacked(message)), nonce));
        bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

        // signed by malicious signer
        bytes32 signerStructHash = keccak256(abi.encode(exchange.SIGN_KEY_TYPEHASH(), account));
        bytes memory maliciousSignerSignature = _signTypedDataHash(maliciousSignerKey, signerStructHash);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.Exchange_InvalidSignerSignature.selector, maliciousSigner, signer)
        );
        exchange.registerSigningWallet(account, signer, message, nonce, accountSignature, maliciousSignerSignature);
    }

    function test_registerSigningWallet_revertsIfNonceUsed() public {
        vm.startPrank(sequencer);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");

        string memory message = "message";
        uint64 nonce = 1;

        bytes32 accountStructHash =
            keccak256(abi.encode(exchange.REGISTER_TYPEHASH(), signer, keccak256(abi.encodePacked(message)), nonce));
        bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

        bytes32 signerStructHash = keccak256(abi.encode(exchange.SIGN_KEY_TYPEHASH(), account));
        bytes memory signerSignature = _signTypedDataHash(signerKey, signerStructHash);

        exchange.registerSigningWallet(account, signer, message, nonce, accountSignature, signerSignature);

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_AddSigningWallet_UsedNonce.selector, account, nonce));
        exchange.registerSigningWallet(account, signer, message, nonce, accountSignature, signerSignature);
    }

    function test_unregisterSigningWallet() public {
        vm.startPrank(sequencer);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");

        // add signing wallet
        {
            string memory message = "message";
            uint64 nonce = 1;

            bytes32 accountStructHash =
                keccak256(abi.encode(exchange.REGISTER_TYPEHASH(), signer, keccak256(abi.encodePacked(message)), nonce));
            bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

            bytes32 signerStructHash = keccak256(abi.encode(exchange.SIGN_KEY_TYPEHASH(), account));
            bytes memory signerSignature = _signTypedDataHash(signerKey, signerStructHash);

            bytes memory addSigningWalletData = abi.encode(
                IExchange.AddSigningWallet(account, signer, message, nonce, accountSignature, signerSignature)
            );
            bytes memory operation =
                _encodeDataToOperation(IExchange.OperationType.AddSigningWallet, addSigningWalletData);
            exchange.processBatch(operation.toArray());
        }

        assertEq(exchange.isSigningWallet(account, signer), true);

        exchange.unregisterSigningWallet(account, signer);
        assertEq(exchange.isSigningWallet(account, signer), false);
    }

    function test_unregisterSigningWallet_revertsIfUnauthorized() public {
        address malicious = makeAddr("malicious");
        bytes32 role = access.SIGNER_OPERATOR_ROLE();

        vm.startPrank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        exchange.unregisterSigningWallet(address(0x12), address(0x34));
    }

    function test_claimCollectedTradingFees() public {
        vm.startPrank(sequencer);

        uint256 collectedTradingFees = 100 * 1e18;
        stdstore.target(address(orderbook)).sig("getTradingFees()").checked_write(collectedTradingFees);
        assertEq(uint128(orderbook.getTradingFees()), collectedTradingFees);
        collateralToken.mint(
            address(exchange), uint128(collectedTradingFees).convertFrom18D(collateralToken.decimals())
        );

        uint256 balanceBefore = collateralToken.balanceOf(feeRecipient);

        vm.expectEmit(address(exchange));
        emit IExchange.ClaimTradingFees(sequencer, collectedTradingFees);
        exchange.claimTradingFees();

        uint256 balanceAfter = collateralToken.balanceOf(feeRecipient);
        uint256 netAmount = uint128(collectedTradingFees).convertFrom18D(collateralToken.decimals());
        assertEq(balanceAfter, balanceBefore + netAmount);
        assertEq(orderbook.getTradingFees(), 0);
        assertEq(exchange.getTradingFees(), 0);
    }

    function test_claimCollectedTradingFees_revertsWhenUnauthorized() public {
        address malicious = makeAddr("malicious");
        bytes32 role = access.GENERAL_ROLE();

        vm.startPrank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        exchange.claimTradingFees();
    }

    function test_claimCollectedSequencerFees() public {
        vm.startPrank(sequencer);

        uint256 exchangeCollectedSequencerFees = 50 * 1e18;
        uint256 orderbookCollectedSequencerFees = 90 * 1e18;
        uint256 totalCollectedFees = exchangeCollectedSequencerFees + orderbookCollectedSequencerFees;

        stdstore.target(address(exchange)).sig("getSequencerFees(address)").with_key(address(collateralToken))
            .checked_write(exchangeCollectedSequencerFees);
        assertEq(uint256(exchange.getSequencerFees(address(collateralToken))), exchangeCollectedSequencerFees);
        stdstore.target(address(orderbook)).sig("getSequencerFees()").checked_write(orderbookCollectedSequencerFees);
        assertEq(uint256(orderbook.getSequencerFees()), orderbookCollectedSequencerFees);
        collateralToken.mint(address(exchange), uint128(totalCollectedFees).convertFrom18D(collateralToken.decimals()));

        uint256 balanceBefore = collateralToken.balanceOf(feeRecipient);

        vm.expectEmit(address(exchange));
        emit IExchange.ClaimSequencerFees(sequencer, address(collateralToken), totalCollectedFees);
        exchange.claimSequencerFees();

        uint256 balanceAfter = collateralToken.balanceOf(feeRecipient);
        assertEq(balanceAfter, balanceBefore + uint128(totalCollectedFees).convertFrom18D(collateralToken.decimals()));
        assertEq(exchange.getSequencerFees(address(collateralToken)), 0);
        assertEq(orderbook.getSequencerFees(), 0);
    }

    function test_claimCollectedSequencerFees_multipleTokens() public {
        ERC20Simple token1 = new ERC20Simple(6);
        ERC20Simple token2 = new ERC20Simple(6);

        uint256 token1CollectedFee = 70 * 1e18;
        uint256 token2CollectedFee = 90 * 1e18;
        uint256 orderbookCollectedSequencerFees = 20 * 1e18;

        stdstore.target(address(exchange)).sig("getSequencerFees(address)").with_key(address(token1)).checked_write(
            token1CollectedFee
        );
        stdstore.target(address(exchange)).sig("getSequencerFees(address)").with_key(address(token2)).checked_write(
            token2CollectedFee
        );

        stdstore.target(address(orderbook)).sig("getSequencerFees()").checked_write(orderbookCollectedSequencerFees);

        vm.startPrank(sequencer);

        exchange.addSupportedToken(address(token1));
        exchange.addSupportedToken(address(token2));

        token1.mint(address(exchange), uint128(token1CollectedFee).convertFrom18D(token1.decimals()));
        token2.mint(address(exchange), uint128(token2CollectedFee).convertFrom18D(token2.decimals()));
        collateralToken.mint(
            address(exchange), uint128(orderbookCollectedSequencerFees).convertFrom18D(collateralToken.decimals())
        );

        uint256 token1BalanceBefore = token1.balanceOf(feeRecipient);
        uint256 token2BalanceBefore = token2.balanceOf(feeRecipient);
        uint256 underlyingTokenBalanceBefore = collateralToken.balanceOf(feeRecipient);

        vm.expectEmit(address(exchange));
        emit IExchange.ClaimSequencerFees(sequencer, address(token1), token1CollectedFee);
        emit IExchange.ClaimSequencerFees(sequencer, address(token2), token2CollectedFee);
        emit IExchange.ClaimSequencerFees(sequencer, address(collateralToken), orderbookCollectedSequencerFees);
        exchange.claimSequencerFees();

        assertEq(
            token1.balanceOf(feeRecipient),
            token1BalanceBefore + uint128(token1CollectedFee).convertFrom18D(token1.decimals())
        );
        assertEq(
            token2.balanceOf(feeRecipient),
            token2BalanceBefore + uint128(token2CollectedFee).convertFrom18D(token2.decimals())
        );
        assertEq(
            collateralToken.balanceOf(feeRecipient),
            underlyingTokenBalanceBefore
                + uint128(orderbookCollectedSequencerFees).convertFrom18D(collateralToken.decimals())
        );
        assertEq(exchange.getSequencerFees(address(token1)), 0);
        assertEq(exchange.getSequencerFees(address(token2)), 0);
        assertEq(exchange.getSequencerFees(address(collateralToken)), 0);
        assertEq(orderbook.getSequencerFees(), 0);
    }

    function test_claimCollectedSequencerFees_revertsWhenUnauthorized() public {
        address malicious = makeAddr("malicious");
        bytes32 role = access.GENERAL_ROLE();

        vm.startPrank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        exchange.claimSequencerFees();
    }

    function test_depositInsuranceFund() public {
        uint128 totalAmount;
        uint8 tokenDecimals = collateralToken.decimals();

        vm.startPrank(sequencer);

        for (uint128 i = 1; i < 5; i++) {
            uint128 amount = i * 1e18;
            _prepareDeposit(sequencer, amount);

            totalAmount += amount;
            vm.expectEmit(address(exchange));
            emit IExchange.DepositInsuranceFund(amount, totalAmount);
            exchange.depositInsuranceFund(amount);

            assertEq(clearingService.getInsuranceFundBalance(), totalAmount);
            assertEq(exchange.getInsuranceFundBalance(), totalAmount);
            assertEq(collateralToken.balanceOf(address(exchange)), totalAmount.convertFrom18D(tokenDecimals));
        }
    }

    function test_depositInsuranceFund_revertsWhenUnauthorized() public {
        address malicious = makeAddr("malicious");
        bytes32 role = access.GENERAL_ROLE();

        vm.startPrank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        exchange.depositInsuranceFund(100);
    }

    function test_depositInsuranceFund_revertsIfZeroAmount() public {
        vm.startPrank(sequencer);
        uint128 zeroAmount = 0;
        vm.expectRevert(Errors.Exchange_ZeroAmount.selector);
        exchange.depositInsuranceFund(zeroAmount);

        uint128 maxZeroScaledAmount = _maxZeroScaledAmount();
        vm.expectRevert(Errors.Exchange_ZeroAmount.selector);
        exchange.depositInsuranceFund(maxZeroScaledAmount);
    }

    function test_withdrawInsuranceFund() public {
        uint128 totalAmount;
        uint8 tokenDecimals = collateralToken.decimals();

        vm.startPrank(sequencer);

        for (uint128 i = 1; i < 5; i++) {
            uint128 amount = i * 1e18;
            _prepareDeposit(sequencer, amount);

            totalAmount += amount;
            emit IExchange.DepositInsuranceFund(amount, totalAmount);
            exchange.depositInsuranceFund(amount);
        }

        for (uint128 i = 1; i < 5; i++) {
            uint128 amount = i * 1e18;
            totalAmount -= amount;
            vm.expectEmit(address(exchange));
            emit IExchange.WithdrawInsuranceFund(amount, totalAmount);
            exchange.withdrawInsuranceFund(amount);

            assertEq(clearingService.getInsuranceFundBalance(), totalAmount);
            assertEq(collateralToken.balanceOf(address(exchange)), totalAmount.convertFrom18D(tokenDecimals));
        }
    }

    function test_withdrawInsuranceFund_revertsWhenUnauthorized() public {
        address malicious = makeAddr("malicious");
        bytes32 role = access.GENERAL_ROLE();

        vm.startPrank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        exchange.withdrawInsuranceFund(100);
    }

    function test_withdrawInsuranceFund_revertsIfZeroAmount() public {
        vm.startPrank(sequencer);
        uint128 zeroAmount = 0;
        vm.expectRevert(Errors.Exchange_ZeroAmount.selector);
        exchange.withdrawInsuranceFund(zeroAmount);

        uint128 maxZeroScaledAmount = _maxZeroScaledAmount();
        vm.expectRevert(Errors.Exchange_ZeroAmount.selector);
        exchange.withdrawInsuranceFund(maxZeroScaledAmount);
    }

    function test_setPauseBatchProcess() public {
        vm.startPrank(sequencer);

        bool pauseBatchProcess = exchange.pauseBatchProcess();

        exchange.setPauseBatchProcess(!pauseBatchProcess);
        assertEq(exchange.pauseBatchProcess(), !pauseBatchProcess);

        exchange.setPauseBatchProcess(pauseBatchProcess);
        assertEq(exchange.pauseBatchProcess(), pauseBatchProcess);
    }

    function test_setPauseBatchProcess_revertsWhenUnauthorized() public {
        address malicious = makeAddr("malicious");
        bytes32 role = access.GENERAL_ROLE();

        vm.startPrank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        exchange.setPauseBatchProcess(true);
    }

    function test_setCanDeposit() public {
        vm.startPrank(sequencer);

        bool canDeposit = exchange.canDeposit();

        exchange.setCanDeposit(!canDeposit);
        assertEq(exchange.canDeposit(), !canDeposit);

        exchange.setCanDeposit(canDeposit);
        assertEq(exchange.canDeposit(), canDeposit);
    }

    function test_enableDeposit_revertsWhenUnauthorized() public {
        address malicious = makeAddr("malicious");
        bytes32 role = access.GENERAL_ROLE();

        vm.startPrank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        exchange.setCanDeposit(true);
    }

    function test_setCanWithdraw() public {
        vm.startPrank(sequencer);

        bool canWithdraw = exchange.canWithdraw();

        exchange.setCanWithdraw(!canWithdraw);
        assertEq(exchange.canWithdraw(), !canWithdraw);

        exchange.setCanWithdraw(canWithdraw);
        assertEq(exchange.canWithdraw(), canWithdraw);
    }

    function test_setCanWithdraw_revertsWhenUnauthorized() public {
        address malicious = makeAddr("malicious");
        bytes32 role = access.GENERAL_ROLE();

        vm.startPrank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        exchange.setCanWithdraw(true);
    }

    function _accountSetup() private {
        (maker, makerKey) = makeAddrAndKey("maker");
        (makerSigner, makerSignerKey) = makeAddrAndKey("makerSigner");
        (taker, takerKey) = makeAddrAndKey("taker");
        (takerSigner, takerSignerKey) = makeAddrAndKey("takerSigner");

        _authorizeSigner(makerKey, makerSignerKey);
        _authorizeSigner(takerKey, takerSignerKey);
    }

    function _authorizeSigner(uint256 accountKey, uint256 signerKey) private {
        address account = vm.addr(accountKey);
        address signer = vm.addr(signerKey);

        string memory message = "message";
        uint64 nonce = 0;
        while (exchange.isRegisterSignerNonceUsed(account, nonce)) {
            nonce++;
        }

        bytes32 accountStructHash =
            keccak256(abi.encode(exchange.REGISTER_TYPEHASH(), signer, keccak256(abi.encodePacked(message)), nonce));
        bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

        bytes32 signerStructHash = keccak256(abi.encode(exchange.SIGN_KEY_TYPEHASH(), account));
        bytes memory signerSignature = _signTypedDataHash(signerKey, signerStructHash);

        bytes memory authorizeSignerData =
            abi.encode(IExchange.AddSigningWallet(account, signer, message, nonce, accountSignature, signerSignature));
        IExchange.OperationType opType = IExchange.OperationType.AddSigningWallet;
        uint32 transactionId = exchange.executedTransactionCounter();
        bytes memory opData = abi.encodePacked(opType, transactionId, authorizeSignerData);

        bytes[] memory data = new bytes[](1);
        data[0] = opData;
        exchange.processBatch(data);
    }

    function _encodeOrder(uint256 signerKey, LibOrder.Order memory order, bool isLiquidated, int128 tradingFee)
        private
        view
        returns (bytes memory)
    {
        address signer = vm.addr(signerKey);
        return _encodeOrderWithSigner(signer, signerKey, order, isLiquidated, tradingFee);
    }

    function _encodeOrderWithSigner(
        address signer,
        uint256 signerKey,
        LibOrder.Order memory order,
        bool isLiquidated,
        int128 tradingFee
    ) private view returns (bytes memory) {
        bytes memory signerSignature = _signTypedDataHash(
            signerKey,
            keccak256(
                abi.encode(
                    exchange.ORDER_TYPEHASH(),
                    order.sender,
                    order.size,
                    order.price,
                    order.nonce,
                    order.productIndex,
                    order.orderSide
                )
            )
        );
        return abi.encodePacked(
            order.sender,
            order.size,
            order.price,
            order.nonce,
            order.productIndex,
            order.orderSide,
            signerSignature,
            signer,
            isLiquidated,
            tradingFee
        );
    }

    function _encodeLiquidatedOrder(LibOrder.Order memory order, bool isLiquidated, int128 tradingFee)
        private
        pure
        returns (bytes memory)
    {
        address mockSigner = address(0);
        bytes memory mockSignature = abi.encodePacked(bytes32(0), bytes32(0), uint8(0));
        return abi.encodePacked(
            order.sender,
            order.size,
            order.price,
            order.nonce,
            order.productIndex,
            order.orderSide,
            mockSignature,
            mockSigner,
            isLiquidated,
            tradingFee
        );
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

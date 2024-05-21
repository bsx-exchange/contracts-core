// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";

import {ERC20MissingReturn} from "../mocks/ERC20MissingReturn.sol";
import {ERC20Simple} from "../mocks/ERC20Simple.sol";
import {Access} from "src/Access.sol";
import {Clearinghouse} from "src/Clearinghouse.sol";
import {Exchange, IERC3009Minimal} from "src/Exchange.sol";
import {Orderbook} from "src/Orderbook.sol";
import {PerpEngine} from "src/PerpEngine.sol";
import {SpotEngine} from "src/SpotEngine.sol";
import {IExchangeEvents} from "src/interfaces/IExchangeEvents.sol";
import {IOrderbook} from "src/interfaces/IOrderbook.sol";
import {Errors} from "src/libraries/Errors.sol";
import {Math} from "src/libraries/Math.sol";
import {OperationType, OrderSide} from "src/types/DataTypes.sol";

library Helper {
    /// @dev add this to be excluded from coverage report
    function test() public {}

    function toArray(bytes memory data) internal pure returns (bytes[] memory) {
        bytes[] memory array = new bytes[](1);
        array[0] = data;
        return array;
    }
}

// solhint-disable max-states-count
contract ExchangeTest is Test {
    using stdStorage for StdStorage;
    using Math for uint128;
    using Helper for bytes;

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

    ERC20Simple private collateralToken = new ERC20Simple();

    Access private access;
    Exchange private exchange;
    Clearinghouse private clearinghouse;
    Orderbook private orderbook;
    PerpEngine private perpEngine;
    SpotEngine private spotEngine;

    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    struct WrappedOrder {
        uint8 productId;
        uint128 size;
        uint128 price;
        bool isLiquidated;
        IOrderbook.Fee fee;
        uint64 makerNonce;
        OrderSide makerSide;
        uint64 takerNonce;
        OrderSide takerSide;
    }

    function setUp() public {
        vm.startPrank(sequencer);

        access = new Access();
        access.initialize(sequencer);

        clearinghouse = new Clearinghouse();
        clearinghouse.initialize(address(access));

        perpEngine = new PerpEngine();
        perpEngine.initialize(address(access));

        spotEngine = new SpotEngine();
        spotEngine.initialize(address(access));

        orderbook = new Orderbook();
        orderbook.initialize(
            address(clearinghouse), address(spotEngine), address(perpEngine), address(access), address(collateralToken)
        );

        exchange = new Exchange();

        access.setExchange(address(exchange));
        access.setClearinghouse(address(clearinghouse));
        access.setOrderbook(address(orderbook));

        exchange.initialize(
            address(access),
            address(clearinghouse),
            address(spotEngine),
            address(perpEngine),
            address(orderbook),
            feeRecipient
        );
        exchange.addSupportedToken(address(collateralToken));

        _accountSetup();

        vm.stopPrank();
    }

    function test_initialize() public view {
        assertEq(address(exchange.access()), address(access));
        assertEq(address(exchange.clearinghouse()), address(clearinghouse));
        assertEq(address(exchange.spotEngine()), address(spotEngine));
        assertEq(address(exchange.perpEngine()), address(perpEngine));
        assertEq(address(exchange.orderbook()), address(orderbook));
        assertEq(exchange.feeRecipient(), feeRecipient);
    }

    function test_initialize_revertsIfSetZeroAddr() public {
        Exchange _exchange = new Exchange();
        address mockAddr = makeAddr("mockAddr");
        address[6] memory addresses = [mockAddr, mockAddr, mockAddr, mockAddr, mockAddr, mockAddr];
        for (uint256 i = 0; i < 5; i++) {
            addresses[i] = address(0);
            vm.expectRevert(Errors.ZeroAddress.selector);
            _exchange.initialize(addresses[0], addresses[1], addresses[2], addresses[3], addresses[4], addresses[5]);
            addresses[i] = mockAddr;
        }
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
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
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

        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        exchange.removeSupportedToken(supportedToken);
    }

    function test_updateFeeRecipient() public {
        vm.startPrank(sequencer);

        address newFeeRecipient = makeAddr("newFeeRecipient");
        exchange.updateFeeRecipient(newFeeRecipient);
        assertEq(exchange.feeRecipient(), newFeeRecipient);
    }

    function test_updateFeeRecipient_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        exchange.updateFeeRecipient(makeAddr("newFeeRecipient"));
    }

    function test_updateFeeRecipient_revertsIfZeroAddr() public {
        vm.startPrank(sequencer);

        vm.expectRevert(Errors.ZeroAddress.selector);
        exchange.updateFeeRecipient(address(0));
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
            emit IExchangeEvents.Deposit(account, address(collateralToken), amount, int128(totalAmount));
            exchange.deposit(address(collateralToken), amount);

            assertEq(spotEngine.getBalance(account, address(collateralToken)), int128(totalAmount));
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
        emit IExchangeEvents.Deposit(account, address(erc20MissingReturn), amount, int128(amount));
        exchange.deposit(address(erc20MissingReturn), amount);

        assertEq(spotEngine.getBalance(account, address(erc20MissingReturn)), int128(amount));
        assertEq(spotEngine.getTotalBalance(address(erc20MissingReturn)), amount);
        assertEq(erc20MissingReturn.balanceOf(address(exchange)), amount.convertFrom18D(tokenDecimals));
    }

    function test_deposit_revertsIfZeroAmount() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        exchange.deposit(address(collateralToken), 0);
    }

    function test_deposit_revertsIfTokenNotSupported() public {
        address notSupportedToken = makeAddr("notSupportedToken");
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_TokenNotSupported.selector, notSupportedToken));
        exchange.deposit(notSupportedToken, 100);
    }

    function test_deposit_revertsIfDisabledDeposit() public {
        vm.prank(sequencer);
        exchange.disableDeposit();

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
            emit IExchangeEvents.Deposit(recipient, address(collateralToken), amount, int128(totalAmount));
            exchange.deposit(recipient, address(collateralToken), amount);

            assertEq(spotEngine.getBalance(recipient, address(collateralToken)), int128(totalAmount));
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
        emit IExchangeEvents.Deposit(recipient, address(erc20MissingReturn), amount, int128(amount));
        exchange.deposit(recipient, address(erc20MissingReturn), amount);

        assertEq(spotEngine.getBalance(recipient, address(erc20MissingReturn)), int128(amount));
        assertEq(spotEngine.getTotalBalance(address(erc20MissingReturn)), amount);
        assertEq(erc20MissingReturn.balanceOf(address(exchange)), amount.convertFrom18D(tokenDecimals));
    }

    function test_deposit_withRecipient_revertsIfZeroAmount() public {
        address recipient = makeAddr("recipient");
        vm.expectRevert(Errors.ZeroAmount.selector);
        exchange.deposit(recipient, address(collateralToken), 0);
    }

    function test_deposit_withRecipient_revertsIfTokenNotSupported() public {
        address recipient = makeAddr("recipient");
        address notSupportedToken = makeAddr("notSupportedToken");
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_TokenNotSupported.selector, notSupportedToken));
        exchange.deposit(recipient, notSupportedToken, 100);
    }

    function test_deposit_withRecipient_revertsIfDisabledDeposit() public {
        address recipient = makeAddr("recipient");

        vm.prank(sequencer);
        exchange.disableDeposit();

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
            emit IExchangeEvents.Deposit(account, address(collateralToken), amount, int128(totalAmount));
            exchange.depositRaw(account, address(collateralToken), rawAmount);

            assertEq(spotEngine.getBalance(account, address(collateralToken)), int128(totalAmount));
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
        emit IExchangeEvents.Deposit(account, address(erc20MissingReturn), amount, int128(amount));
        exchange.depositRaw(account, address(erc20MissingReturn), rawAmount);

        assertEq(spotEngine.getBalance(account, address(erc20MissingReturn)), int128(amount));
        assertEq(spotEngine.getTotalBalance(address(erc20MissingReturn)), amount);

        assertEq(erc20MissingReturn.balanceOf(account), 0);
        assertEq(erc20MissingReturn.balanceOf(address(exchange)), amount.convertFrom18D(tokenDecimals));
    }

    function test_depositRaw_revertsIfZeroAmount() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        exchange.depositRaw(makeAddr("account"), address(collateralToken), 0);
    }

    function test_depositWithAuthorization() public {
        address account = makeAddr("account");
        uint128 totalAmount;
        uint8 tokenDecimals = collateralToken.decimals();
        uint256 mockValidTime = block.timestamp;
        bytes32 mockNonce = keccak256(abi.encode(account, mockValidTime));
        bytes memory mockSignature = abi.encode(account, mockValidTime, mockNonce);

        vm.startPrank(account);

        for (uint128 i = 1; i < 5; i++) {
            uint128 amount = i * 1e18;
            _prepareDeposit(account, amount);

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
            emit IExchangeEvents.Deposit(account, address(collateralToken), amount, int128(totalAmount));
            exchange.depositWithAuthorization(
                address(collateralToken), account, amount, mockValidTime, mockValidTime, mockNonce, mockSignature
            );

            assertEq(spotEngine.getBalance(account, address(collateralToken)), int128(totalAmount));
            assertEq(spotEngine.getTotalBalance(address(collateralToken)), totalAmount);
        }
    }

    function test_depositWithAuthorization_revertsIfZeroAmount() public {
        uint128 zeroAmount = 0;
        vm.expectRevert(Errors.ZeroAmount.selector);
        exchange.depositWithAuthorization(address(collateralToken), makeAddr("account"), zeroAmount, 0, 0, 0, "");
    }

    function test_depositWithAuthorization_revertsIfTokenNotSupported() public {
        address notSupportedToken = makeAddr("notSupportedToken");
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_TokenNotSupported.selector, notSupportedToken));
        exchange.depositWithAuthorization(notSupportedToken, makeAddr("account"), 100, 0, 0, 0, "");
    }

    function test_depositWithAuthorization_revertsIfDisabledDeposit() public {
        vm.prank(sequencer);
        exchange.disableDeposit();

        vm.expectRevert(Errors.Exchange_DisabledDeposit.selector);
        exchange.depositWithAuthorization(address(collateralToken), makeAddr("account"), 100, 0, 0, 0, "");
    }

    function test_depositRaw_revertsIfTokenNotSupported() public {
        address notSupportedToken = makeAddr("notSupportedToken");
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_TokenNotSupported.selector, notSupportedToken));
        exchange.depositRaw(makeAddr("account"), notSupportedToken, 100);
    }

    function test_depositRaw_revertsIfDisabledDeposit() public {
        vm.prank(sequencer);
        exchange.disableDeposit();

        vm.expectRevert(Errors.Exchange_DisabledDeposit.selector);
        exchange.depositRaw(makeAddr("account"), address(collateralToken), 100);
    }

    function test_processBatch_authorizeSigner() public {
        vm.startPrank(sequencer);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");

        string memory message = "message";
        uint64 nonce = 1;

        bytes32 accountStructHash = keccak256(
            abi.encode(exchange.AUTHORIZE_SIGNER_TYPEHASH(), signer, keccak256(abi.encodePacked(message)), nonce)
        );
        bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

        bytes32 signerStructHash = keccak256(abi.encode(exchange.SIGNING_KEY_TYPEHASH(), account));
        bytes memory signerSignature = _signTypedDataHash(signerKey, signerStructHash);

        bytes memory authorizeSignerData =
            abi.encode(account, signer, message, nonce, accountSignature, signerSignature);
        bytes memory operation = _encodeDataToOperation(OperationType.AuthorizeSigner, authorizeSignerData);

        vm.expectEmit(address(exchange));
        emit IExchangeEvents.AuthorizeSigner(account, signer, exchange.executedTransactionCounter());
        exchange.processBatch(operation.toArray());

        assertEq(exchange.authorizedSigners(account, signer), true);
        assertEq(exchange.authorizedSignerNonces(account, nonce), true);
    }

    function test_processBatch_authorizeSigner_revertsIfInvalidAccountSignature() public {
        vm.startPrank(sequencer);

        address account = makeAddr("account");
        (address maliciousAccount, uint256 maliciousAccountKey) = makeAddrAndKey("maliciousAccount");
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");

        string memory message = "message";
        uint64 nonce = 1;

        // signed by malicious account
        bytes memory maliciousAccountSignature = _signTypedDataHash(
            maliciousAccountKey,
            keccak256(abi.encode(exchange.AUTHORIZE_SIGNER_TYPEHASH(), signer, keccak256(abi.encodePacked(message)), 1))
        );

        bytes32 signerStructHash = keccak256(abi.encode(exchange.SIGNING_KEY_TYPEHASH(), account));
        bytes memory signerSignature = _signTypedDataHash(signerKey, signerStructHash);

        bytes memory authorizeSignerData =
            abi.encode(account, signer, message, nonce, maliciousAccountSignature, signerSignature);
        bytes memory operation = _encodeDataToOperation(OperationType.AuthorizeSigner, authorizeSignerData);

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_InvalidSigner.selector, maliciousAccount, account));
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_authorizeSigner_revertsIfInvalidSignerSignature() public {
        vm.startPrank(sequencer);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        address signer = makeAddr("signer");
        (address maliciousSigner, uint256 maliciousSignerKey) = makeAddrAndKey("maliciousSigner");

        string memory message = "message";
        uint64 nonce = 1;

        bytes32 accountStructHash = keccak256(
            abi.encode(exchange.AUTHORIZE_SIGNER_TYPEHASH(), signer, keccak256(abi.encodePacked(message)), nonce)
        );
        bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

        // signed by malicious signer
        bytes32 signerStructHash = keccak256(abi.encode(exchange.SIGNING_KEY_TYPEHASH(), account));
        bytes memory maliciousSignerSignature = _signTypedDataHash(maliciousSignerKey, signerStructHash);

        bytes memory authorizeSignerData =
            abi.encode(account, signer, message, nonce, accountSignature, maliciousSignerSignature);
        bytes memory operation = _encodeDataToOperation(OperationType.AuthorizeSigner, authorizeSignerData);

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_InvalidSigner.selector, maliciousSigner, signer));
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_authorizeSigner_revertsIfNonceUsed() public {
        vm.startPrank(sequencer);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");

        string memory message = "message";
        uint64 nonce = 1;

        bytes32 accountStructHash = keccak256(
            abi.encode(exchange.AUTHORIZE_SIGNER_TYPEHASH(), signer, keccak256(abi.encodePacked(message)), nonce)
        );
        bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

        bytes32 signerStructHash = keccak256(abi.encode(exchange.SIGNING_KEY_TYPEHASH(), account));
        bytes memory signerSignature = _signTypedDataHash(signerKey, signerStructHash);

        bytes memory authorizeSignerData =
            abi.encode(account, signer, message, nonce, accountSignature, signerSignature);
        bytes memory operation = _encodeDataToOperation(OperationType.AuthorizeSigner, authorizeSignerData);

        vm.expectEmit(address(exchange));
        emit IExchangeEvents.AuthorizeSigner(account, signer, exchange.executedTransactionCounter());
        exchange.processBatch(operation.toArray());

        operation = _encodeDataToOperation(OperationType.AuthorizeSigner, authorizeSignerData);
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_AuthorizeSigner_UsedNonce.selector, account, nonce));
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
        generalOrder.makerSide = OrderSide.LONG;
        generalOrder.takerSide = OrderSide.SHORT;
        generalOrder.fee = IOrderbook.Fee({maker: 2 * 1e12, taker: 3 * 1e12, sequencer: 5 * 1e12, referralRebate: 0});

        bytes memory operation;

        // avoid "Stack too deep"
        {
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                generalOrder.productId,
                IOrderbook.Order({
                    account: maker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.makerNonce,
                    orderSide: generalOrder.makerSide,
                    orderHash: 0
                }),
                generalOrder.isLiquidated,
                generalOrder.fee.maker
            );
            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                generalOrder.productId,
                IOrderbook.Order({
                    account: taker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.takerNonce,
                    orderSide: generalOrder.takerSide,
                    orderHash: 0
                }),
                generalOrder.isLiquidated,
                generalOrder.fee.taker
            );

            operation = _encodeDataToOperation(
                OperationType.MatchOrders,
                abi.encodePacked(makerEncodedOrder, takerEncodedOrder, generalOrder.fee.sequencer)
            );
        }

        vm.expectEmit();
        emit IOrderbook.OrderMatched(
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

        _authorizeSigner(makerKey, makerSignerKey);
        _authorizeSigner(takerKey, takerSignerKey);

        uint8 productId = 1;

        bool[2] memory isLiquidated = [true, false];
        for (uint256 i = 0; i < 2; i++) {
            for (uint256 j = 0; j < 2; j++) {
                bool makerIsLiquidated = isLiquidated[i];
                bool takerIsLiquidated = isLiquidated[j];

                if (makerIsLiquidated == false && takerIsLiquidated == false) {
                    continue;
                }

                bytes memory makerEncodedOrder = _encodeOrder(
                    makerSignerKey,
                    productId,
                    IOrderbook.Order({
                        account: maker,
                        size: 0,
                        price: 0,
                        nonce: 50,
                        orderSide: OrderSide.LONG,
                        orderHash: 0
                    }),
                    makerIsLiquidated,
                    0
                );

                bytes memory takerEncodedOrder = _encodeOrder(
                    takerSignerKey,
                    productId,
                    IOrderbook.Order({
                        account: taker,
                        size: 0,
                        price: 0,
                        nonce: 60,
                        orderSide: OrderSide.SHORT,
                        orderHash: 0
                    }),
                    takerIsLiquidated,
                    0
                );

                uint128 sequencerFee = 0;
                bytes memory operation = _encodeDataToOperation(
                    OperationType.MatchOrders, abi.encodePacked(makerEncodedOrder, takerEncodedOrder, sequencerFee)
                );

                vm.expectRevert(Errors.Exchange_LiquidatedOrder.selector);
                exchange.processBatch(operation.toArray());
            }
        }
    }

    function test_processBatch_matchOrders_revertsIfProductIdMismatch() public {
        vm.startPrank(sequencer);

        bool isLiquidated = false;
        uint8 makerProductId = 1;
        bytes memory makerEncodedOrder = _encodeOrder(
            makerSignerKey,
            makerProductId,
            IOrderbook.Order({account: maker, size: 0, price: 0, nonce: 66, orderSide: OrderSide.LONG, orderHash: 0}),
            isLiquidated,
            0
        );

        uint8 takerProductId = 2;
        bytes memory takerEncodedOrder = _encodeOrder(
            takerSignerKey,
            takerProductId,
            IOrderbook.Order({account: taker, size: 0, price: 0, nonce: 77, orderSide: OrderSide.SHORT, orderHash: 0}),
            isLiquidated,
            0
        );

        uint128 sequencerFee = 0;
        bytes memory operation = _encodeDataToOperation(
            OperationType.MatchOrders, abi.encodePacked(makerEncodedOrder, takerEncodedOrder, sequencerFee)
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_ProductIdMismatch.selector));
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
                productId,
                IOrderbook.Order({
                    account: maker,
                    size: 10,
                    price: 20,
                    nonce: 66,
                    orderSide: OrderSide.LONG,
                    orderHash: 0
                }),
                isLiquidated,
                0
            );
            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                productId,
                IOrderbook.Order({
                    account: taker,
                    size: 10,
                    price: 20,
                    nonce: 77,
                    orderSide: OrderSide.SHORT,
                    orderHash: 0
                }),
                isLiquidated,
                0
            );

            address account = accounts[i];
            if (account == maker) {
                makerEncodedOrder = _encodeOrder(
                    maliciousSignerKey,
                    productId,
                    IOrderbook.Order({
                        account: maker,
                        size: 0,
                        price: 0,
                        nonce: 66,
                        orderSide: OrderSide.LONG,
                        orderHash: 0
                    }),
                    isLiquidated,
                    0
                );
            } else {
                takerEncodedOrder = _encodeOrder(
                    maliciousSignerKey,
                    productId,
                    IOrderbook.Order({
                        account: taker,
                        size: 0,
                        price: 0,
                        nonce: 77,
                        orderSide: OrderSide.SHORT,
                        orderHash: 0
                    }),
                    isLiquidated,
                    0
                );
            }

            uint128 sequencerFee = 0;
            bytes memory operation = _encodeDataToOperation(
                OperationType.MatchOrders, abi.encodePacked(makerEncodedOrder, takerEncodedOrder, sequencerFee)
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
                productId,
                IOrderbook.Order({
                    account: maker,
                    size: 10,
                    price: 20,
                    nonce: 77,
                    orderSide: OrderSide.LONG,
                    orderHash: 0
                }),
                isLiquidated,
                0
            );
            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                productId,
                IOrderbook.Order({
                    account: taker,
                    size: 10,
                    price: 20,
                    nonce: 77,
                    orderSide: OrderSide.SHORT,
                    orderHash: 0
                }),
                isLiquidated,
                0
            );

            address expectedSigner = signers[i];
            if (expectedSigner == makerSigner) {
                makerEncodedOrder = _encodeOrderWithSigner(
                    makerSigner,
                    maliciousSignerKey,
                    productId,
                    IOrderbook.Order({
                        account: maker,
                        size: 0,
                        price: 0,
                        nonce: 33,
                        orderSide: OrderSide.LONG,
                        orderHash: 0
                    }),
                    isLiquidated,
                    0
                );
            } else {
                takerEncodedOrder = _encodeOrderWithSigner(
                    takerSigner,
                    maliciousSignerKey,
                    productId,
                    IOrderbook.Order({
                        account: taker,
                        size: 0,
                        price: 0,
                        nonce: 88,
                        orderSide: OrderSide.SHORT,
                        orderHash: 0
                    }),
                    isLiquidated,
                    0
                );
            }

            bytes memory operation = _encodeDataToOperation(
                OperationType.MatchOrders, abi.encodePacked(makerEncodedOrder, takerEncodedOrder, uint128(0))
            );

            vm.expectRevert(
                abi.encodeWithSelector(Errors.Exchange_InvalidSigner.selector, maliciousSigner, expectedSigner)
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
        generalOrder.makerSide = OrderSide.SHORT;
        generalOrder.takerSide = OrderSide.LONG;
        generalOrder.fee = IOrderbook.Fee({maker: 2 * 1e12, taker: 3 * 1e12, sequencer: 5 * 1e12, referralRebate: 0});
        bytes memory operation;

        // avoid "Stack too deep"
        {
            bool makerIsLiquidated = false;
            bytes memory makerEncodedOrder = _encodeOrder(
                makerSignerKey,
                generalOrder.productId,
                IOrderbook.Order({
                    account: maker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.makerNonce,
                    orderSide: generalOrder.makerSide,
                    orderHash: 0
                }),
                makerIsLiquidated,
                generalOrder.fee.maker
            );
            bytes memory takerEncodedOrder = _encodeOrder(
                takerSignerKey,
                generalOrder.productId,
                IOrderbook.Order({
                    account: taker,
                    size: generalOrder.size,
                    price: generalOrder.price,
                    nonce: generalOrder.takerNonce,
                    orderSide: generalOrder.takerSide,
                    orderHash: 0
                }),
                generalOrder.isLiquidated,
                generalOrder.fee.taker
            );

            operation = _encodeDataToOperation(
                OperationType.MatchLiquidatedOrders,
                abi.encodePacked(makerEncodedOrder, takerEncodedOrder, generalOrder.fee.sequencer)
            );
        }

        vm.expectEmit();
        emit IOrderbook.OrderMatched(
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

    function test_processBatch_matchLiquidatedOrders_revertsIfNotLiquidatedOrders() public {
        vm.startPrank(sequencer);

        uint8 productId = 1;

        bool[2] memory isLiquidated = [true, false];
        for (uint256 i = 0; i < 2; i++) {
            for (uint256 j = 0; j < 2; j++) {
                bool makerIsLiquidated = isLiquidated[i];
                bool takerIsLiquidated = isLiquidated[j];

                if (makerIsLiquidated == false && takerIsLiquidated == true) {
                    continue;
                }

                bytes memory makerEncodedOrder = _encodeOrder(
                    makerSignerKey,
                    productId,
                    IOrderbook.Order({
                        account: maker,
                        size: 0,
                        price: 0,
                        nonce: 50,
                        orderSide: OrderSide.LONG,
                        orderHash: 0
                    }),
                    makerIsLiquidated,
                    0
                );

                bytes memory takerEncodedOrder = _encodeOrder(
                    takerSignerKey,
                    productId,
                    IOrderbook.Order({
                        account: taker,
                        size: 0,
                        price: 0,
                        nonce: 60,
                        orderSide: OrderSide.SHORT,
                        orderHash: 0
                    }),
                    takerIsLiquidated,
                    0
                );

                uint128 sequencerFee = 0;
                bytes memory operation = _encodeDataToOperation(
                    OperationType.MatchLiquidatedOrders,
                    abi.encodePacked(makerEncodedOrder, takerEncodedOrder, sequencerFee)
                );

                if (makerIsLiquidated) {
                    vm.expectRevert(Errors.Exchange_LiquidatedOrder.selector);
                    exchange.processBatch(operation.toArray());
                } else {
                    vm.expectRevert(Errors.Exchange_NotLiquidatedOrder.selector);
                    exchange.processBatch(operation.toArray());
                }
            }
        }
    }

    function test_processBatch_matchLiquidatedOrders_revertsIfProductIdMismatch() public {
        vm.startPrank(sequencer);

        bool isLiquidated = true;

        uint8 makerProductId = 1;
        bool makerIsLiquidated = false;
        bytes memory makerEncodedOrder = _encodeOrder(
            makerSignerKey,
            makerProductId,
            IOrderbook.Order({account: maker, size: 0, price: 0, nonce: 66, orderSide: OrderSide.LONG, orderHash: 0}),
            makerIsLiquidated,
            0
        );

        uint8 takerProductId = 2;
        bytes memory takerEncodedOrder = _encodeLiquidatedOrder(
            takerProductId,
            IOrderbook.Order({account: taker, size: 0, price: 0, nonce: 77, orderSide: OrderSide.SHORT, orderHash: 0}),
            isLiquidated,
            0
        );

        uint128 sequencerFee = 0;
        bytes memory operation = _encodeDataToOperation(
            OperationType.MatchLiquidatedOrders, abi.encodePacked(makerEncodedOrder, takerEncodedOrder, sequencerFee)
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_ProductIdMismatch.selector));
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
            productId,
            IOrderbook.Order({account: maker, size: 0, price: 0, nonce: 66, orderSide: OrderSide.LONG, orderHash: 0}),
            makerIsLiquidated,
            0
        );
        bytes memory takerEncodedOrder = _encodeLiquidatedOrder(
            productId,
            IOrderbook.Order({account: taker, size: 0, price: 0, nonce: 77, orderSide: OrderSide.SHORT, orderHash: 0}),
            isLiquidated,
            0
        );

        uint128 sequencerFee = 0;
        bytes memory operation = _encodeDataToOperation(
            OperationType.MatchLiquidatedOrders, abi.encodePacked(makerEncodedOrder, takerEncodedOrder, sequencerFee)
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
            productId,
            IOrderbook.Order({account: maker, size: 0, price: 0, nonce: 77, orderSide: OrderSide.LONG, orderHash: 0}),
            makerIsLiquidated,
            0
        );
        bytes memory takerEncodedOrder = _encodeLiquidatedOrder(
            productId,
            IOrderbook.Order({account: taker, size: 0, price: 0, nonce: 77, orderSide: OrderSide.SHORT, orderHash: 0}),
            isLiquidated,
            0
        );

        bytes memory operation = _encodeDataToOperation(
            OperationType.MatchLiquidatedOrders, abi.encodePacked(makerEncodedOrder, takerEncodedOrder, uint128(0))
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_InvalidSigner.selector, maliciousSigner, makerSigner));
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_withdraw() public {
        collateralToken.mint(address(exchange), type(uint128).max);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        uint128 amount = 5 * 1e18;

        {
            vm.startPrank(address(exchange));
            spotEngine.updateAccount(account, address(collateralToken), int128(amount));
            spotEngine.increaseTotalBalance(address(collateralToken), amount);
            vm.stopPrank();
        }

        int256 accountBalanceStateBefore = spotEngine.getBalance(account, address(collateralToken));
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
            OperationType.Withdraw, abi.encode(account, address(collateralToken), amount, nonce, signature, withdrawFee)
        );

        vm.expectEmit(address(exchange));
        emit IExchangeEvents.Withdraw(account, address(collateralToken), amount, withdrawFee, 0);
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(spotEngine.getBalance(account, address(collateralToken)), accountBalanceStateBefore - int128(amount));
        assertEq(spotEngine.getTotalBalance(address(collateralToken)), totalBalanceStateBefore - amount);

        uint8 tokenDecimals = collateralToken.decimals();
        uint128 netAmount = amount - withdrawFee;
        assertEq(collateralToken.balanceOf(account), accountBalanceBefore + netAmount.convertFrom18D(tokenDecimals));
        assertEq(
            collateralToken.balanceOf(address(exchange)),
            exchangeBalanceBefore - netAmount.convertFrom18D(tokenDecimals)
        );
    }

    function test_processBatch_withdraw_revertsIfDisabledWithdraw() public {
        vm.startPrank(sequencer);
        exchange.disableWithdraw();

        address account = makeAddr("account");
        bytes memory operation =
            _encodeDataToOperation(OperationType.Withdraw, abi.encode(account, address(collateralToken), 100, 0, "", 0));
        vm.expectRevert(Errors.Exchange_DisabledWithdraw.selector);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_withdraw_revertsIfExceededMaxFee() public {
        vm.startPrank(sequencer);

        address account = makeAddr("account");
        uint128 maxFee = exchange.MAX_WITHDRAW_FEE() + 1;
        bytes memory operation = _encodeDataToOperation(
            OperationType.Withdraw, abi.encode(account, address(collateralToken), 100, 0, "", maxFee)
        );
        vm.expectRevert(Errors.Exchange_ExceededMaxWithdrawFee.selector);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_withdraw_revertsIfNonceUsed() public {
        collateralToken.mint(address(exchange), type(uint128).max);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        uint128 amount = 5 * 1e18;

        {
            vm.startPrank(address(exchange));
            spotEngine.updateAccount(account, address(collateralToken), int128(amount));
            spotEngine.increaseTotalBalance(address(collateralToken), amount);
            vm.stopPrank();
        }

        vm.startPrank(sequencer);

        uint64 nonce = 1;
        bytes memory signature = _signTypedDataHash(
            accountKey,
            keccak256(abi.encode(exchange.WITHDRAW_TYPEHASH(), account, address(collateralToken), amount, nonce))
        );
        bytes memory operation = _encodeDataToOperation(
            OperationType.Withdraw, abi.encode(account, address(collateralToken), amount, nonce, signature, 0)
        );
        exchange.processBatch(operation.toArray());

        operation = _encodeDataToOperation(
            OperationType.Withdraw, abi.encode(account, address(collateralToken), amount, nonce, signature, 0)
        );
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_Withdraw_UsedNonce.selector, account, nonce));
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_withdraw_revertsIfWithdrawAmountExceedBalance() public {
        collateralToken.mint(address(exchange), type(uint128).max);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        uint128 balance = 5 * 1e18;

        {
            vm.startPrank(address(exchange));
            spotEngine.updateAccount(account, address(collateralToken), int128(balance));
            spotEngine.increaseTotalBalance(address(collateralToken), balance);
            vm.stopPrank();
        }

        vm.startPrank(sequencer);

        uint64 nonce = 1;
        uint128 withdrawAmount = balance + 1;
        bytes memory signature = _signTypedDataHash(
            accountKey,
            keccak256(
                abi.encode(exchange.WITHDRAW_TYPEHASH(), account, address(collateralToken), withdrawAmount, nonce)
            )
        );
        bytes memory data = abi.encode(account, address(collateralToken), withdrawAmount, nonce, signature, 0);
        bytes memory operation = _encodeDataToOperation(OperationType.Withdraw, data);
        vm.expectEmit(address(exchange));
        emit IExchangeEvents.WithdrawRejected(account, address(collateralToken), withdrawAmount, int128(balance));
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_withdraw_revertsIfWithdrawAmountTooSmall() public {
        collateralToken.mint(address(exchange), type(uint128).max);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        uint128 balance = 5 * 1e18;

        {
            vm.startPrank(address(exchange));
            spotEngine.updateAccount(account, address(collateralToken), int128(balance));
            spotEngine.increaseTotalBalance(address(collateralToken), balance);
            vm.stopPrank();
        }

        vm.startPrank(sequencer);

        uint64 nonce = 1;
        uint128 withdrawAmount = exchange.MIN_WITHDRAW_AMOUNT() - 1;
        bytes memory signature = _signTypedDataHash(
            accountKey,
            keccak256(
                abi.encode(exchange.WITHDRAW_TYPEHASH(), account, address(collateralToken), withdrawAmount, nonce)
            )
        );
        bytes memory data = abi.encode(account, address(collateralToken), withdrawAmount, nonce, signature, 0);
        bytes memory operation = _encodeDataToOperation(OperationType.Withdraw, data);
        vm.expectEmit(address(exchange));
        emit IExchangeEvents.WithdrawRejected(account, address(collateralToken), withdrawAmount, int128(balance));
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_coverLossWithInsuranceFund() public {
        address account = makeAddr("account");
        int128 loss = -5 * 1e18;
        uint128 insuranceFund = 100 * 1e18;

        {
            vm.startPrank(address(exchange));
            spotEngine.updateAccount(account, address(collateralToken), loss);
            clearinghouse.depositInsuranceFund(insuranceFund);
            vm.stopPrank();
        }

        bytes memory operation = _encodeDataToOperation(
            OperationType.CoverLossWithInsuranceFund, abi.encode(account, address(collateralToken))
        );

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(spotEngine.getBalance(account, address(collateralToken)), 0);
        assertEq(clearinghouse.getInsuranceFund(), insuranceFund - uint128(-loss));
    }

    function test_processBatch_cumulateFundingRate() public {
        vm.startPrank(sequencer);

        uint8 productId = 2;
        int128 premiumRate = -15 * 1e16;
        uint256 fundingRateId = exchange.lastFundingRateId() + 1;
        bytes memory operation =
            _encodeDataToOperation(OperationType.CumulateFundingRate, abi.encode(productId, premiumRate, fundingRateId));

        int128 cumulativeFundingRate = perpEngine.getMarketMetrics(productId).cumulativeFundingRate;
        cumulativeFundingRate += premiumRate;
        vm.expectEmit(address(exchange));
        emit IExchangeEvents.CumulateFundingRate(
            productId, premiumRate, cumulativeFundingRate, exchange.executedTransactionCounter()
        );
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_cumulateFundingRate_revertsIfInvalidFundingRateId() public {
        vm.startPrank(sequencer);

        uint8 productId = 2;
        int128 premiumRate = -15 * 1e16;

        uint256 fundingRateId = 500;
        bytes memory operation =
            _encodeDataToOperation(OperationType.CumulateFundingRate, abi.encode(productId, premiumRate, fundingRateId));
        exchange.processBatch(operation.toArray());

        for (uint256 i = 0; i < 5; i++) {
            uint256 invalidFundingRateId = fundingRateId - i;
            bytes memory op = _encodeDataToOperation(
                OperationType.CumulateFundingRate, abi.encode(productId, premiumRate, invalidFundingRateId)
            );

            vm.expectRevert(
                abi.encodeWithSelector(
                    Errors.Exchange_InvalidFundingRateId.selector, invalidFundingRateId, fundingRateId
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

    function test_processBatch_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        bytes[] memory data = new bytes[](0);
        exchange.processBatch(data);
    }

    function test_processBatch_revertsWhenPaused() public {
        vm.startPrank(sequencer);
        exchange.pauseProcessBatch();

        vm.expectRevert(Errors.Exchange_PausedProcessBatch.selector);
        bytes[] memory data = new bytes[](0);
        exchange.processBatch(data);
    }

    function test_processBatch_revertsIfInvalidOperationType() public {
        vm.startPrank(sequencer);

        bytes memory invalidOperation = _encodeDataToOperation(OperationType.Invalid, abi.encodePacked());

        vm.expectRevert(Errors.Exchange_InvalidOperation.selector);
        exchange.processBatch(invalidOperation.toArray());
    }

    function test_claimCollectedTradingFees() public {
        vm.startPrank(sequencer);

        uint256 collectedTradingFees = 100 * 1e18;
        stdstore.target(address(orderbook)).sig("getCollectedTradingFees()").checked_write(collectedTradingFees);
        assertEq(orderbook.getCollectedTradingFees(), collectedTradingFees);
        collateralToken.mint(
            address(exchange), uint128(collectedTradingFees).convertFrom18D(collateralToken.decimals())
        );

        uint256 balanceBefore = collateralToken.balanceOf(feeRecipient);

        vm.expectEmit(address(exchange));
        emit IExchangeEvents.ClaimCollectedTradingFees(sequencer, collectedTradingFees);
        exchange.claimCollectedTradingFees();

        uint256 balanceAfter = collateralToken.balanceOf(feeRecipient);
        uint256 netAmount = uint128(collectedTradingFees).convertFrom18D(collateralToken.decimals());
        assertEq(balanceAfter, balanceBefore + netAmount);
        assertEq(orderbook.getCollectedTradingFees(), 0);
    }

    function test_claimCollectedTradingFees_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        exchange.claimCollectedTradingFees();
    }

    function test_claimCollectedSequencerFees() public {
        vm.startPrank(sequencer);

        uint256 exchangeCollectedSequencerFees = 50 * 1e18;
        uint256 orderbookCollectedSequencerFees = 90 * 1e18;
        uint256 totalCollectedFees = exchangeCollectedSequencerFees + orderbookCollectedSequencerFees;

        stdstore.target(address(exchange)).sig("getCollectedSequencerFees()").checked_write(
            exchangeCollectedSequencerFees
        );
        assertEq(exchange.getCollectedSequencerFees(), exchangeCollectedSequencerFees);
        stdstore.target(address(orderbook)).sig("getCollectedSequencerFees()").checked_write(
            orderbookCollectedSequencerFees
        );
        assertEq(orderbook.getCollectedSequencerFees(), orderbookCollectedSequencerFees);
        collateralToken.mint(address(exchange), uint128(totalCollectedFees).convertFrom18D(collateralToken.decimals()));

        uint256 balanceBefore = collateralToken.balanceOf(feeRecipient);

        vm.expectEmit(address(exchange));
        emit IExchangeEvents.ClaimCollectedSequencerFees(sequencer, totalCollectedFees);
        exchange.claimCollectedSequencerFees();

        uint256 balanceAfter = collateralToken.balanceOf(feeRecipient);
        assertEq(balanceAfter, balanceBefore + uint128(totalCollectedFees).convertFrom18D(collateralToken.decimals()));
        assertEq(exchange.getCollectedSequencerFees(), 0);
        assertEq(orderbook.getCollectedSequencerFees(), 0);
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
            emit IExchangeEvents.DepositInsuranceFund(amount);
            exchange.depositInsuranceFund(amount);

            assertEq(clearinghouse.getInsuranceFund(), totalAmount);
            assertEq(collateralToken.balanceOf(address(exchange)), totalAmount.convertFrom18D(tokenDecimals));
        }
    }

    function test_depositInsuranceFund_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        exchange.depositInsuranceFund(100);
    }

    function test_withdrawInsuranceFund() public {
        uint128 totalAmount;
        uint8 tokenDecimals = collateralToken.decimals();

        vm.startPrank(sequencer);

        for (uint128 i = 1; i < 5; i++) {
            uint128 amount = i * 1e18;
            _prepareDeposit(sequencer, amount);

            totalAmount += amount;
            emit IExchangeEvents.DepositInsuranceFund(amount);
            exchange.depositInsuranceFund(amount);
        }

        for (uint128 i = 1; i < 5; i++) {
            uint128 amount = i * 1e18;
            totalAmount -= amount;
            vm.expectEmit(address(exchange));
            emit IExchangeEvents.WithdrawInsuranceFund(amount);
            exchange.withdrawInsuranceFund(amount);

            assertEq(clearinghouse.getInsuranceFund(), totalAmount);
            assertEq(collateralToken.balanceOf(address(exchange)), totalAmount.convertFrom18D(tokenDecimals));
        }
    }

    function test_withdrawInsuranceFund_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        exchange.withdrawInsuranceFund(100);
    }

    function test_pauseProcessBatch() public {
        vm.startPrank(sequencer);
        exchange.pauseProcessBatch();
        assertEq(exchange.pausedBatchProcess(), true);
    }

    function test_pauseProcessBatch_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        exchange.pauseProcessBatch();
    }

    function test_unpauseProcessBatch() public {
        vm.startPrank(sequencer);
        exchange.pauseProcessBatch();
        assertEq(exchange.pausedBatchProcess(), true);

        exchange.unpauseProcessBatch();
        assertEq(exchange.pausedBatchProcess(), false);
    }

    function test_unpauseProcessBatch_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        exchange.unpauseProcessBatch();
    }

    function test_enableDeposit() public {
        vm.startPrank(sequencer);
        exchange.enableDeposit();
        assertEq(exchange.canDeposit(), true);
    }

    function test_enableDeposit_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        exchange.enableDeposit();
    }

    function test_disableDeposit() public {
        vm.startPrank(sequencer);
        exchange.enableDeposit();
        assertEq(exchange.canDeposit(), true);

        exchange.disableDeposit();
        assertEq(exchange.canDeposit(), false);
    }

    function test_disableDeposit_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        exchange.disableDeposit();
    }

    function test_enableWithdraw() public {
        vm.startPrank(sequencer);
        exchange.enableWithdraw();
        assertEq(exchange.canWithdraw(), true);
    }

    function test_enableWithdraw_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        exchange.enableWithdraw();
    }

    function test_disableWithdraw() public {
        vm.startPrank(sequencer);
        exchange.disableWithdraw();
        assertEq(exchange.canWithdraw(), false);
    }

    function test_disableWithdraw_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        exchange.disableWithdraw();
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
        while (exchange.authorizedSignerNonces(account, nonce)) {
            nonce++;
        }

        bytes32 accountStructHash = keccak256(
            abi.encode(exchange.AUTHORIZE_SIGNER_TYPEHASH(), signer, keccak256(abi.encodePacked(message)), nonce)
        );
        bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

        bytes32 signerStructHash = keccak256(abi.encode(exchange.SIGNING_KEY_TYPEHASH(), account));
        bytes memory signerSignature = _signTypedDataHash(signerKey, signerStructHash);

        bytes memory authorizeSignerData =
            abi.encode(account, signer, message, nonce, accountSignature, signerSignature);
        OperationType opType = OperationType.AuthorizeSigner;
        uint32 transactionId = exchange.executedTransactionCounter();
        bytes memory opData = abi.encodePacked(opType, transactionId, authorizeSignerData);

        bytes[] memory data = new bytes[](1);
        data[0] = opData;
        exchange.processBatch(data);
    }

    function _encodeOrderWithSigner(
        address signer,
        uint256 signerKey,
        uint8 productId,
        IOrderbook.Order memory order,
        bool isLiquidated,
        uint128 tradingFee
    ) private view returns (bytes memory) {
        bytes memory signerSignature = _signTypedDataHash(
            signerKey,
            keccak256(
                abi.encode(
                    exchange.ORDER_TYPEHASH(),
                    order.account,
                    order.size,
                    order.price,
                    order.nonce,
                    productId,
                    order.orderSide
                )
            )
        );
        return abi.encodePacked(
            order.account,
            order.size,
            order.price,
            order.nonce,
            productId,
            order.orderSide,
            signerSignature,
            signer,
            isLiquidated,
            tradingFee
        );
    }

    function _encodeOrder(
        uint256 signerKey,
        uint8 productId,
        IOrderbook.Order memory order,
        bool isLiquidated,
        uint128 tradingFee
    ) private view returns (bytes memory) {
        address signer = vm.addr(signerKey);
        return _encodeOrderWithSigner(signer, signerKey, productId, order, isLiquidated, tradingFee);
    }

    function _encodeLiquidatedOrder(
        uint8 productId,
        IOrderbook.Order memory order,
        bool isLiquidated,
        uint128 tradingFee
    ) private pure returns (bytes memory) {
        address mockSigner = address(0);
        bytes memory mockSignature = abi.encodePacked(bytes32(0), bytes32(0), uint8(0));
        return abi.encodePacked(
            order.account,
            order.size,
            order.price,
            order.nonce,
            productId,
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

    function _encodeDataToOperation(
        OperationType operationType,
        bytes memory data
    ) private view returns (bytes memory) {
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
}

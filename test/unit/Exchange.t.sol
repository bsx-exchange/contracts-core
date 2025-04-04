// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {Helper} from "../Helper.sol";
import {ERC1271} from "../mock/ERC1271.sol";
import {ERC20Simple} from "../mock/ERC20Simple.sol";
import {UniversalSigValidator} from "../mock/UniversalSigValidator.sol";

import {ClearingService, IClearingService} from "contracts/exchange/ClearingService.sol";
import {Exchange, IExchange} from "contracts/exchange/Exchange.sol";
import {IOrderBook, OrderBook} from "contracts/exchange/OrderBook.sol";
import {Perp} from "contracts/exchange/Perp.sol";
import {Spot} from "contracts/exchange/Spot.sol";
import {VaultManager} from "contracts/exchange/VaultManager.sol";
import {Access} from "contracts/exchange/access/Access.sol";
import {Errors} from "contracts/exchange/lib/Errors.sol";
import {
    BSX_TOKEN,
    NATIVE_ETH,
    UNIVERSAL_SIG_VALIDATOR,
    USDC_TOKEN,
    USDC_TOKEN
} from "contracts/exchange/share/Constants.sol";

// solhint-disable max-states-count
contract ExchangeTest is Test {
    using stdStorage for StdStorage;
    using Helper for bytes;
    using Helper for uint128;

    address private sequencer = makeAddr("sequencer");
    address private feeRecipient = makeAddr("feeRecipient");

    ERC20Simple private collateralToken = ERC20Simple(USDC_TOKEN);

    Access private access;
    Exchange private exchange;
    ClearingService private clearingService;
    OrderBook private orderbook;
    Perp private perpEngine;
    Spot private spotEngine;
    VaultManager private vaultManager;

    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant REGISTER_TYPEHASH = keccak256("Register(address key,string message,uint64 nonce)");
    bytes32 private constant REGISTER_SUBACCOUNT_SIGNER_TYPEHASH =
        keccak256("RegisterSubaccountSigner(address main,address subaccount,string message,uint64 nonce)");
    bytes32 private constant SIGN_KEY_TYPEHASH = keccak256("SignKey(address account)");

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
        vm.etch(address(UNIVERSAL_SIG_VALIDATOR), code);

        access.setExchange(address(exchange));
        access.setClearingService(address(clearingService));
        access.setOrderBook(address(orderbook));
        access.setSpotEngine(address(spotEngine));

        vaultManager = new VaultManager();
        stdstore.target(address(vaultManager)).sig("access()").checked_write(address(access));
        access.setVaultManager(address(vaultManager));

        stdstore.target(address(exchange)).sig("access()").checked_write(address(access));
        stdstore.target(address(exchange)).sig("book()").checked_write(address(orderbook));
        stdstore.target(address(exchange)).sig("clearingService()").checked_write(address(clearingService));
        stdstore.target(address(exchange)).sig("spotEngine()").checked_write(address(spotEngine));
        stdstore.target(address(exchange)).sig("perpEngine()").checked_write(address(perpEngine));
        exchange.updateFeeRecipientAddress(feeRecipient);
        exchange.setCanDeposit(true);
        exchange.setCanWithdraw(true);

        deployCodeTo("ERC20Simple.sol", abi.encode(6), USDC_TOKEN);
        exchange.addSupportedToken(USDC_TOKEN);

        deployCodeTo("ERC20Simple.sol", abi.encode(18), BSX_TOKEN);
        exchange.addSupportedToken(BSX_TOKEN);

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

    function test_processBatch_addSigningWallet_EOA() public {
        vm.startPrank(sequencer);

        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");

        string memory message = "message";
        uint64 nonce = 1;

        bytes32 accountStructHash =
            keccak256(abi.encode(REGISTER_TYPEHASH, signer, keccak256(abi.encodePacked(message)), nonce));
        bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

        bytes32 signerStructHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, account));
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
            keccak256(abi.encode(REGISTER_TYPEHASH, signer, keccak256(abi.encodePacked(message)), nonce));
        bytes memory ownerSignature = _signTypedDataHash(ownerKey, contractAccountStructHash);

        bytes32 signerStructHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, contractAccount));
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
            keccak256(abi.encode(REGISTER_TYPEHASH, signer, keccak256(abi.encodePacked(message)), 1))
        );

        bytes32 signerStructHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, account));
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
            keccak256(abi.encode(REGISTER_TYPEHASH, signer, keccak256(abi.encodePacked(message)), nonce));
        bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

        // signed by malicious signer
        bytes32 signerStructHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, account));
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
            keccak256(abi.encode(REGISTER_TYPEHASH, signer, keccak256(abi.encodePacked(message)), nonce));
        bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

        bytes32 signerStructHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, account));
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

    function test_processBatch_coverLossWithInsuranceFund() public {
        address account = makeAddr("account");
        uint128 loss = 5 * 1e18;
        uint128 insuranceFundUsdc = 100 * 1e18;

        vm.startPrank(address(exchange));
        spotEngine.updateBalance(account, USDC_TOKEN, -int128(loss));
        clearingService.depositInsuranceFund(USDC_TOKEN, insuranceFundUsdc);
        vm.stopPrank();

        bytes memory operation =
            _encodeDataToOperation(IExchange.OperationType.CoverLossByInsuranceFund, abi.encode(account, loss));

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(spotEngine.getBalance(account, USDC_TOKEN), 0);

        IClearingService.InsuranceFund memory insuranceFund = clearingService.getInsuranceFundBalance();
        assertEq(insuranceFund.inUSDC, insuranceFundUsdc - loss);
        assertEq(insuranceFund.inBSX, 0);
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

        // this is a deprecated operation type
        bytes memory invalidOperation =
            _encodeDataToOperation(IExchange.OperationType._UpdateLiquidationFeeRate, abi.encodePacked());

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
            keccak256(abi.encode(REGISTER_TYPEHASH, signer, keccak256(abi.encodePacked(message)), nonce));
        bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

        bytes32 signerStructHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, account));
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
            keccak256(abi.encode(REGISTER_TYPEHASH, signer, keccak256(abi.encodePacked(message)), nonce));
        bytes memory ownerSignature = _signTypedDataHash(ownerKey, contractAccountStructHash);

        bytes32 signerStructHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, contractAccount));
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
            keccak256(abi.encode(REGISTER_TYPEHASH, signer, keccak256(abi.encodePacked(message)), 1))
        );

        bytes32 signerStructHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, account));
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
            keccak256(abi.encode(REGISTER_TYPEHASH, signer, keccak256(abi.encodePacked(message)), nonce));
        bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

        // signed by malicious signer
        bytes32 signerStructHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, account));
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
            keccak256(abi.encode(REGISTER_TYPEHASH, signer, keccak256(abi.encodePacked(message)), nonce));
        bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

        bytes32 signerStructHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, account));
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
                keccak256(abi.encode(REGISTER_TYPEHASH, signer, keccak256(abi.encodePacked(message)), nonce));
            bytes memory accountSignature = _signTypedDataHash(accountKey, accountStructHash);

            bytes32 signerStructHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, account));
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

    function test_coverLoss_succeed() public {
        address account = makeAddr("account");
        uint128 loss = 5 * 1e18;
        address payer = makeAddr("payer");
        uint128 payerBalance = 10 * 1e18;

        vm.startPrank(address(exchange));
        spotEngine.updateBalance(account, address(collateralToken), -int128(loss));
        clearingService.deposit(payer, payerBalance, address(collateralToken));
        vm.stopPrank();

        vm.expectEmit(address(exchange));
        emit IExchange.CoverLoss(account, payer, address(collateralToken), loss);

        vm.prank(address(vaultManager));
        exchange.coverLoss(account, payer, address(collateralToken));

        assertEq(spotEngine.getBalance(address(collateralToken), account), 0);
        assertEq(spotEngine.getBalance(address(collateralToken), payer), int128(payerBalance - loss));
    }

    function test_coverLoss_revertsIfUnauthorized() public {
        address account = makeAddr("account");
        address payer = makeAddr("payer");

        vm.expectRevert(Errors.Unauthorized.selector);
        exchange.coverLoss(account, payer, address(collateralToken));
    }

    function test_coverLoss_revertsIfAccountNoLoss() public {
        address account = makeAddr("account");
        address payer = makeAddr("payer");

        vm.expectRevert(
            abi.encodeWithSelector(Errors.Exchange_AccountNoLoss.selector, account, address(collateralToken))
        );

        vm.prank(address(vaultManager));
        exchange.coverLoss(account, payer, address(collateralToken));
    }

    function test_coverLoss_revertsIfPayerInsufficientBalance() public {
        address account = makeAddr("account");
        uint128 loss = 5 * 1e18;
        address payer = makeAddr("payer");

        vm.prank(address(exchange));
        spotEngine.updateBalance(account, address(collateralToken), -int128(loss));

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.Exchange_AccountInsufficientBalance.selector, payer, address(collateralToken), 0, loss
            )
        );

        vm.prank(address(vaultManager));
        exchange.coverLoss(account, payer, address(collateralToken));
    }

    function test_claimCollectedTradingFees() public {
        vm.startPrank(sequencer);

        IOrderBook.FeeCollection memory collectedTradingFees;
        collectedTradingFees.inUSDC = 100 * 1e18;
        collectedTradingFees.inBSX = 50 * 1e18;
        vm.store(
            address(orderbook),
            bytes32(uint256(6)),
            bytes32(abi.encodePacked(collectedTradingFees.inBSX, collectedTradingFees.inUSDC))
        );
        assertEq(abi.encode(orderbook.getTradingFees()), abi.encode(collectedTradingFees));
        collateralToken.mint(
            address(exchange), uint128(collectedTradingFees.inUSDC).convertFrom18D(collateralToken.decimals())
        );
        ERC20Simple(BSX_TOKEN).mint(address(exchange), uint128(collectedTradingFees.inBSX));

        uint256 balanceBefore = collateralToken.balanceOf(feeRecipient);

        vm.expectEmit(address(exchange));
        emit IExchange.ClaimTradingFees(sequencer, collectedTradingFees);
        exchange.claimTradingFees();

        uint256 balanceAfter = collateralToken.balanceOf(feeRecipient);
        uint256 netAmount = uint128(collectedTradingFees.inUSDC).convertFrom18D(collateralToken.decimals());
        assertEq(balanceAfter, balanceBefore + netAmount);

        assertEq(abi.encode(orderbook.getTradingFees()), abi.encode(IOrderBook.FeeCollection(0, 0)));
        assertEq(abi.encode(exchange.getTradingFees()), abi.encode(IOrderBook.FeeCollection(0, 0)));
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

        uint256 exchangeSequencerFees = 50 * 1e18;
        int256 orderbookSequencerFees = 90 * 1e18;
        uint256 totalCollectedFees = exchangeSequencerFees + uint256(orderbookSequencerFees);

        stdstore.target(address(exchange)).sig("getSequencerFees(address)").with_key(address(collateralToken))
            .checked_write(exchangeSequencerFees);
        assertEq(uint256(exchange.getSequencerFees(address(collateralToken))), exchangeSequencerFees);

        IOrderBook.FeeCollection memory sequencerFees;
        sequencerFees.inUSDC = int128(orderbookSequencerFees);
        vm.store(
            address(orderbook),
            bytes32(uint256(9)),
            bytes32(abi.encodePacked(sequencerFees.inBSX, sequencerFees.inUSDC))
        );
        assertEq(abi.encode(orderbook.getSequencerFees()), abi.encode(sequencerFees));
        collateralToken.mint(address(exchange), uint128(totalCollectedFees).convertFrom18D(collateralToken.decimals()));

        uint256 balanceBefore = collateralToken.balanceOf(feeRecipient);

        vm.expectEmit(address(exchange));
        emit IExchange.ClaimSequencerFees(sequencer, address(collateralToken), totalCollectedFees);
        exchange.claimSequencerFees();

        uint256 balanceAfter = collateralToken.balanceOf(feeRecipient);
        assertEq(balanceAfter, balanceBefore + uint128(totalCollectedFees).convertFrom18D(collateralToken.decimals()));
        assertEq(exchange.getSequencerFees(address(collateralToken)), 0);
        assertEq(abi.encode(orderbook.getSequencerFees()), abi.encode(IOrderBook.FeeCollection(0, 0)));
    }

    function test_claimCollectedSequencerFees_multipleTokens() public {
        ERC20Simple token1 = new ERC20Simple(6);
        ERC20Simple token2 = new ERC20Simple(6);

        uint256 usdcTokenCollectedFee = 50 * 1e18;
        uint256 bsxTokenCollectedFee = 30 * 1e18;
        uint256 token1CollectedFee = 70 * 1e18;
        uint256 token2CollectedFee = 90 * 1e18;

        stdstore.target(address(exchange)).sig("getSequencerFees(address)").with_key(address(collateralToken))
            .checked_write(usdcTokenCollectedFee);
        stdstore.target(address(exchange)).sig("getSequencerFees(address)").with_key(BSX_TOKEN).checked_write(
            bsxTokenCollectedFee
        );
        stdstore.target(address(exchange)).sig("getSequencerFees(address)").with_key(address(token1)).checked_write(
            token1CollectedFee
        );
        stdstore.target(address(exchange)).sig("getSequencerFees(address)").with_key(address(token2)).checked_write(
            token2CollectedFee
        );

        IOrderBook.FeeCollection memory sequencerFees;
        sequencerFees.inUSDC = 20 * 1e18;
        sequencerFees.inBSX = 30 * 1e18;
        vm.store(
            address(orderbook),
            bytes32(uint256(9)),
            bytes32(abi.encodePacked(sequencerFees.inBSX, sequencerFees.inUSDC))
        );

        vm.startPrank(sequencer);

        exchange.addSupportedToken(NATIVE_ETH);
        exchange.addSupportedToken(address(token1));
        exchange.addSupportedToken(address(token2));

        deal(address(exchange), 1 ether);
        token1.mint(address(exchange), 10_000 ether);
        token2.mint(address(exchange), 10_000 ether);
        collateralToken.mint(address(exchange), 10_000 ether);
        ERC20Simple(BSX_TOKEN).mint(address(exchange), 10_000 ether);

        assertEq(
            exchange.getSequencerFees(address(collateralToken)), usdcTokenCollectedFee + uint128(sequencerFees.inUSDC)
        );
        assertEq(exchange.getSequencerFees(address(BSX_TOKEN)), bsxTokenCollectedFee + uint128(sequencerFees.inBSX));
        assertEq(exchange.getSequencerFees(address(token1)), token1CollectedFee);
        assertEq(exchange.getSequencerFees(address(token2)), token2CollectedFee);

        uint256 usdcTokenBalanceBefore = collateralToken.balanceOf(feeRecipient);
        uint256 bsxTokenBalanceBefore = ERC20Simple(BSX_TOKEN).balanceOf(feeRecipient);
        uint256 token1BalanceBefore = token1.balanceOf(feeRecipient);
        uint256 token2BalanceBefore = token2.balanceOf(feeRecipient);

        vm.expectEmit(address(exchange));
        emit IExchange.ClaimSequencerFees(
            sequencer, address(collateralToken), usdcTokenCollectedFee + uint128(sequencerFees.inUSDC)
        );

        vm.expectEmit(address(exchange));
        emit IExchange.ClaimSequencerFees(sequencer, BSX_TOKEN, bsxTokenCollectedFee + uint128(sequencerFees.inBSX));

        vm.expectEmit(address(exchange));
        emit IExchange.ClaimSequencerFees(sequencer, address(token1), token1CollectedFee);

        vm.expectEmit(address(exchange));
        emit IExchange.ClaimSequencerFees(sequencer, address(token2), token2CollectedFee);

        exchange.claimSequencerFees();

        assertEq(address(exchange).balance, 1 ether);
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
            usdcTokenBalanceBefore
                + (uint128(usdcTokenCollectedFee) + uint128(sequencerFees.inUSDC)).convertFrom18D(
                    collateralToken.decimals()
                )
        );
        assertEq(
            ERC20Simple(BSX_TOKEN).balanceOf(feeRecipient),
            bsxTokenBalanceBefore + bsxTokenCollectedFee + uint128(sequencerFees.inBSX)
        );

        assertEq(exchange.getSequencerFees(address(collateralToken)), 0);
        assertEq(exchange.getSequencerFees(address(BSX_TOKEN)), 0);
        assertEq(exchange.getSequencerFees(address(token1)), 0);
        assertEq(exchange.getSequencerFees(address(token2)), 0);

        assertEq(abi.encode(orderbook.getSequencerFees()), abi.encode(IOrderBook.FeeCollection(0, 0)));
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

    function test_depositInsuranceFund_succeeds() public {
        vm.startPrank(sequencer);

        uint8 usdcDecimals = 6;
        uint8 bsxDecimals = 18;
        IClearingService.InsuranceFund memory insuranceFund;

        for (uint128 i = 1; i < 5; i++) {
            uint128 amount = i * 1e18;
            _prepareDeposit(sequencer, USDC_TOKEN, amount);

            insuranceFund.inUSDC += amount;
            vm.expectEmit(address(exchange));
            emit IExchange.DepositInsuranceFund(USDC_TOKEN, amount, insuranceFund);
            exchange.depositInsuranceFund(USDC_TOKEN, amount);

            assertEq(clearingService.getInsuranceFundBalance().inUSDC, insuranceFund.inUSDC);
            assertEq(clearingService.getInsuranceFundBalance().inBSX, insuranceFund.inBSX);

            assertEq(exchange.getInsuranceFundBalance().inUSDC, insuranceFund.inUSDC);
            assertEq(exchange.getInsuranceFundBalance().inBSX, insuranceFund.inBSX);

            assertEq(
                ERC20Simple(USDC_TOKEN).balanceOf(address(exchange)),
                uint128(insuranceFund.inUSDC).convertFrom18D(usdcDecimals)
            );
            assertEq(
                ERC20Simple(BSX_TOKEN).balanceOf(address(exchange)),
                uint128(insuranceFund.inBSX).convertFrom18D(bsxDecimals)
            );
        }

        for (uint128 i = 1; i < 3; i++) {
            uint128 amount = i * 2e18;
            _prepareDeposit(sequencer, BSX_TOKEN, amount);

            insuranceFund.inBSX += amount;
            vm.expectEmit(address(exchange));
            emit IExchange.DepositInsuranceFund(BSX_TOKEN, amount, insuranceFund);
            exchange.depositInsuranceFund(BSX_TOKEN, amount);

            assertEq(clearingService.getInsuranceFundBalance().inUSDC, insuranceFund.inUSDC);
            assertEq(clearingService.getInsuranceFundBalance().inBSX, insuranceFund.inBSX);

            assertEq(exchange.getInsuranceFundBalance().inUSDC, insuranceFund.inUSDC);
            assertEq(exchange.getInsuranceFundBalance().inBSX, insuranceFund.inBSX);

            assertEq(
                ERC20Simple(USDC_TOKEN).balanceOf(address(exchange)),
                uint128(insuranceFund.inUSDC).convertFrom18D(usdcDecimals)
            );
            assertEq(
                ERC20Simple(BSX_TOKEN).balanceOf(address(exchange)),
                uint128(insuranceFund.inBSX).convertFrom18D(bsxDecimals)
            );
        }
    }

    function test_depositInsuranceFund_revertsWhenUnauthorized() public {
        address malicious = makeAddr("malicious");
        bytes32 role = access.GENERAL_ROLE();

        vm.startPrank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        exchange.depositInsuranceFund(USDC_TOKEN, 100);
    }

    function test_depositInsuranceFund_revertsIfZeroAmount() public {
        vm.startPrank(sequencer);
        uint128 zeroAmount = 0;
        vm.expectRevert(Errors.Exchange_ZeroAmount.selector);
        exchange.depositInsuranceFund(USDC_TOKEN, zeroAmount);

        uint128 maxZeroScaledAmount = _maxZeroScaledAmount();
        vm.expectRevert(Errors.Exchange_ZeroAmount.selector);
        exchange.depositInsuranceFund(USDC_TOKEN, maxZeroScaledAmount);
    }

    function test_withdrawInsuranceFund() public {
        vm.startPrank(sequencer);

        uint8 usdcDecimals = 6;
        uint8 bsxDecimals = 18;
        IClearingService.InsuranceFund memory insuranceFund;

        for (uint128 i = 1; i < 5; i++) {
            uint128 amount = i * 1e18;
            _prepareDeposit(sequencer, USDC_TOKEN, amount);

            insuranceFund.inUSDC += amount;
            emit IExchange.DepositInsuranceFund(USDC_TOKEN, amount, insuranceFund);
            exchange.depositInsuranceFund(USDC_TOKEN, amount);

            amount = 2 * amount;

            insuranceFund.inBSX += amount;
            _prepareDeposit(sequencer, BSX_TOKEN, amount);
            emit IExchange.DepositInsuranceFund(BSX_TOKEN, amount, insuranceFund);
            exchange.depositInsuranceFund(BSX_TOKEN, amount);
        }

        for (uint128 i = 1; i < 2; i++) {
            uint128 amount = i * 1e18;
            insuranceFund.inUSDC -= amount;
            vm.expectEmit(address(exchange));
            emit IExchange.WithdrawInsuranceFund(USDC_TOKEN, amount, insuranceFund);
            exchange.withdrawInsuranceFund(USDC_TOKEN, amount);

            assertEq(clearingService.getInsuranceFundBalance().inUSDC, insuranceFund.inUSDC);
            assertEq(clearingService.getInsuranceFundBalance().inBSX, insuranceFund.inBSX);
            assertEq(
                ERC20Simple(USDC_TOKEN).balanceOf(address(exchange)),
                uint128(insuranceFund.inUSDC).convertFrom18D(usdcDecimals)
            );
        }

        for (uint128 i = 1; i < 4; i++) {
            uint128 amount = i * 1e18;
            insuranceFund.inBSX -= amount;
            vm.expectEmit(address(exchange));
            emit IExchange.WithdrawInsuranceFund(BSX_TOKEN, amount, insuranceFund);
            exchange.withdrawInsuranceFund(BSX_TOKEN, amount);

            assertEq(clearingService.getInsuranceFundBalance().inUSDC, insuranceFund.inUSDC);
            assertEq(clearingService.getInsuranceFundBalance().inBSX, insuranceFund.inBSX);
            assertEq(
                ERC20Simple(BSX_TOKEN).balanceOf(address(exchange)),
                uint128(insuranceFund.inBSX).convertFrom18D(bsxDecimals)
            );
        }
    }

    function test_withdrawInsuranceFund_revertsWhenUnauthorized() public {
        address malicious = makeAddr("malicious");
        bytes32 role = access.GENERAL_ROLE();

        vm.startPrank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        exchange.withdrawInsuranceFund(USDC_TOKEN, 100);
    }

    function test_withdrawInsuranceFund_revertsIfZeroAmount() public {
        vm.startPrank(sequencer);
        uint128 zeroAmount = 0;
        vm.expectRevert(Errors.Exchange_ZeroAmount.selector);
        exchange.withdrawInsuranceFund(USDC_TOKEN, zeroAmount);

        uint128 maxZeroScaledAmount = _maxZeroScaledAmount();
        vm.expectRevert(Errors.Exchange_ZeroAmount.selector);
        exchange.withdrawInsuranceFund(USDC_TOKEN, maxZeroScaledAmount);
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

    function test_requestToken_succeeds() public {
        uint256 amount = 1e18;
        ERC20Simple(collateralToken).mint(address(exchange), amount);

        uint256 exchangeBalanceBefore = ERC20Simple(collateralToken).balanceOf(address(exchange));
        uint256 clearingServiceBalanceBefore = ERC20Simple(collateralToken).balanceOf(address(clearingService));

        vm.expectEmit(address(collateralToken));
        emit IERC20.Transfer(address(exchange), address(clearingService), amount);

        vm.prank(address(clearingService));
        exchange.requestToken(address(collateralToken), amount);

        assertEq(ERC20Simple(collateralToken).balanceOf(address(exchange)), exchangeBalanceBefore - amount);
        assertEq(
            ERC20Simple(collateralToken).balanceOf(address(clearingService)), clearingServiceBalanceBefore + amount
        );
    }

    function test_requestToken_revertsIfUnauthorized() public {
        address malicious = makeAddr("malicious");

        vm.expectRevert(Errors.Unauthorized.selector);

        vm.prank(malicious);
        exchange.requestToken(address(collateralToken), 1e8);
    }

    function _encodeDataToOperation(IExchange.OperationType operationType, bytes memory data)
        private
        view
        returns (bytes memory)
    {
        uint32 transactionId = exchange.executedTransactionCounter();
        return abi.encodePacked(operationType, transactionId, data);
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

    function _signTypedDataHash(uint256 privateKey, bytes32 structHash) private view returns (bytes memory) {
        return Helper.signTypedDataHash(exchange, privateKey, structHash);
    }

    function _maxZeroScaledAmount() private view returns (uint128) {
        return uint128(uint128(1).convertTo18D(collateralToken.decimals()) - 1);
    }
}

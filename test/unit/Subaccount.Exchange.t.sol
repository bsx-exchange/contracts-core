// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {Helper} from "../Helper.sol";
import {ERC20Simple} from "../mock/ERC20Simple.sol";
import {UniversalSigValidator} from "../mock/UniversalSigValidator.sol";

import {BSX1000x} from "contracts/1000x/BSX1000x.sol";
import {ClearingService} from "contracts/exchange/ClearingService.sol";
import {Exchange, IExchange} from "contracts/exchange/Exchange.sol";
import {Perp} from "contracts/exchange/Perp.sol";
import {Spot} from "contracts/exchange/Spot.sol";
import {VaultManager} from "contracts/exchange/VaultManager.sol";
import {Access} from "contracts/exchange/access/Access.sol";
import {Errors} from "contracts/exchange/lib/Errors.sol";
import {BSX_TOKEN, UNIVERSAL_SIG_VALIDATOR, USDC_TOKEN} from "contracts/exchange/share/Constants.sol";

// solhint-disable max-states-count
contract ExchangeTest is Test {
    using stdStorage for StdStorage;
    using Helper for bytes;
    using Helper for uint128;

    address private sequencer = makeAddr("sequencer");
    address private main;
    uint256 private mainKey;

    ERC20Simple private token = ERC20Simple(USDC_TOKEN);

    Access private access;
    Exchange private exchange;
    ClearingService private clearingService;
    Perp private perpEngine;
    Spot private spotEngine;
    BSX1000x private bsx1000;
    VaultManager private vaultManager;

    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant CREATE_SUBACCOUNT_TYPEHASH = keccak256("CreateSubaccount(address main,address subaccount)");
    bytes32 public constant DELETE_SUBACCOUNT_TYPEHASH = keccak256("DeleteSubaccount(address main,address subaccount)");
    bytes32 public constant REGISTER_SUBACCOUNT_SIGNER_TYPEHASH = keccak256(
        "RegisterSubaccountSigner(address main,address subaccount,address signer,string message,uint64 nonce)"
    );
    bytes32 public constant SIGN_KEY_TYPEHASH = keccak256("SignKey(address account)");

    bytes32 private constant GENERAL_ROLE = keccak256("GENERAL_ROLE");
    bytes32 private constant BATCH_OPERATOR_ROLE = keccak256("BATCH_OPERATOR_ROLE");
    bytes32 private constant SIGNER_OPERATOR_ROLE = keccak256("SIGNER_OPERATOR_ROLE");

    function setUp() public {
        (main, mainKey) = makeAddrAndKey("main");

        vm.startPrank(sequencer);

        access = new Access();
        stdstore.target(address(access)).sig("hasRole(bytes32,address)").with_key(access.ADMIN_ROLE()).with_key(
            sequencer
        ).checked_write(true);
        access.grantRole(GENERAL_ROLE, sequencer);
        access.grantRole(BATCH_OPERATOR_ROLE, sequencer);
        access.grantRole(SIGNER_OPERATOR_ROLE, sequencer);

        clearingService = new ClearingService();
        stdstore.target(address(clearingService)).sig("access()").checked_write(address(access));

        perpEngine = new Perp();
        stdstore.target(address(perpEngine)).sig("access()").checked_write(address(access));

        spotEngine = new Spot();
        stdstore.target(address(spotEngine)).sig("access()").checked_write(address(access));

        exchange = new Exchange();
        bytes memory code = address(new UniversalSigValidator()).code;
        vm.etch(address(UNIVERSAL_SIG_VALIDATOR), code);

        bsx1000 = new BSX1000x();
        stdstore.target(address(bsx1000)).sig("access()").checked_write(address(access));
        stdstore.target(address(bsx1000)).sig("collateralToken()").checked_write(address(token));

        vaultManager = new VaultManager();
        stdstore.target(address(vaultManager)).sig("access()").checked_write(address(access));
        access.setVaultManager(address(vaultManager));

        access.setExchange(address(exchange));
        access.setClearingService(address(clearingService));
        access.setSpotEngine(address(spotEngine));
        access.setPerpEngine(address(perpEngine));
        access.setBsx1000(address(bsx1000));
        access.setVaultManager(address(vaultManager));

        stdstore.target(address(exchange)).sig("access()").checked_write(address(access));
        stdstore.target(address(exchange)).sig("clearingService()").checked_write(address(clearingService));
        stdstore.target(address(exchange)).sig("spotEngine()").checked_write(address(spotEngine));
        stdstore.target(address(exchange)).sig("perpEngine()").checked_write(address(perpEngine));
        exchange.setCanDeposit(true);
        exchange.setCanWithdraw(true);

        deployCodeTo("ERC20Simple.sol", abi.encode(6), USDC_TOKEN);
        exchange.addSupportedToken(USDC_TOKEN);

        deployCodeTo("ERC20Simple.sol", abi.encode(18), BSX_TOKEN);
        exchange.addSupportedToken(BSX_TOKEN);

        vm.stopPrank();
    }

    function test_createSubaccount_succeeds() public {
        (address subaccount, uint256 subKey) = makeAddrAndKey("subaccount");

        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedData(mainKey, structHash);
        bytes memory subSignature = _signTypedData(subKey, structHash);

        vm.expectEmit(address(exchange));
        emit IExchange.CreateSubaccount(main, subaccount);

        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);

        IExchange.Account memory mainAccount = exchange.accounts(main);
        assertEq(mainAccount.main, address(0));
        assertEq(uint8(mainAccount.accountType), uint8(IExchange.AccountType.Main));
        assertEq(uint8(mainAccount.state), uint8(IExchange.AccountState.Active));
        assertEq(mainAccount.subaccounts.length, 1);
        assertEq(mainAccount.subaccounts[0], subaccount);

        IExchange.Account memory subAccount = exchange.accounts(subaccount);
        assertEq(subAccount.main, main);
        assertEq(uint8(subAccount.accountType), uint8(IExchange.AccountType.Subaccount));
        assertEq(uint8(subAccount.state), uint8(IExchange.AccountState.Active));
        assertEq(subAccount.subaccounts.length, 0);
    }

    function test_createSubaccount_revertsIfUnauthorized() public {
        address malicious = makeAddr("malicious");
        bytes32 role = access.GENERAL_ROLE();
        bytes memory signature;

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );

        vm.prank(malicious);
        exchange.createSubaccount(main, address(1), signature, signature);
    }

    function test_createSubaccount_revertsIfInvalidSignature() public {
        (address subaccount, uint256 subKey) = makeAddrAndKey("subaccount");

        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedData(mainKey, structHash);
        bytes memory subSignature = _signTypedData(subKey, structHash);
        bytes memory maliciousSignature = _signTypedData(123, structHash);

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_InvalidSignature.selector, main));
        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, maliciousSignature, subSignature);

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_InvalidSignature.selector, subaccount));
        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, maliciousSignature);
    }

    function test_processBatch_deleteSubaccount_succeeds() public {
        (address sub1, uint256 sub1Key) = makeAddrAndKey("sub1");
        (address sub2, uint256 sub2Key) = makeAddrAndKey("sub2");

        // create 2 subaccounts
        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, sub1));
        bytes memory mainSignature = _signTypedData(mainKey, structHash);
        bytes memory subSignature = _signTypedData(sub1Key, structHash);
        vm.prank(sequencer);
        exchange.createSubaccount(main, sub1, mainSignature, subSignature);

        structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, sub2));
        mainSignature = _signTypedData(mainKey, structHash);
        subSignature = _signTypedData(sub2Key, structHash);
        vm.prank(sequencer);
        exchange.createSubaccount(main, sub2, mainSignature, subSignature);

        // delete sub1
        structHash = keccak256(abi.encode(DELETE_SUBACCOUNT_TYPEHASH, main, sub1));
        mainSignature = _signTypedData(mainKey, structHash);

        bytes memory deleteSubacountData = abi.encode(IExchange.DeleteSubaccountParams(main, sub1, mainSignature));
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.DeleteSubaccount, deleteSubacountData);

        vm.expectEmit(address(exchange));
        emit IExchange.DeleteSubaccount(main, sub1, IExchange.ActionStatus.Success);

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        IExchange.Account memory mainAccount = exchange.accounts(main);
        assertEq(mainAccount.main, address(0));
        assertEq(uint8(mainAccount.accountType), uint8(IExchange.AccountType.Main));
        assertEq(uint8(mainAccount.state), uint8(IExchange.AccountState.Active));
        assertEq(mainAccount.subaccounts.length, 1);
        assertEq(mainAccount.subaccounts[0], sub2);

        IExchange.Account memory subAccount1 = exchange.accounts(sub1);
        assertEq(subAccount1.main, main);
        assertEq(uint8(subAccount1.accountType), uint8(IExchange.AccountType.Subaccount));
        assertEq(uint8(subAccount1.state), uint8(IExchange.AccountState.Deleted));
        assertEq(subAccount1.subaccounts.length, 0);

        IExchange.Account memory subAccount2 = exchange.accounts(sub2);
        assertEq(subAccount2.main, main);
        assertEq(uint8(subAccount2.accountType), uint8(IExchange.AccountType.Subaccount));
        assertEq(uint8(subAccount2.state), uint8(IExchange.AccountState.Active));
        assertEq(subAccount2.subaccounts.length, 0);
    }

    function test_processBatch_deleteSubaccount_revertsIfInvalidSignature() public {
        (address sub, uint256 subKey) = makeAddrAndKey("sub");

        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, sub));
        bytes memory mainSignature = _signTypedData(mainKey, structHash);
        bytes memory subSignature = _signTypedData(subKey, structHash);
        vm.prank(sequencer);
        exchange.createSubaccount(main, sub, mainSignature, subSignature);

        structHash = keccak256(abi.encode(DELETE_SUBACCOUNT_TYPEHASH, main, sub));
        bytes memory maliciousSignature = _signTypedData(123, structHash);

        bytes memory deleteSubacountData = abi.encode(IExchange.DeleteSubaccountParams(main, sub, maliciousSignature));
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.DeleteSubaccount, deleteSubacountData);

        vm.expectEmit(address(exchange));
        emit IExchange.DeleteSubaccount(main, sub, IExchange.ActionStatus.Failure);

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_registerSubaccountSigner() public {
        (address subaccount, uint256 subaccountKey) = makeAddrAndKey("subaccount");
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");

        bytes32 createSubHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedData(mainKey, createSubHash);
        bytes memory subSignature = _signTypedData(subaccountKey, createSubHash);

        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);

        string memory message = "message";
        uint64 nonce = 1;

        bytes32 mainHash = keccak256(
            abi.encode(
                REGISTER_SUBACCOUNT_SIGNER_TYPEHASH,
                main,
                subaccount,
                signer,
                keccak256(abi.encodePacked(message)),
                nonce
            )
        );
        mainSignature = _signTypedData(mainKey, mainHash);

        bytes32 signerHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, subaccount));
        bytes memory signerSignature = _signTypedData(signerKey, signerHash);

        bytes memory registerSubaccountSignerData = abi.encode(
            IExchange.RegisterSubaccountSignerParams(
                main, subaccount, signer, message, nonce, mainSignature, signerSignature
            )
        );
        bytes memory operation =
            _encodeDataToOperation(IExchange.OperationType.RegisterSubaccountSigner, registerSubaccountSignerData);

        vm.expectEmit(address(exchange));
        emit IExchange.RegisterSigner(subaccount, signer, nonce);

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isSigningWallet(main, signer), false);
        assertEq(exchange.isRegisterSignerNonceUsed(main, nonce), true);

        assertEq(exchange.isSigningWallet(subaccount, signer), true);
        assertEq(exchange.isRegisterSignerNonceUsed(subaccount, nonce), false);
    }

    function test_processBatch_registerSubaccountSigner_revertsIfInvalidMainSignature() public {
        (address subaccount, uint256 subaccountKey) = makeAddrAndKey("subaccount");
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");

        bytes32 createSubHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedData(mainKey, createSubHash);
        bytes memory subSignature = _signTypedData(subaccountKey, createSubHash);

        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);

        string memory message = "message";
        uint64 nonce = 1;

        bytes32 mainHash = keccak256(
            abi.encode(
                REGISTER_SUBACCOUNT_SIGNER_TYPEHASH,
                main,
                subaccount,
                signer,
                keccak256(abi.encodePacked(message)),
                nonce
            )
        );
        mainSignature = _signTypedData(123, mainHash);

        bytes32 signerHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, subaccount));
        bytes memory signerSignature = _signTypedData(signerKey, signerHash);

        bytes memory registerSubaccountSignerData = abi.encode(
            IExchange.RegisterSubaccountSignerParams(
                main, subaccount, signer, message, nonce, mainSignature, signerSignature
            )
        );
        bytes memory operation =
            _encodeDataToOperation(IExchange.OperationType.RegisterSubaccountSigner, registerSubaccountSignerData);

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_InvalidSignature.selector, main));

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_registerSubaccountSigner_revertsIfInvalidSignerSignature() public {
        (address subaccount, uint256 subaccountKey) = makeAddrAndKey("subaccount");
        (address signer,) = makeAddrAndKey("signer");

        bytes32 createSubHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedData(mainKey, createSubHash);
        bytes memory subSignature = _signTypedData(subaccountKey, createSubHash);

        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);

        string memory message = "message";
        uint64 nonce = 1;

        bytes32 mainHash = keccak256(
            abi.encode(
                REGISTER_SUBACCOUNT_SIGNER_TYPEHASH,
                main,
                subaccount,
                signer,
                keccak256(abi.encodePacked(message)),
                nonce
            )
        );
        mainSignature = _signTypedData(123, mainHash);

        bytes32 signerHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, subaccount));
        bytes memory signerSignature = _signTypedData(123, signerHash);

        bytes memory registerSubaccountSignerData = abi.encode(
            IExchange.RegisterSubaccountSignerParams(
                main, subaccount, signer, message, nonce, mainSignature, signerSignature
            )
        );
        bytes memory operation =
            _encodeDataToOperation(IExchange.OperationType.RegisterSubaccountSigner, registerSubaccountSignerData);

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_InvalidSignature.selector, main));

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_registerSubaccountSigner_revertsIfNonceUsed() public {
        (address subaccount, uint256 subaccountKey) = makeAddrAndKey("subaccount");
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");

        bytes32 createSubHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedData(mainKey, createSubHash);
        bytes memory subSignature = _signTypedData(subaccountKey, createSubHash);

        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);

        string memory message = "message";
        uint64 nonce = 1;

        bytes32 mainHash = keccak256(
            abi.encode(
                REGISTER_SUBACCOUNT_SIGNER_TYPEHASH,
                main,
                subaccount,
                signer,
                keccak256(abi.encodePacked(message)),
                nonce
            )
        );
        mainSignature = _signTypedData(mainKey, mainHash);

        bytes32 signerHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, subaccount));
        bytes memory signerSignature = _signTypedData(signerKey, signerHash);

        bytes memory registerSubaccountSignerData = abi.encode(
            IExchange.RegisterSubaccountSignerParams(
                main, subaccount, signer, message, nonce, mainSignature, signerSignature
            )
        );
        bytes memory operation =
            _encodeDataToOperation(IExchange.OperationType.RegisterSubaccountSigner, registerSubaccountSignerData);

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.isSigningWallet(main, signer), false);
        assertEq(exchange.isRegisterSignerNonceUsed(main, nonce), true);

        assertEq(exchange.isSigningWallet(subaccount, signer), true);
        assertEq(exchange.isRegisterSignerNonceUsed(subaccount, nonce), false);

        operation =
            _encodeDataToOperation(IExchange.OperationType.RegisterSubaccountSigner, registerSubaccountSignerData);

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_AddSigningWallet_UsedNonce.selector, main, nonce));

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function _encodeDataToOperation(IExchange.OperationType operationType, bytes memory data)
        private
        view
        returns (bytes memory)
    {
        uint32 transactionId = exchange.executedTransactionCounter();
        return abi.encodePacked(operationType, transactionId, data);
    }

    function _signTypedData(uint256 privateKey, bytes32 structHash) private view returns (bytes memory) {
        return Helper.signTypedDataHash(exchange, privateKey, structHash);
    }
}

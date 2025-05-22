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
import {Roles} from "contracts/exchange/lib/Roles.sol";
import {BSX_TOKEN, UNIVERSAL_SIG_VALIDATOR, USDC_TOKEN} from "contracts/exchange/share/Constants.sol";
import {TxStatus} from "contracts/exchange/share/Enums.sol";

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
    bytes32 private constant DELETE_SUBACCOUNT_TYPEHASH = keccak256("DeleteSubaccount(address main,address subaccount)");
    bytes32 private constant REGISTER_SUBACCOUNT_SIGNER_TYPEHASH = keccak256(
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
        stdstore.target(address(access)).sig("hasRole(bytes32,address)").with_key(Roles.ADMIN_ROLE).with_key(sequencer)
            .checked_write(true);
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
        address[] memory subaccounts = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            (address subaccount, uint256 subKey) = makeAddrAndKey(string(abi.encodePacked("subaccount", i)));
            subaccounts[i] = subaccount;

            bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
            bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
            bytes memory subSignature = _signTypedDataHash(subKey, structHash);

            vm.expectEmit(address(exchange));
            emit IExchange.CreateSubaccount(main, subaccount);

            vm.prank(sequencer);
            exchange.createSubaccount(main, subaccount, mainSignature, subSignature);
        }

        IExchange.Account memory mainAccount = exchange.accounts(main);
        assertEq(mainAccount.main, address(0));
        assertEq(uint8(mainAccount.accountType), uint8(IExchange.AccountType.Main));
        assertEq(uint8(mainAccount.state), uint8(IExchange.AccountState.Active));
        assertEq(mainAccount.subaccounts.length, 10);

        address[] memory subaccountList = exchange.getSubaccounts(main);
        assertEq(subaccountList.length, 10);

        for (uint256 i = 0; i < 10; i++) {
            assertEq(subaccountList[i], mainAccount.subaccounts[i]);
            assertEq(subaccountList[i], subaccounts[i]);

            IExchange.Account memory subAccount = exchange.accounts(subaccounts[i]);
            assertEq(subAccount.main, main);
            assertEq(uint8(subAccount.accountType), uint8(IExchange.AccountType.Subaccount));
            assertEq(uint8(subAccount.state), uint8(IExchange.AccountState.Active));
            assertEq(subAccount.subaccounts.length, 0);
        }
    }

    function test_createSubaccount_revertsIfUnauthorized() public {
        address malicious = makeAddr("malicious");
        bytes32 role = Roles.GENERAL_ROLE;
        bytes memory signature;

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );

        vm.prank(malicious);
        exchange.createSubaccount(main, address(1), signature, signature);
    }

    function test_createSubaccount_revertsIfSubaccountIsTheSameAsMain() public {
        (address subaccount, uint256 subKey) = (main, mainKey);

        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
        bytes memory subSignature = _signTypedDataHash(subKey, structHash);

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_Subaccount_SameAsMainAccount.selector, subaccount));

        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);
    }

    function test_createSubaccount_revertsIfInvalidMainAccount() public {
        (address subaccount, uint256 subKey) = makeAddrAndKey("subaccount");

        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
        bytes memory subSignature = _signTypedDataHash(subKey, structHash);

        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);

        // main account is already a subaccount
        main = subaccount;
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_InvalidAccountType.selector, main));
        vm.prank(sequencer);
        exchange.createSubaccount(main, address(1), mainSignature, subSignature);
    }

    function test_createSubaccount_revertsIfInvalidSubaccount() public {
        (address subaccount, uint256 subKey) = makeAddrAndKey("subaccount");

        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
        bytes memory subSignature = _signTypedDataHash(subKey, structHash);

        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);

        // subaccount is already a subaccount
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_InvalidAccountType.selector, subaccount));
        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);

        // subaccount is a main account
        subaccount = main;
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_Subaccount_IsMainAccount.selector, subaccount));
        vm.prank(sequencer);
        exchange.createSubaccount(address(1), subaccount, mainSignature, subSignature);
    }

    function test_createSubaccount_revertsIfSubaccountBSX1000BalanceNotZero() public {
        (address subaccount, uint256 subKey) = makeAddrAndKey("subaccount");

        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
        bytes memory subSignature = _signTypedDataHash(subKey, structHash);

        // bsx1000 balance > 0
        vm.mockCall(
            address(bsx1000), abi.encodeWithSelector(BSX1000x.getBalance.selector, subaccount), abi.encode(1e18, 0)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.Exchange_Subaccount_BSX1000_NonzeroBalance.selector, subaccount, address(token)
            )
        );
        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);

        vm.mockCall(
            address(bsx1000), abi.encodeWithSelector(BSX1000x.getBalance.selector, subaccount), abi.encode(0, 2e18)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.Exchange_Subaccount_BSX1000_NonzeroBalance.selector, subaccount, address(token)
            )
        );
        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);
    }

    function test_createSubaccount_revertsIfSubaccountPerpBalanceNotZero() public {
        (address subaccount, uint256 subKey) = makeAddrAndKey("subaccount");

        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
        bytes memory subSignature = _signTypedDataHash(subKey, structHash);

        // perp balance > 0
        vm.prank(address(exchange));
        clearingService.deposit(subaccount, 1e18, address(token));

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.Exchange_Subaccount_Exchange_NonzeroBalance.selector, subaccount, address(token)
            )
        );

        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);
    }

    function test_createSubaccount_revertsIfSubaccountYieldBalanceNotZero() public {
        (address subaccount, uint256 subKey) = makeAddrAndKey("subaccount");

        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
        bytes memory subSignature = _signTypedDataHash(subKey, structHash);

        address yieldAsset = makeAddr("yieldAsset");
        vm.mockCall(
            address(clearingService),
            abi.encodeWithSignature("yieldAssets(address)", address(token)),
            abi.encode(yieldAsset)
        );
        vm.mockCall(
            address(spotEngine),
            abi.encodeWithSelector(Spot.getBalance.selector, yieldAsset, subaccount),
            abi.encode(1e18)
        );

        vm.expectRevert(
            abi.encodeWithSelector(Errors.Exchange_Subaccount_Exchange_NonzeroBalance.selector, subaccount, yieldAsset)
        );

        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);
    }

    function test_createSubaccount_revertsIfSubaccountJoinedVault() public {
        (address subaccount, uint256 subKey) = makeAddrAndKey("subaccount");

        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
        bytes memory subSignature = _signTypedDataHash(subKey, structHash);

        vm.mockCall(address(vaultManager), abi.encodeWithSignature("vaultCount(address)", subaccount), abi.encode(1));

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_Subaccount_JoinedVault.selector, subaccount));

        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);
    }

    function test_createSubaccount_revertsIfInvalidSignature() public {
        (address subaccount, uint256 subKey) = makeAddrAndKey("subaccount");

        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
        bytes memory subSignature = _signTypedDataHash(subKey, structHash);
        bytes memory maliciousSignature = _signTypedDataHash(123, structHash);

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
        bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
        bytes memory subSignature = _signTypedDataHash(sub1Key, structHash);
        vm.prank(sequencer);
        exchange.createSubaccount(main, sub1, mainSignature, subSignature);

        structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, sub2));
        mainSignature = _signTypedDataHash(mainKey, structHash);
        subSignature = _signTypedDataHash(sub2Key, structHash);
        vm.prank(sequencer);
        exchange.createSubaccount(main, sub2, mainSignature, subSignature);

        // deposit to subaccount accounts
        vm.startPrank(address(exchange));
        clearingService.deposit(sub1, 100e18, address(token));
        clearingService.deposit(sub2, 200e18, address(token));
        vm.stopPrank();

        // delete sub1
        structHash = keccak256(abi.encode(DELETE_SUBACCOUNT_TYPEHASH, main, sub1));
        mainSignature = _signTypedDataHash(mainKey, structHash);

        bytes memory deleteSubacountData = abi.encode(IExchange.DeleteSubaccountParams(main, sub1, mainSignature));
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.DeleteSubaccount, deleteSubacountData);

        vm.expectEmit(address(exchange));
        emit IExchange.Transfer(address(token), sub1, main, address(0), 0, 100e18, TxStatus.Success);

        vm.expectEmit(address(exchange));
        emit IExchange.DeleteSubaccount(main, sub1, TxStatus.Success);

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.balanceOf(sub1, address(token)), 0);
        assertEq(exchange.balanceOf(sub2, address(token)), 200e18);
        assertEq(exchange.balanceOf(main, address(token)), 100e18);

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
        bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
        bytes memory subSignature = _signTypedDataHash(subKey, structHash);
        vm.prank(sequencer);
        exchange.createSubaccount(main, sub, mainSignature, subSignature);

        structHash = keccak256(abi.encode(DELETE_SUBACCOUNT_TYPEHASH, main, sub));
        bytes memory maliciousSignature = _signTypedDataHash(123, structHash);

        bytes memory deleteSubacountData = abi.encode(IExchange.DeleteSubaccountParams(main, sub, maliciousSignature));
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.DeleteSubaccount, deleteSubacountData);

        vm.expectEmit(address(exchange));
        emit IExchange.DeleteSubaccount(main, sub, TxStatus.Failure);

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_deleteSubaccount_revertsIfInvalidMainAccount() public {
        (address subaccount, uint256 subKey) = makeAddrAndKey("subaccount");

        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
        bytes memory subSignature = _signTypedDataHash(subKey, structHash);
        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);

        // deposit to subaccount accounts
        vm.prank(address(exchange));
        clearingService.deposit(subaccount, 100e18, address(token));

        // main account is already a subaccount
        address invalidMain = subaccount;
        structHash = keccak256(abi.encode(DELETE_SUBACCOUNT_TYPEHASH, invalidMain, subaccount));
        mainSignature = _signTypedDataHash(mainKey, structHash);

        bytes memory deleteSubacountData =
            abi.encode(IExchange.DeleteSubaccountParams(invalidMain, subaccount, mainSignature));
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.DeleteSubaccount, deleteSubacountData);

        vm.expectEmit(address(exchange));
        emit IExchange.DeleteSubaccount(invalidMain, subaccount, TxStatus.Failure);

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.balanceOf(subaccount, address(token)), 100e18);
        assertEq(exchange.balanceOf(main, address(token)), 0);

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

    function test_processBatch_deleteSubaccount_revertsIfInvalidSubaccount() public {
        (address subaccount, uint256 subKey) = makeAddrAndKey("subaccount");

        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
        bytes memory subSignature = _signTypedDataHash(subKey, structHash);
        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);

        // deposit to subaccount accounts
        vm.prank(address(exchange));
        clearingService.deposit(subaccount, 100e18, address(token));

        // subaccount is not a subaccount
        address invalidSubaccount = address(1);
        structHash = keccak256(abi.encode(DELETE_SUBACCOUNT_TYPEHASH, main, invalidSubaccount));
        mainSignature = _signTypedDataHash(mainKey, structHash);

        bytes memory deleteSubacountData =
            abi.encode(IExchange.DeleteSubaccountParams(main, invalidSubaccount, mainSignature));
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.DeleteSubaccount, deleteSubacountData);

        vm.expectEmit(address(exchange));
        emit IExchange.DeleteSubaccount(main, invalidSubaccount, TxStatus.Failure);

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.balanceOf(subaccount, address(token)), 100e18);
        assertEq(exchange.balanceOf(main, address(token)), 0);

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

    function test_processBatch_deleteSubaccount_revertsIfMainAccountMismatch() public {
        (address subaccount, uint256 subKey) = makeAddrAndKey("subaccount");

        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
        bytes memory subSignature = _signTypedDataHash(subKey, structHash);
        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);

        // deposit to subaccount accounts
        vm.prank(address(exchange));
        clearingService.deposit(subaccount, 100e18, address(token));

        // main account mismatch
        address anotherMain = address(1);
        structHash = keccak256(abi.encode(DELETE_SUBACCOUNT_TYPEHASH, anotherMain, subaccount));
        mainSignature = _signTypedDataHash(mainKey, structHash);

        bytes memory deleteSubacountData =
            abi.encode(IExchange.DeleteSubaccountParams(anotherMain, subaccount, mainSignature));
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.DeleteSubaccount, deleteSubacountData);

        vm.expectEmit(address(exchange));
        emit IExchange.DeleteSubaccount(anotherMain, subaccount, TxStatus.Failure);

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.balanceOf(subaccount, address(token)), 100e18);
        assertEq(exchange.balanceOf(main, address(token)), 0);

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

    function test_processBatch_deleteSubaccount_revertsISubaccountAlreadyDeleted() public {
        (address subaccount, uint256 subKey) = makeAddrAndKey("subaccount");

        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
        bytes memory subSignature = _signTypedDataHash(subKey, structHash);
        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);

        // deposit to subaccount accounts
        vm.prank(address(exchange));
        clearingService.deposit(subaccount, 100e18, address(token));

        structHash = keccak256(abi.encode(DELETE_SUBACCOUNT_TYPEHASH, main, subaccount));
        mainSignature = _signTypedDataHash(mainKey, structHash);

        bytes memory deleteSubacountData = abi.encode(IExchange.DeleteSubaccountParams(main, subaccount, mainSignature));
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.DeleteSubaccount, deleteSubacountData);
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        // delete subaccount again
        operation = _encodeDataToOperation(IExchange.OperationType.DeleteSubaccount, deleteSubacountData);

        vm.expectEmit(address(exchange));
        emit IExchange.DeleteSubaccount(main, subaccount, TxStatus.Failure);

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.balanceOf(subaccount, address(token)), 0);
        assertEq(exchange.balanceOf(main, address(token)), 100e18);

        IExchange.Account memory mainAccount = exchange.accounts(main);
        assertEq(mainAccount.main, address(0));
        assertEq(uint8(mainAccount.accountType), uint8(IExchange.AccountType.Main));
        assertEq(uint8(mainAccount.state), uint8(IExchange.AccountState.Active));
        assertEq(mainAccount.subaccounts.length, 0);

        IExchange.Account memory subAccount = exchange.accounts(subaccount);
        assertEq(subAccount.main, main);
        assertEq(uint8(subAccount.accountType), uint8(IExchange.AccountType.Subaccount));
        assertEq(uint8(subAccount.state), uint8(IExchange.AccountState.Deleted));
        assertEq(subAccount.subaccounts.length, 0);
    }

    function test_processBatch_deleteSubaccount_revertsISubaccountHasOpenPositions() public {
        (address subaccount, uint256 subKey) = makeAddrAndKey("subaccount");

        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
        bytes memory subSignature = _signTypedDataHash(subKey, structHash);
        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);

        // deposit to subaccount accounts
        vm.prank(address(exchange));
        clearingService.deposit(subaccount, 100e18, address(token));

        structHash = keccak256(abi.encode(DELETE_SUBACCOUNT_TYPEHASH, main, subaccount));
        mainSignature = _signTypedDataHash(mainKey, structHash);

        bytes memory deleteSubacountData = abi.encode(IExchange.DeleteSubaccountParams(main, subaccount, mainSignature));
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.DeleteSubaccount, deleteSubacountData);

        vm.mockCall(address(perpEngine), abi.encodeWithSignature("openPositions(address)", subaccount), abi.encode(2));

        vm.expectEmit(address(exchange));
        emit IExchange.DeleteSubaccount(main, subaccount, TxStatus.Failure);

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(exchange.balanceOf(subaccount, address(token)), 100e18);
        assertEq(exchange.balanceOf(main, address(token)), 0);

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

    function test_processBatch_registerSubaccountSigner_succeeds() public {
        (address subaccount, uint256 subaccountKey) = makeAddrAndKey("subaccount");
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");

        bytes32 createSubHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedDataHash(mainKey, createSubHash);
        bytes memory subSignature = _signTypedDataHash(subaccountKey, createSubHash);

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
        mainSignature = _signTypedDataHash(mainKey, mainHash);

        bytes32 signerHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, subaccount));
        bytes memory signerSignature = _signTypedDataHash(signerKey, signerHash);

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
        bytes memory mainSignature = _signTypedDataHash(mainKey, createSubHash);
        bytes memory subSignature = _signTypedDataHash(subaccountKey, createSubHash);

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
        mainSignature = _signTypedDataHash(123, mainHash);

        bytes32 signerHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, subaccount));
        bytes memory signerSignature = _signTypedDataHash(signerKey, signerHash);

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
        bytes memory mainSignature = _signTypedDataHash(mainKey, createSubHash);
        bytes memory subSignature = _signTypedDataHash(subaccountKey, createSubHash);

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
        mainSignature = _signTypedDataHash(123, mainHash);

        bytes32 signerHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, subaccount));
        bytes memory signerSignature = _signTypedDataHash(123, signerHash);

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
        bytes memory mainSignature = _signTypedDataHash(mainKey, createSubHash);
        bytes memory subSignature = _signTypedDataHash(subaccountKey, createSubHash);

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
        mainSignature = _signTypedDataHash(mainKey, mainHash);

        bytes32 signerHash = keccak256(abi.encode(SIGN_KEY_TYPEHASH, subaccount));
        bytes memory signerSignature = _signTypedDataHash(signerKey, signerHash);

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

    function test_processBatch_registerSubaccountSigner_revertsIfInvalidMainAccount() public {
        (address subaccount, uint256 subaccountKey) = makeAddrAndKey("subaccount");
        address signer = address(2);

        bytes32 createSubHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedDataHash(mainKey, createSubHash);
        bytes memory subSignature = _signTypedDataHash(subaccountKey, createSubHash);

        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);

        // main account is already a subaccount
        main = subaccount;

        bytes memory registerSubaccountSignerData =
            abi.encode(IExchange.RegisterSubaccountSignerParams(main, subaccount, signer, "", 1, bytes(""), bytes("")));
        bytes memory operation =
            _encodeDataToOperation(IExchange.OperationType.RegisterSubaccountSigner, registerSubaccountSignerData);

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_InvalidAccountType.selector, main));

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_registerSubaccountSigner_revertsIfInvalidSubaccount() public {
        address subaccount = address(1);
        address signer = address(2);

        bytes memory registerSubaccountSignerData =
            abi.encode(IExchange.RegisterSubaccountSignerParams(main, subaccount, signer, "", 1, bytes(""), bytes("")));
        bytes memory operation =
            _encodeDataToOperation(IExchange.OperationType.RegisterSubaccountSigner, registerSubaccountSignerData);

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_InvalidAccountType.selector, subaccount));

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_registerSubaccountSigner_revertsIfSubaccountDeleted() public {
        (address subaccount, uint256 subKey) = makeAddrAndKey("subaccount");

        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
        bytes memory subSignature = _signTypedDataHash(subKey, structHash);
        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);

        structHash = keccak256(abi.encode(DELETE_SUBACCOUNT_TYPEHASH, main, subaccount));
        mainSignature = _signTypedDataHash(mainKey, structHash);

        bytes memory deleteSubacountData = abi.encode(IExchange.DeleteSubaccountParams(main, subaccount, mainSignature));
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.DeleteSubaccount, deleteSubacountData);
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        // subaccount is already deleted
        address signer = address(2);
        bytes memory registerSubaccountSignerData =
            abi.encode(IExchange.RegisterSubaccountSignerParams(main, subaccount, signer, "", 1, bytes(""), bytes("")));
        operation =
            _encodeDataToOperation(IExchange.OperationType.RegisterSubaccountSigner, registerSubaccountSignerData);

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_Subaccount_NotActive.selector, subaccount));

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_processBatch_registerSubaccountSigner_revertsIfMainAccountMismatch() public {
        (address subaccount, uint256 subKey) = makeAddrAndKey("subaccount");

        bytes32 structHash = keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount));
        bytes memory mainSignature = _signTypedDataHash(mainKey, structHash);
        bytes memory subSignature = _signTypedDataHash(subKey, structHash);
        vm.prank(sequencer);
        exchange.createSubaccount(main, subaccount, mainSignature, subSignature);

        // subaccount is already deleted
        address anotherMain = address(1);
        address signer = address(2);
        bytes memory registerSubaccountSignerData = abi.encode(
            IExchange.RegisterSubaccountSignerParams(anotherMain, subaccount, signer, "", 1, bytes(""), bytes(""))
        );
        bytes memory operation =
            _encodeDataToOperation(IExchange.OperationType.RegisterSubaccountSigner, registerSubaccountSignerData);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.Exchange_Subaccount_MainAccountMismatch.selector, anotherMain, main)
        );

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

    function _signTypedDataHash(uint256 privateKey, bytes32 structHash) private view returns (bytes memory) {
        return Helper.signTypedDataHash(exchange, privateKey, structHash);
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {Helper} from "../Helper.sol";
import {ERC20Simple} from "../mock/ERC20Simple.sol";
import {UniversalSigValidator} from "../mock/UniversalSigValidator.sol";

import {ClearingService} from "contracts/exchange/ClearingService.sol";
import {Exchange, IExchange} from "contracts/exchange/Exchange.sol";
import {Spot} from "contracts/exchange/Spot.sol";
import {IVaultManager, VaultManager} from "contracts/exchange/VaultManager.sol";
import {Access} from "contracts/exchange/access/Access.sol";
import {Errors} from "contracts/exchange/lib/Errors.sol";
import {Roles} from "contracts/exchange/lib/Roles.sol";
import {UNIVERSAL_SIG_VALIDATOR} from "contracts/exchange/share/Constants.sol";

contract VaultManagerTest is Test {
    using stdStorage for StdStorage;
    using Helper for bytes;

    address private sequencer = makeAddr("sequencer");
    address private vault;
    uint256 private vaultPrivKey;
    address private feeRecipient = makeAddr("feeRecipient");
    uint256 private profitShareBps = 1000; // 10%

    address private staker;
    uint256 private stakerPrivKey;

    ERC20Simple private asset = new ERC20Simple(6);
    ERC20Simple private collateralToken1 = new ERC20Simple(18);
    ERC20Simple private collateralToken2 = new ERC20Simple(8);

    Access private access;
    Exchange private exchange;
    ClearingService private clearingService;
    Spot private spotEngine;
    VaultManager private vaultManager;

    bytes32 private constant REGISTER_VAULT_TYPEHASH =
        keccak256("RegisterVault(address vault,address feeRecipient,uint256 profitShareBps)");
    bytes32 private constant STAKE_VAULT_TYPEHASH =
        keccak256("StakeVault(address vault,address account,address token,uint256 amount,uint256 nonce)");
    bytes32 private constant UNSTAKE_VAULT_TYPEHASH =
        keccak256("UnstakeVault(address vault,address account,address token,uint256 amount,uint256 nonce)");

    function setUp() public {
        vm.startPrank(sequencer);

        (vault, vaultPrivKey) = makeAddrAndKey("vault");
        (staker, stakerPrivKey) = makeAddrAndKey("staker");

        bytes memory code = address(new UniversalSigValidator()).code;
        vm.etch(address(UNIVERSAL_SIG_VALIDATOR), code);

        access = new Access();
        stdstore.target(address(access)).sig("hasRole(bytes32,address)").with_key(Roles.ADMIN_ROLE).with_key(sequencer)
            .checked_write(true);
        access.grantRole(Roles.GENERAL_ROLE, sequencer);
        access.grantRole(Roles.BATCH_OPERATOR_ROLE, sequencer);

        clearingService = new ClearingService();
        stdstore.target(address(clearingService)).sig("access()").checked_write(address(access));

        spotEngine = new Spot();
        stdstore.target(address(spotEngine)).sig("access()").checked_write(address(access));

        exchange = new Exchange();
        stdstore.target(address(exchange)).sig("access()").checked_write(address(access));
        stdstore.target(address(exchange)).sig("clearingService()").checked_write(address(clearingService));
        stdstore.target(address(exchange)).sig("spotEngine()").checked_write(address(spotEngine));

        vaultManager = new VaultManager();
        stdstore.target(address(vaultManager)).sig("access()").checked_write(address(access));
        stdstore.target(address(vaultManager)).sig("asset()").checked_write(address(asset));

        access.setExchange(address(exchange));
        access.setClearingService(address(clearingService));
        access.setSpotEngine(address(spotEngine));
        access.setVaultManager(address(vaultManager));

        exchange.setCanDeposit(true);
        exchange.setCanWithdraw(true);

        exchange.addSupportedToken(address(asset));
        exchange.addSupportedToken(address(collateralToken1));
        exchange.addSupportedToken(address(collateralToken2));

        vm.stopPrank();
    }

    function test_registerVault_success() public {
        bytes32 structHash = keccak256(abi.encode(REGISTER_VAULT_TYPEHASH, vault, feeRecipient, profitShareBps));
        bytes memory signature = _signTypedDataHash(vaultPrivKey, structHash);

        vm.expectEmit(address(exchange));
        emit IExchange.RegisterVault(vault, feeRecipient, profitShareBps);

        vm.prank(sequencer);
        exchange.registerVault(vault, feeRecipient, profitShareBps, signature);

        IVaultManager.VaultConfig memory vaultConfig = vaultManager.getVaultConfig(vault);
        assertEq(vaultConfig.profitShareBps, profitShareBps);
        assertEq(vaultConfig.feeRecipient, feeRecipient);
        assertEq(vaultConfig.isRegistered, true);

        assertEq(exchange.isVault(vault), true);
    }

    function test_registerVault_revertIfUnauthorized() public {
        address malicious = makeAddr("malicious");
        bytes32 role = Roles.GENERAL_ROLE;
        bytes memory signature;

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );

        vm.prank(malicious);
        exchange.registerVault(vault, feeRecipient, profitShareBps, signature);

        vm.expectRevert(Errors.Unauthorized.selector);

        vm.prank(malicious);
        vaultManager.registerVault(vault, feeRecipient, profitShareBps, signature);
    }

    function test_registerVault_revertIfVaultAlreadyRegistered() public {
        bytes32 structHash = keccak256(abi.encode(REGISTER_VAULT_TYPEHASH, vault, feeRecipient, profitShareBps));
        bytes memory signature = _signTypedDataHash(vaultPrivKey, structHash);

        vm.prank(sequencer);
        exchange.registerVault(vault, feeRecipient, profitShareBps, signature);

        vm.expectRevert(abi.encodeWithSelector(Errors.Vault_AlreadyRegistered.selector, vault));

        vm.prank(address(exchange));
        vaultManager.registerVault(vault, feeRecipient, profitShareBps, signature);

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_InvalidAccountType.selector, vault));

        vm.prank(sequencer);
        exchange.registerVault(vault, feeRecipient, profitShareBps, signature);
    }

    function test_registerVault_revertIfInvalidVaultAddress() public {
        bytes32 structHash = keccak256(abi.encode(REGISTER_VAULT_TYPEHASH, vault, feeRecipient, profitShareBps));
        bytes memory signature = _signTypedDataHash(vaultPrivKey, structHash);
        vm.prank(sequencer);
        exchange.registerVault(vault, feeRecipient, profitShareBps, signature);

        // feeRecipient is already registered
        vault = feeRecipient;
        feeRecipient = makeAddr("newFeeRecipient");
        vm.expectRevert(abi.encodeWithSelector(Errors.Vault_InvalidVaultAddress.selector, vault));
        vm.prank(sequencer);
        exchange.registerVault(vault, feeRecipient, profitShareBps, signature);
    }

    function test_registerVault_revertIfInvalidFeeRecipient() public {
        (address newVault, uint256 newVaultPrivKey) = makeAddrAndKey("newVault");
        bytes32 structHash = keccak256(abi.encode(REGISTER_VAULT_TYPEHASH, newVault, feeRecipient, profitShareBps));
        bytes memory signature = _signTypedDataHash(newVaultPrivKey, structHash);
        vm.prank(sequencer);
        exchange.registerVault(newVault, feeRecipient, profitShareBps, signature);

        // feeRecipient is already registered
        feeRecipient = newVault;
        vm.expectRevert(abi.encodeWithSelector(Errors.Vault_InvalidFeeRecipient.selector, vault, feeRecipient));
        vm.prank(sequencer);
        exchange.registerVault(vault, feeRecipient, profitShareBps, signature);

        // feeRecipient is the same as vault
        feeRecipient = vault;
        vm.expectRevert(abi.encodeWithSelector(Errors.Vault_InvalidFeeRecipient.selector, vault, feeRecipient));
        vm.prank(sequencer);
        exchange.registerVault(vault, feeRecipient, profitShareBps, signature);
    }

    function test_registerVault_revertIfInvalidProfitShareBps() public {
        profitShareBps = 10_001;
        bytes32 structHash = keccak256(abi.encode(REGISTER_VAULT_TYPEHASH, vault, feeRecipient, profitShareBps));
        bytes memory signature = _signTypedDataHash(vaultPrivKey, structHash);

        vm.expectRevert(abi.encodeWithSelector(Errors.Vault_InvalidProfitShareBps.selector, vault, profitShareBps));

        vm.prank(sequencer);
        exchange.registerVault(vault, feeRecipient, profitShareBps, signature);
    }

    function test_registerVault_revertIfInvalidSignature() public {
        bytes32 structHash = keccak256(abi.encode(REGISTER_VAULT_TYPEHASH, vault, feeRecipient, profitShareBps));
        bytes memory signature = _signTypedDataHash(vaultPrivKey, structHash);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, vault));

        vm.prank(sequencer);
        exchange.registerVault(vault, feeRecipient, profitShareBps + 1, signature);
    }

    function test_registerVault_revertIfVaultBalanceIsNotZero() public {
        bytes32 structHash = keccak256(abi.encode(REGISTER_VAULT_TYPEHASH, vault, feeRecipient, profitShareBps));
        bytes memory signature = _signTypedDataHash(vaultPrivKey, structHash);

        _depositExchange(collateralToken1, vault, 1);

        vm.expectRevert(abi.encodeWithSelector(Errors.Vault_NotZeroBalance.selector, vault, collateralToken1, 1));

        vm.prank(sequencer);
        exchange.registerVault(vault, feeRecipient, profitShareBps, signature);
    }

    function test_stake_success() public {
        _registerVault();
        _depositExchange(asset, staker, 100 ether);

        uint256 nonce = 123;
        uint256 stakeAmount = 25 ether;

        bytes32 structHash =
            keccak256(abi.encode(STAKE_VAULT_TYPEHASH, vault, staker, address(asset), stakeAmount, nonce));
        bytes memory signature = _signTypedDataHash(stakerPrivKey, structHash);
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.StakeVault,
            abi.encode(
                IExchange.StakeVaultParams({
                    vault: vault,
                    account: staker,
                    token: address(asset),
                    amount: stakeAmount,
                    nonce: nonce,
                    signature: signature
                })
            )
        );

        uint256 expectedShares = 25 ether;

        assertEq(vaultManager.vaultCount(staker), 0);

        vm.expectEmit(address(exchange));
        emit IExchange.StakeVault(
            vault, staker, nonce, address(asset), stakeAmount, expectedShares, IExchange.VaultActionStatus.Success
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(vaultManager.vaultCount(staker), 1);
        assertEq(exchange.isStakeVaultNonceUsed(staker, nonce), true);

        IVaultManager.StakerData memory stakerData = vaultManager.getStakerData(vault, staker);
        assertEq(stakerData.shares, expectedShares);
        assertEq(stakerData.avgPrice, 1 ether);

        IVaultManager.VaultData memory vaultData = vaultManager.getVaultData(vault);
        assertEq(vaultData.totalShares, expectedShares);

        assertEq(exchange.balanceOf(staker, address(asset)), 75 ether);
        assertEq(exchange.balanceOf(vault, address(asset)), 25 ether);
    }

    function test_stake_multipleTimes_success() public {
        _registerVault();

        uint256 stakerTokenBalance = 500 ether;
        _depositExchange(asset, staker, stakerTokenBalance);

        uint256 nonce = 1;
        uint256 stakeAmount1 = 25 ether;
        uint256 expectedShares1 = 25 ether;
        bytes32 structHash =
            keccak256(abi.encode(STAKE_VAULT_TYPEHASH, vault, staker, address(asset), stakeAmount1, nonce));
        bytes memory signature = _signTypedDataHash(stakerPrivKey, structHash);
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.StakeVault,
            abi.encode(
                IExchange.StakeVaultParams({
                    vault: vault,
                    account: staker,
                    token: address(asset),
                    amount: stakeAmount1,
                    nonce: nonce,
                    signature: signature
                })
            )
        );

        // 1. stake 25 ether
        vm.expectEmit(address(exchange));
        emit IExchange.StakeVault(
            vault, staker, nonce, address(asset), stakeAmount1, expectedShares1, IExchange.VaultActionStatus.Success
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(vaultManager.vaultCount(staker), 1);
        assertEq(exchange.isStakeVaultNonceUsed(staker, nonce), true);
        IVaultManager.StakerData memory stakerData = vaultManager.getStakerData(vault, staker);
        assertEq(stakerData.shares, expectedShares1);
        assertEq(stakerData.avgPrice, 1 ether);
        IVaultManager.VaultData memory vaultData = vaultManager.getVaultData(vault);
        assertEq(vaultData.totalShares, expectedShares1);
        assertEq(exchange.balanceOf(staker, address(asset)), int256(stakerTokenBalance - stakeAmount1));
        assertEq(exchange.balanceOf(vault, address(asset)), int256(stakeAmount1));

        // 2. stake 50 ether
        nonce = 2;
        uint256 stakeAmount2 = 50 ether;
        uint256 expectedShares2 = 50 ether;
        structHash = keccak256(abi.encode(STAKE_VAULT_TYPEHASH, vault, staker, address(asset), stakeAmount2, nonce));
        signature = _signTypedDataHash(stakerPrivKey, structHash);
        operation = _encodeDataToOperation(
            IExchange.OperationType.StakeVault,
            abi.encode(
                IExchange.StakeVaultParams({
                    vault: vault,
                    account: staker,
                    token: address(asset),
                    amount: stakeAmount2,
                    nonce: nonce,
                    signature: signature
                })
            )
        );

        vm.expectEmit(address(exchange));
        emit IExchange.StakeVault(
            vault, staker, nonce, address(asset), stakeAmount2, expectedShares2, IExchange.VaultActionStatus.Success
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(vaultManager.vaultCount(staker), 1);
        assertEq(exchange.isStakeVaultNonceUsed(staker, nonce), true);
        stakerData = vaultManager.getStakerData(vault, staker);
        assertEq(stakerData.shares, expectedShares1 + expectedShares2);
        assertEq(stakerData.avgPrice, 1 ether);
        vaultData = vaultManager.getVaultData(vault);
        assertEq(vaultData.totalShares, expectedShares1 + expectedShares2);
        assertEq(exchange.balanceOf(staker, address(asset)), int256(stakerTokenBalance - stakeAmount1 - stakeAmount2));
        assertEq(exchange.balanceOf(vault, address(asset)), int256(stakeAmount1 + stakeAmount2));

        // current vault balance = 75 ether
        // x2 vault balance = 150 ether => price = 2 ether
        uint256 increasedAmount = 75 ether;
        vm.prank(address(clearingService));
        spotEngine.updateBalance(vault, address(asset), int256(increasedAmount));

        // 3. stake 50 ether
        nonce = 3;
        uint256 stakeAmount3 = 150 ether;
        uint256 expectedShares3 = 75 ether;
        structHash = keccak256(abi.encode(STAKE_VAULT_TYPEHASH, vault, staker, address(asset), stakeAmount3, nonce));
        signature = _signTypedDataHash(stakerPrivKey, structHash);
        operation = _encodeDataToOperation(
            IExchange.OperationType.StakeVault,
            abi.encode(
                IExchange.StakeVaultParams({
                    vault: vault,
                    account: staker,
                    token: address(asset),
                    amount: stakeAmount3,
                    nonce: nonce,
                    signature: signature
                })
            )
        );

        vm.expectEmit(address(exchange));
        emit IExchange.StakeVault(
            vault, staker, nonce, address(asset), stakeAmount3, expectedShares3, IExchange.VaultActionStatus.Success
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(vaultManager.vaultCount(staker), 1);
        assertEq(exchange.isStakeVaultNonceUsed(staker, nonce), true);
        stakerData = vaultManager.getStakerData(vault, staker);
        assertEq(stakerData.shares, expectedShares1 + expectedShares2 + expectedShares3);
        assertEq(stakerData.avgPrice, 1.5 ether);
        vaultData = vaultManager.getVaultData(vault);
        assertEq(vaultData.totalShares, expectedShares1 + expectedShares2 + expectedShares3);
        assertEq(
            exchange.balanceOf(staker, address(asset)),
            int256(stakerTokenBalance - stakeAmount1 - stakeAmount2 - stakeAmount3)
        );
        assertEq(
            exchange.balanceOf(vault, address(asset)),
            int256(stakeAmount1 + stakeAmount2 + stakeAmount3 + increasedAmount)
        );
    }

    function test_stake_revertIfUnauthorized() public {
        _registerVault();

        address malicious = makeAddr("malicious");
        bytes memory signature;

        vm.expectRevert(Errors.Unauthorized.selector);
        vm.prank(malicious);
        vaultManager.stake(vault, staker, address(asset), 0, 0, signature);
    }

    function test_stake_revertIfNotMainAccount() public {
        _registerVault();

        uint256 stakeAmount = 10 ether;
        uint256 nonce = 5;
        bytes32 structHash =
            keccak256(abi.encode(STAKE_VAULT_TYPEHASH, vault, staker, address(asset), stakeAmount, nonce));
        bytes memory signature = _signTypedDataHash(stakerPrivKey, structHash);
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.StakeVault,
            abi.encode(
                IExchange.StakeVaultParams({
                    vault: vault,
                    account: staker,
                    token: address(asset),
                    amount: stakeAmount,
                    nonce: nonce,
                    signature: signature
                })
            )
        );

        vm.mockCall(
            address(exchange),
            abi.encodeWithSelector(IExchange.getAccountType.selector, staker),
            abi.encode(IExchange.AccountType.Subaccount)
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_InvalidAccountType.selector, staker));
        vm.prank(address(exchange));
        vaultManager.stake(vault, staker, address(asset), stakeAmount, nonce, signature);

        uint256 expectedShares = 0;
        vm.expectEmit(address(exchange));
        emit IExchange.StakeVault(
            vault, staker, nonce, address(asset), stakeAmount, expectedShares, IExchange.VaultActionStatus.Failure
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(vaultManager.vaultCount(staker), 0);
        assertEq(exchange.isNonceUsed(staker, nonce), true);
    }

    function test_stake_revertIfVaultNotRegistered() public {
        address notVault = makeAddr("notVault");

        uint256 stakeAmount = 10 ether;
        uint256 nonce = 5;
        bytes memory signature;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.StakeVault,
            abi.encode(
                IExchange.StakeVaultParams({
                    vault: notVault,
                    account: staker,
                    token: address(asset),
                    amount: stakeAmount,
                    nonce: nonce,
                    signature: signature
                })
            )
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.Vault_NotRegistered.selector, notVault));
        vm.prank(address(exchange));
        vaultManager.stake(notVault, staker, address(asset), stakeAmount, nonce, signature);

        uint256 expectedShares = 0;
        vm.expectEmit(address(exchange));
        emit IExchange.StakeVault(
            notVault, staker, nonce, address(asset), stakeAmount, expectedShares, IExchange.VaultActionStatus.Failure
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(vaultManager.vaultCount(staker), 0);
        assertEq(exchange.isNonceUsed(staker, nonce), true);
    }

    function test_stake_revertIfUsedNonce() public {
        _registerVault();
        _depositExchange(asset, staker, 100 ether);

        uint256 stakeAmount = 10 ether;
        uint256 nonce = 5;
        bytes32 structHash =
            keccak256(abi.encode(STAKE_VAULT_TYPEHASH, vault, staker, address(asset), stakeAmount, nonce));
        bytes memory signature = _signTypedDataHash(stakerPrivKey, structHash);
        bytes memory stakeData = abi.encode(
            IExchange.StakeVaultParams({
                vault: vault,
                account: staker,
                token: address(asset),
                amount: stakeAmount,
                nonce: nonce,
                signature: signature
            })
        );
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.StakeVault, stakeData);
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        vm.expectRevert(abi.encodeWithSelector(Errors.Vault_Stake_UsedNonce.selector, staker, nonce));
        vm.prank(address(exchange));
        vaultManager.stake(vault, staker, address(asset), stakeAmount, nonce, signature);

        operation = _encodeDataToOperation(IExchange.OperationType.StakeVault, stakeData);
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_NonceUsed.selector, staker, nonce));
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_stake_revertIfInvalidToken() public {
        _registerVault();
        _depositExchange(collateralToken1, staker, 100 ether);

        uint256 stakeAmount = 10 ether;
        uint256 nonce = 5;
        bytes32 structHash =
            keccak256(abi.encode(STAKE_VAULT_TYPEHASH, vault, staker, address(collateralToken1), stakeAmount, nonce));
        bytes memory signature = _signTypedDataHash(stakerPrivKey, structHash);
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.StakeVault,
            abi.encode(
                IExchange.StakeVaultParams({
                    vault: vault,
                    account: staker,
                    token: address(collateralToken1),
                    amount: stakeAmount,
                    nonce: nonce,
                    signature: signature
                })
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(Errors.Vault_InvalidToken.selector, address(collateralToken1), address(asset))
        );
        vm.prank(address(exchange));
        vaultManager.stake(vault, staker, address(collateralToken1), stakeAmount, nonce, signature);

        uint256 expectedShares = 0;
        vm.expectEmit(address(exchange));
        emit IExchange.StakeVault(
            vault,
            staker,
            nonce,
            address(collateralToken1),
            stakeAmount,
            expectedShares,
            IExchange.VaultActionStatus.Failure
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(vaultManager.vaultCount(staker), 0);
        assertEq(exchange.isNonceUsed(staker, nonce), true);
    }

    function test_stake_revertIfInvalidSignature() public {
        _registerVault();
        _depositExchange(asset, staker, 100 ether);

        uint256 stakeAmount = 10 ether;
        uint256 nonce = 5;
        bytes32 structHash =
            keccak256(abi.encode(STAKE_VAULT_TYPEHASH, vault, staker, address(asset), stakeAmount + 1, nonce));
        bytes memory signature = _signTypedDataHash(stakerPrivKey, structHash);
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.StakeVault,
            abi.encode(
                IExchange.StakeVaultParams({
                    vault: vault,
                    account: staker,
                    token: address(asset),
                    amount: stakeAmount,
                    nonce: nonce,
                    signature: signature
                })
            )
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, staker));
        vm.prank(address(exchange));
        vaultManager.stake(vault, staker, address(asset), stakeAmount, nonce, signature);

        uint256 expectedShares = 0;
        vm.expectEmit(address(exchange));
        emit IExchange.StakeVault(
            vault, staker, nonce, address(asset), stakeAmount, expectedShares, IExchange.VaultActionStatus.Failure
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(vaultManager.vaultCount(staker), 0);
        assertEq(exchange.isNonceUsed(staker, nonce), true);
    }

    function test_stake_revertIfInsufficientBalance() public {
        _registerVault();
        _depositExchange(asset, staker, 5 ether);

        uint256 stakeAmount = 10 ether;
        uint256 nonce = 5;
        bytes32 structHash =
            keccak256(abi.encode(STAKE_VAULT_TYPEHASH, vault, staker, address(asset), stakeAmount, nonce));
        bytes memory signature = _signTypedDataHash(stakerPrivKey, structHash);
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.StakeVault,
            abi.encode(
                IExchange.StakeVaultParams({
                    vault: vault,
                    account: staker,
                    token: address(asset),
                    amount: stakeAmount,
                    nonce: nonce,
                    signature: signature
                })
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(Errors.Vault_Stake_InsufficientBalance.selector, staker, 5 ether, stakeAmount)
        );
        vm.prank(address(exchange));
        vaultManager.stake(vault, staker, address(asset), stakeAmount, nonce, signature);

        uint256 expectedShares = 0;
        vm.expectEmit(address(exchange));
        emit IExchange.StakeVault(
            vault, staker, nonce, address(asset), stakeAmount, expectedShares, IExchange.VaultActionStatus.Failure
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(vaultManager.vaultCount(staker), 0);
        assertEq(exchange.isNonceUsed(staker, nonce), true);
    }

    function test_stake_coverVaultLoss_stakeAmountOverLoss() public {
        _registerVault();
        _depositExchange(asset, staker, 100 ether);

        uint256 loss = 30 ether;
        vm.prank(address(clearingService));
        spotEngine.updateBalance(vault, address(asset), -int256(loss));

        uint256 anyShare = 10 ether;
        assertEq(vaultManager.convertToAssets(vault, anyShare), 0);

        uint256 nonce = 456;
        uint256 stakeAmount = 80 ether;

        bytes32 structHash =
            keccak256(abi.encode(STAKE_VAULT_TYPEHASH, vault, staker, address(asset), stakeAmount, nonce));
        bytes memory signature = _signTypedDataHash(stakerPrivKey, structHash);
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.StakeVault,
            abi.encode(
                IExchange.StakeVaultParams({
                    vault: vault,
                    account: staker,
                    token: address(asset),
                    amount: stakeAmount,
                    nonce: nonce,
                    signature: signature
                })
            )
        );

        uint256 expectedShares = 50 ether;

        vm.expectEmit(address(exchange));
        emit IExchange.CoverLoss(vault, staker, address(asset), loss);

        vm.expectEmit(address(exchange));
        emit IExchange.StakeVault(
            vault, staker, nonce, address(asset), stakeAmount, expectedShares, IExchange.VaultActionStatus.Success
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(vaultManager.vaultCount(staker), 1);
        assertEq(vaultManager.isStakeNonceUsed(staker, nonce), true);

        IVaultManager.StakerData memory stakerData = vaultManager.getStakerData(vault, staker);
        assertEq(stakerData.shares, expectedShares);
        assertEq(stakerData.avgPrice, 1 ether);

        IVaultManager.VaultData memory vaultData = vaultManager.getVaultData(vault);
        assertEq(vaultData.totalShares, expectedShares);

        assertEq(exchange.balanceOf(staker, address(asset)), 20 ether);
        assertEq(exchange.balanceOf(vault, address(asset)), 50 ether);
    }

    function test_stake_coverVaultLoss_revertIfAmountNotCoverLoss() public {
        _registerVault();
        _depositExchange(asset, staker, 100 ether);

        uint256 loss = 90 ether;
        vm.prank(address(clearingService));
        spotEngine.updateBalance(vault, address(asset), -int256(loss));

        uint256 nonce = 456;
        uint256 stakeAmount = 80 ether;

        bytes32 structHash =
            keccak256(abi.encode(STAKE_VAULT_TYPEHASH, vault, staker, address(asset), stakeAmount, nonce));
        bytes memory signature = _signTypedDataHash(stakerPrivKey, structHash);
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.StakeVault,
            abi.encode(
                IExchange.StakeVaultParams({
                    vault: vault,
                    account: staker,
                    token: address(asset),
                    amount: stakeAmount,
                    nonce: nonce,
                    signature: signature
                })
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(Errors.Vault_CoverLoss_InsufficientAmount.selector, vault, staker, loss, stakeAmount)
        );
        vm.prank(address(exchange));
        vaultManager.stake(vault, staker, address(asset), stakeAmount, nonce, signature);

        vm.expectEmit(address(exchange));
        emit IExchange.StakeVault(
            vault, staker, nonce, address(asset), stakeAmount, 0, IExchange.VaultActionStatus.Failure
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_unstake_withNoProfit_success() public {
        _registerVault();
        _depositExchange(asset, staker, 100 ether);

        uint256 nonce = 123;
        uint256 stakeAmount = 100 ether;

        // 1. stake 100 ether with price 1 ether
        bytes32 structHash =
            keccak256(abi.encode(STAKE_VAULT_TYPEHASH, vault, staker, address(asset), stakeAmount, nonce));
        bytes memory signature = _signTypedDataHash(stakerPrivKey, structHash);
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.StakeVault,
            abi.encode(
                IExchange.StakeVaultParams({
                    vault: vault,
                    account: staker,
                    token: address(asset),
                    amount: stakeAmount,
                    nonce: nonce,
                    signature: signature
                })
            )
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        // 2. unstake 60 ether with price 1 ether => 60 shares
        nonce = 345;
        uint256 unstakeAmount = 60 ether;
        uint256 expectedShares = 60 ether;
        uint256 expectedFee = 0;
        assertEq(vaultManager.convertToShares(vault, unstakeAmount), expectedShares);
        assertEq(vaultManager.convertToAssets(vault, expectedShares), unstakeAmount);

        structHash = keccak256(abi.encode(UNSTAKE_VAULT_TYPEHASH, vault, staker, address(asset), unstakeAmount, nonce));
        signature = _signTypedDataHash(stakerPrivKey, structHash);
        operation = _encodeDataToOperation(
            IExchange.OperationType.UnstakeVault,
            abi.encode(
                IExchange.UnstakeVaultParams({
                    vault: vault,
                    account: staker,
                    token: address(asset),
                    amount: unstakeAmount,
                    nonce: nonce,
                    signature: signature
                })
            )
        );

        vm.expectEmit(address(exchange));
        emit IExchange.UnstakeVault(
            vault,
            staker,
            nonce,
            address(asset),
            unstakeAmount,
            expectedShares,
            expectedFee,
            address(0),
            IExchange.VaultActionStatus.Success
        );

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(vaultManager.vaultCount(staker), 1);
        assertEq(exchange.isUnstakeVaultNonceUsed(staker, nonce), true);

        IVaultManager.StakerData memory stakerData = vaultManager.getStakerData(vault, staker);
        assertEq(stakerData.shares, 40 ether);
        assertEq(stakerData.avgPrice, 1 ether);

        IVaultManager.VaultData memory vaultData = vaultManager.getVaultData(vault);
        assertEq(vaultData.totalShares, 40 ether);

        assertEq(exchange.balanceOf(vault, address(asset)), 40 ether);
        assertEq(exchange.balanceOf(staker, address(asset)), 60 ether);
        assertEq(exchange.balanceOf(feeRecipient, address(asset)), int256(expectedFee));

        // 3. unstake 40 ether with price 1 ether => 40 shares
        nonce = 456;
        unstakeAmount = 40 ether;
        expectedShares = 40 ether;
        structHash = keccak256(abi.encode(UNSTAKE_VAULT_TYPEHASH, vault, staker, address(asset), unstakeAmount, nonce));
        signature = _signTypedDataHash(stakerPrivKey, structHash);
        operation = _encodeDataToOperation(
            IExchange.OperationType.UnstakeVault,
            abi.encode(
                IExchange.UnstakeVaultParams({
                    vault: vault,
                    account: staker,
                    token: address(asset),
                    amount: unstakeAmount,
                    nonce: nonce,
                    signature: signature
                })
            )
        );

        vm.expectEmit(address(exchange));
        emit IExchange.UnstakeVault(
            vault,
            staker,
            nonce,
            address(asset),
            unstakeAmount,
            expectedShares,
            expectedFee,
            address(0),
            IExchange.VaultActionStatus.Success
        );

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(vaultManager.vaultCount(staker), 0);
        assertEq(exchange.isUnstakeVaultNonceUsed(staker, nonce), true);

        stakerData = vaultManager.getStakerData(vault, staker);
        assertEq(stakerData.shares, 0);
        assertEq(stakerData.avgPrice, 1 ether);

        vaultData = vaultManager.getVaultData(vault);
        assertEq(vaultData.totalShares, 0);

        assertEq(exchange.balanceOf(vault, address(asset)), 0);
        assertEq(exchange.balanceOf(staker, address(asset)), int256(stakeAmount));
        assertEq(exchange.balanceOf(feeRecipient, address(asset)), 0);
    }

    function test_unstake_withProfit_success() public {
        _registerVault();
        _depositExchange(asset, staker, 100 ether);

        uint256 nonce = 123;
        uint256 stakeAmount = 100 ether;

        // stake 100 ether with price 1 ether
        bytes32 structHash =
            keccak256(abi.encode(STAKE_VAULT_TYPEHASH, vault, staker, address(asset), stakeAmount, nonce));
        bytes memory signature = _signTypedDataHash(stakerPrivKey, structHash);
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.StakeVault,
            abi.encode(
                IExchange.StakeVaultParams({
                    vault: vault,
                    account: staker,
                    token: address(asset),
                    amount: stakeAmount,
                    nonce: nonce,
                    signature: signature
                })
            )
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        // vault balance grows to 150 ether
        uint256 increasedAmount = 50 ether;
        vm.prank(address(clearingService));
        spotEngine.updateBalance(vault, address(asset), int256(increasedAmount));

        // unstake 60 ether with price 1.5 ether => 40 shares
        nonce = 345;
        uint256 fee = 2 ether;
        uint256 unstakeAmount = 60 ether;
        uint256 expectedShares = 40 ether;
        uint256 expectedFee = 2 ether;
        structHash = keccak256(abi.encode(UNSTAKE_VAULT_TYPEHASH, vault, staker, address(asset), unstakeAmount, nonce));
        signature = _signTypedDataHash(stakerPrivKey, structHash);
        operation = _encodeDataToOperation(
            IExchange.OperationType.UnstakeVault,
            abi.encode(
                IExchange.UnstakeVaultParams({
                    vault: vault,
                    account: staker,
                    token: address(asset),
                    amount: unstakeAmount,
                    nonce: nonce,
                    signature: signature
                })
            )
        );

        vm.expectEmit(address(exchange));
        emit IExchange.UnstakeVault(
            vault,
            staker,
            nonce,
            address(asset),
            unstakeAmount,
            expectedShares,
            expectedFee,
            feeRecipient,
            IExchange.VaultActionStatus.Success
        );

        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        assertEq(vaultManager.vaultCount(staker), 1);
        assertEq(exchange.isUnstakeVaultNonceUsed(staker, nonce), true);

        IVaultManager.StakerData memory stakerData = vaultManager.getStakerData(vault, staker);
        assertEq(stakerData.shares, 60 ether);
        assertEq(stakerData.avgPrice, 1 ether);

        IVaultManager.VaultData memory vaultData = vaultManager.getVaultData(vault);
        assertEq(vaultData.totalShares, 60 ether);

        assertEq(exchange.balanceOf(vault, address(asset)), 90 ether);
        assertEq(exchange.balanceOf(staker, address(asset)), int256(60 ether - fee));
        assertEq(exchange.balanceOf(feeRecipient, address(asset)), int256(fee));
    }

    function test_unstake_revertIfUnauthorized() public {
        _registerVault();

        address malicious = makeAddr("malicious");
        bytes memory signature;

        vm.expectRevert(Errors.Unauthorized.selector);
        vm.prank(malicious);
        vaultManager.unstake(vault, staker, address(asset), 0, 0, signature);
    }

    function test_unstake_revertIfVaultNotRegistered() public {
        address notVault = makeAddr("notVault");

        uint256 unstakeAmount = 10 ether;
        uint256 nonce = 5;
        bytes memory signature;
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.UnstakeVault,
            abi.encode(
                IExchange.UnstakeVaultParams({
                    vault: notVault,
                    account: staker,
                    token: address(asset),
                    amount: unstakeAmount,
                    nonce: nonce,
                    signature: signature
                })
            )
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.Vault_NotRegistered.selector, notVault));
        vm.prank(address(exchange));
        vaultManager.unstake(notVault, staker, address(asset), unstakeAmount, nonce, signature);

        uint256 expectedFee = 0;
        uint256 expectedShares = 0;
        vm.expectEmit(address(exchange));
        emit IExchange.UnstakeVault(
            notVault,
            staker,
            nonce,
            address(asset),
            unstakeAmount,
            expectedShares,
            expectedFee,
            address(0),
            IExchange.VaultActionStatus.Failure
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_unstake_revertIfUsedNonce() public {
        _registerVault();
        _depositExchange(asset, staker, 100 ether);

        // stake
        uint256 stakeAmount = 10 ether;
        uint256 nonce = 5;
        bytes32 structHash =
            keccak256(abi.encode(STAKE_VAULT_TYPEHASH, vault, staker, address(asset), stakeAmount, nonce));
        bytes memory signature = _signTypedDataHash(stakerPrivKey, structHash);
        vm.prank(address(exchange));
        vaultManager.stake(vault, staker, address(asset), stakeAmount, nonce, signature);

        // unstake
        uint256 unstakeAmount = 5 ether;
        structHash = keccak256(abi.encode(UNSTAKE_VAULT_TYPEHASH, vault, staker, address(asset), unstakeAmount, nonce));
        signature = _signTypedDataHash(stakerPrivKey, structHash);
        bytes memory unstakeData = abi.encode(
            IExchange.UnstakeVaultParams({
                vault: vault,
                account: staker,
                token: address(asset),
                amount: unstakeAmount,
                nonce: nonce,
                signature: signature
            })
        );
        bytes memory operation = _encodeDataToOperation(IExchange.OperationType.UnstakeVault, unstakeData);
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());

        vm.expectRevert(abi.encodeWithSelector(Errors.Vault_Unstake_UsedNonce.selector, staker, nonce));
        vm.prank(address(exchange));
        vaultManager.unstake(vault, staker, address(asset), unstakeAmount, nonce, signature);

        operation = _encodeDataToOperation(IExchange.OperationType.UnstakeVault, unstakeData);
        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_NonceUsed.selector, staker, nonce));
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_unstake_revertIfInvalidToken() public {
        _registerVault();
        _depositExchange(asset, staker, 100 ether);

        // stake
        uint256 stakeAmount = 10 ether;
        uint256 nonce = 5;
        bytes32 structHash =
            keccak256(abi.encode(STAKE_VAULT_TYPEHASH, vault, staker, address(asset), stakeAmount, nonce));
        bytes memory signature = _signTypedDataHash(stakerPrivKey, structHash);
        vm.prank(address(exchange));
        vaultManager.stake(vault, staker, address(asset), stakeAmount, nonce, signature);

        // unstake
        uint256 unstakeAmount = 5 ether;
        address invalidToken = makeAddr("invalidToken");
        structHash = keccak256(abi.encode(UNSTAKE_VAULT_TYPEHASH, vault, staker, invalidToken, unstakeAmount, nonce));
        signature = _signTypedDataHash(stakerPrivKey, structHash);
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.UnstakeVault,
            abi.encode(
                IExchange.UnstakeVaultParams({
                    vault: vault,
                    account: staker,
                    token: invalidToken,
                    amount: unstakeAmount,
                    nonce: nonce,
                    signature: signature
                })
            )
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.Vault_InvalidToken.selector, invalidToken, address(asset)));
        vm.prank(address(exchange));
        vaultManager.unstake(vault, staker, invalidToken, unstakeAmount, nonce, signature);

        uint256 expectedShares = 0;
        uint256 expectedFee = 0;
        vm.expectEmit(address(exchange));
        emit IExchange.UnstakeVault(
            vault,
            staker,
            nonce,
            invalidToken,
            unstakeAmount,
            expectedShares,
            expectedFee,
            address(0),
            IExchange.VaultActionStatus.Failure
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_unstake_revertIfInvalidSignature() public {
        _registerVault();
        _depositExchange(asset, staker, 100 ether);

        // stake
        uint256 stakeAmount = 10 ether;
        uint256 nonce = 5;
        bytes32 structHash =
            keccak256(abi.encode(STAKE_VAULT_TYPEHASH, vault, staker, address(asset), stakeAmount, nonce));
        bytes memory signature = _signTypedDataHash(stakerPrivKey, structHash);
        vm.prank(address(exchange));
        vaultManager.stake(vault, staker, address(asset), stakeAmount, nonce, signature);

        // unstake
        uint256 unstakeAmount = 5 ether;
        structHash =
            keccak256(abi.encode(UNSTAKE_VAULT_TYPEHASH, vault, staker, address(asset), unstakeAmount + 1, nonce));
        signature = _signTypedDataHash(stakerPrivKey, structHash);
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.UnstakeVault,
            abi.encode(
                IExchange.UnstakeVaultParams({
                    vault: vault,
                    account: staker,
                    token: address(asset),
                    amount: unstakeAmount,
                    nonce: nonce,
                    signature: signature
                })
            )
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, staker));
        vm.prank(address(exchange));
        vaultManager.unstake(vault, staker, address(asset), unstakeAmount, nonce, signature);

        uint256 expectedShares = 0;
        uint256 expectedFee = 0;
        vm.expectEmit(address(exchange));
        emit IExchange.UnstakeVault(
            vault,
            staker,
            nonce,
            address(asset),
            unstakeAmount,
            expectedShares,
            expectedFee,
            address(0),
            IExchange.VaultActionStatus.Failure
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_unstake_revertIfInsufficientShares() public {
        _registerVault();
        _depositExchange(asset, staker, 100 ether);

        // stake
        uint256 stakeAmount = 10 ether;
        uint256 nonce = 5;
        bytes32 structHash =
            keccak256(abi.encode(STAKE_VAULT_TYPEHASH, vault, staker, address(asset), stakeAmount, nonce));
        bytes memory signature = _signTypedDataHash(stakerPrivKey, structHash);
        vm.prank(address(exchange));
        vaultManager.stake(vault, staker, address(asset), stakeAmount, nonce, signature);

        // unstake
        uint256 unstakeAmount = stakeAmount + 1;
        structHash = keccak256(abi.encode(UNSTAKE_VAULT_TYPEHASH, vault, staker, address(asset), unstakeAmount, nonce));
        signature = _signTypedDataHash(stakerPrivKey, structHash);
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.UnstakeVault,
            abi.encode(
                IExchange.UnstakeVaultParams({
                    vault: vault,
                    account: staker,
                    token: address(asset),
                    amount: unstakeAmount,
                    nonce: nonce,
                    signature: signature
                })
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(Errors.Vault_Unstake_InsufficientShares.selector, staker, 10 ether, 10 ether + 1)
        );
        vm.prank(address(exchange));
        vaultManager.unstake(vault, staker, address(asset), unstakeAmount, nonce, signature);

        uint256 expectedShares = 0;
        uint256 expectedFee = 0;
        vm.expectEmit(address(exchange));
        emit IExchange.UnstakeVault(
            vault,
            staker,
            nonce,
            address(asset),
            unstakeAmount,
            expectedShares,
            expectedFee,
            address(0),
            IExchange.VaultActionStatus.Failure
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function test_unstake_revertIfVaultBalanceIsNegative() public {
        _registerVault();
        _depositExchange(asset, staker, 100 ether);

        // stake 80 ether, vault balance = 80 ether
        uint256 nonce = 456;
        uint256 stakeAmount = 80 ether;
        bytes32 structHash =
            keccak256(abi.encode(STAKE_VAULT_TYPEHASH, vault, staker, address(asset), stakeAmount, nonce));
        bytes memory signature = _signTypedDataHash(stakerPrivKey, structHash);
        vm.prank(address(exchange));
        vaultManager.stake(vault, staker, address(asset), stakeAmount, nonce, signature);

        // vault balance = -20 ether
        uint256 loss = 100 ether;
        vm.prank(address(clearingService));
        spotEngine.updateBalance(vault, address(asset), -int256(loss));

        uint256 unstakeAmount = 1;
        structHash = keccak256(abi.encode(UNSTAKE_VAULT_TYPEHASH, vault, staker, address(asset), unstakeAmount, nonce));
        signature = _signTypedDataHash(stakerPrivKey, structHash);
        bytes memory operation = _encodeDataToOperation(
            IExchange.OperationType.UnstakeVault,
            abi.encode(
                IExchange.UnstakeVaultParams({
                    vault: vault,
                    account: staker,
                    token: address(asset),
                    amount: unstakeAmount,
                    nonce: nonce,
                    signature: signature
                })
            )
        );

        vm.expectRevert(Errors.Vault_NegativeBalance.selector);
        vm.prank(address(exchange));
        vaultManager.unstake(vault, staker, address(asset), unstakeAmount, nonce, signature);

        uint256 expectedShares = 0;
        uint256 expectedFee = 0;
        vm.expectEmit(address(exchange));
        emit IExchange.UnstakeVault(
            vault,
            staker,
            nonce,
            address(asset),
            unstakeAmount,
            expectedShares,
            expectedFee,
            address(0),
            IExchange.VaultActionStatus.Failure
        );
        vm.prank(sequencer);
        exchange.processBatch(operation.toArray());
    }

    function _depositExchange(ERC20Simple token, address account, uint256 amount) private {
        token.approve(address(exchange), type(uint256).max);
        uint256 rawAmount = Helper.convertFrom18D(amount, token.decimals());
        token.mint(address(this), rawAmount);
        exchange.deposit(account, address(token), uint128(amount));
    }

    function _encodeDataToOperation(IExchange.OperationType operationType, bytes memory data)
        private
        view
        returns (bytes memory)
    {
        uint32 transactionId = exchange.executedTransactionCounter();
        return abi.encodePacked(operationType, transactionId, data);
    }

    function _registerVault() private {
        bytes32 structHash = keccak256(abi.encode(REGISTER_VAULT_TYPEHASH, vault, feeRecipient, profitShareBps));
        bytes memory signature = _signTypedDataHash(vaultPrivKey, structHash);
        vm.prank(sequencer);
        exchange.registerVault(vault, feeRecipient, profitShareBps, signature);
    }

    function _signTypedDataHash(uint256 privateKey, bytes32 structHash) private view returns (bytes memory) {
        return Helper.signTypedDataHash(exchange, privateKey, structHash);
    }
}

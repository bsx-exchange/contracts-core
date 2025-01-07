// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {Helper} from "../Helper.sol";
import {ERC20Simple} from "../mock/ERC20Simple.sol";
import {UniversalSigValidator} from "../mock/UniversalSigValidator.sol";

import {ClearingService} from "contracts/exchange/ClearingService.sol";
import {Exchange, IExchange} from "contracts/exchange/Exchange.sol";
import {ISpot, Spot} from "contracts/exchange/Spot.sol";
import {IVaultManager, VaultManager} from "contracts/exchange/VaultManager.sol";
import {Access} from "contracts/exchange/access/Access.sol";
import {Errors} from "contracts/exchange/lib/Errors.sol";
import {UNIVERSAL_SIG_VALIDATOR} from "contracts/exchange/share/Constants.sol";

contract VaultManagerTest is Test {
    using stdStorage for StdStorage;

    address private sequencer = makeAddr("sequencer");
    address private vault;
    uint256 private vaultPrivKey;
    address private feeRecipient = makeAddr("feeRecipient");
    uint256 private profitShareBps = 1000; // 10%

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

    function setUp() public {
        vm.startPrank(sequencer);

        (vault, vaultPrivKey) = makeAddrAndKey("vault");

        bytes memory code = address(new UniversalSigValidator()).code;
        vm.etch(address(UNIVERSAL_SIG_VALIDATOR), code);

        access = new Access();
        stdstore.target(address(access)).sig("hasRole(bytes32,address)").with_key(access.ADMIN_ROLE()).with_key(
            sequencer
        ).checked_write(true);
        access.grantRole(access.GENERAL_ROLE(), sequencer);
        access.grantRole(access.BATCH_OPERATOR_ROLE(), sequencer);

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

        exchange.addSupportedToken(address(collateralToken1));
        exchange.addSupportedToken(address(collateralToken2));

        vm.stopPrank();
    }

    function test_registerVault_success() public {
        bytes32 structHash = keccak256(abi.encode(REGISTER_VAULT_TYPEHASH, vault, feeRecipient, profitShareBps));
        bytes memory signature = _signTypedData(vaultPrivKey, structHash);

        vm.expectEmit(address(vaultManager));
        emit IVaultManager.RegisterVault(vault, feeRecipient, profitShareBps);

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
        bytes32 role = access.GENERAL_ROLE();
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
        bytes memory signature = _signTypedData(vaultPrivKey, structHash);

        vm.prank(sequencer);
        exchange.registerVault(vault, feeRecipient, profitShareBps, signature);

        vm.expectRevert(abi.encodeWithSelector(Errors.Vault_AlreadyRegistered.selector, vault));

        vm.prank(sequencer);
        exchange.registerVault(vault, feeRecipient, profitShareBps, signature);
    }

    function test_registerVault_revertIfInvalidVaultAddress() public {
        bytes32 structHash = keccak256(abi.encode(REGISTER_VAULT_TYPEHASH, vault, feeRecipient, profitShareBps));
        bytes memory signature = _signTypedData(vaultPrivKey, structHash);
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
        bytes memory signature = _signTypedData(newVaultPrivKey, structHash);
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
        bytes memory signature = _signTypedData(vaultPrivKey, structHash);

        vm.expectRevert(abi.encodeWithSelector(Errors.Vault_InvalidProfitShareBps.selector, vault, profitShareBps));

        vm.prank(sequencer);
        exchange.registerVault(vault, feeRecipient, profitShareBps, signature);
    }

    function test_registerVault_revertIfInvalidSignature() public {
        bytes32 structHash = keccak256(abi.encode(REGISTER_VAULT_TYPEHASH, vault, feeRecipient, profitShareBps));
        bytes memory signature = _signTypedData(vaultPrivKey, structHash);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, vault));

        vm.prank(sequencer);
        exchange.registerVault(vault, feeRecipient, profitShareBps + 1, signature);
    }

    function test_registerVault_revertIfVaultBalanceIsNotZero() public {
        bytes32 structHash = keccak256(abi.encode(REGISTER_VAULT_TYPEHASH, vault, feeRecipient, profitShareBps));
        bytes memory signature = _signTypedData(vaultPrivKey, structHash);

        _depositExchange(collateralToken1, vault, 1);

        vm.expectRevert(abi.encodeWithSelector(Errors.Vault_NotZeroBalance.selector, vault, collateralToken1, 1));

        vm.prank(sequencer);
        exchange.registerVault(vault, feeRecipient, profitShareBps, signature);
    }

    function _signTypedData(uint256 privateKey, bytes32 structHash) private view returns (bytes memory) {
        return Helper.signTypedDataHash(exchange, privateKey, structHash);
    }

    function _depositExchange(ERC20Simple token, address account, uint256 amount) private {
        token.mint(address(this), amount);
        token.approve(address(exchange), type(uint256).max);
        uint256 depositAmount = Helper.convertTo18D(amount, token.decimals());
        exchange.deposit(account, address(token), uint128(depositAmount));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IBSX1000x} from "../../../1000x/interfaces/IBSX1000x.sol";
import {Access} from "../../access/Access.sol";
import {IClearingService} from "../../interfaces/IClearingService.sol";
import {IExchange} from "../../interfaces/IExchange.sol";
import {IPerp} from "../../interfaces/IPerp.sol";
import {ISpot} from "../../interfaces/ISpot.sol";
import {Errors} from "../../lib/Errors.sol";
import {UNIVERSAL_SIG_VALIDATOR, ZERO_ADDRESS, ZERO_NONCE} from "../../share/Constants.sol";
import {TxStatus} from "../../share/Enums.sol";

library AccountLogic {
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant CREATE_SUBACCOUNT_TYPEHASH = keccak256("CreateSubaccount(address main,address subaccount)");
    bytes32 public constant DELETE_SUBACCOUNT_TYPEHASH = keccak256("DeleteSubaccount(address main,address subaccount)");

    function createSubaccount(
        mapping(address => IExchange.Account) storage accounts,
        Access access,
        IExchange exchange,
        address main,
        address subaccount,
        bytes memory mainSignature,
        bytes memory subSignature
    ) external {
        if (main == subaccount) {
            revert Errors.Exchange_Subaccount_SameAsMainAccount(subaccount);
        }

        // Check if the main/sub account are main accounts
        if (accounts[main].accountType != IExchange.AccountType.Main) {
            revert Errors.Exchange_InvalidAccountType(main);
        }
        if (accounts[subaccount].accountType != IExchange.AccountType.Main) {
            revert Errors.Exchange_InvalidAccountType(subaccount);
        }

        // Check if subaccount is not a main account
        if (accounts[subaccount].subaccounts.length > 0) {
            revert Errors.Exchange_Subaccount_IsMainAccount(subaccount);
        }

        // Check if the subaccount has no balance in BSX1000
        IBSX1000x bsx1000 = access.getBsx1000();
        IBSX1000x.Balance memory bsx1000Balance = bsx1000.getBalance(subaccount);
        if (bsx1000Balance.available != 0 || bsx1000Balance.locked != 0) {
            revert Errors.Exchange_Subaccount_BSX1000_NonzeroBalance(subaccount, address(bsx1000.collateralToken()));
        }

        // Check if the subaccount has no balance in BSX perp exchange
        ISpot spotEngine = access.getSpotEngine();
        IClearingService clearingService = access.getClearingService();
        address[] memory supportedTokens = exchange.getSupportedTokenList();
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            int256 balance = spotEngine.getBalance(token, subaccount);
            if (balance != 0) {
                revert Errors.Exchange_Subaccount_Exchange_NonzeroBalance(subaccount, token);
            }

            // Check if the subaccount has no balance in yield asset
            address yieldAsset = clearingService.yieldAssets(token);
            if (yieldAsset != ZERO_ADDRESS) {
                int256 yieldBalance = spotEngine.getBalance(yieldAsset, subaccount);
                if (yieldBalance != 0) {
                    revert Errors.Exchange_Subaccount_Exchange_NonzeroBalance(subaccount, yieldAsset);
                }
            }
        }

        if (access.getVaultManager().vaultCount(subaccount) > 0) {
            revert Errors.Exchange_Subaccount_JoinedVault(subaccount);
        }

        bytes32 hash = exchange.hashTypedDataV4(keccak256(abi.encode(CREATE_SUBACCOUNT_TYPEHASH, main, subaccount)));
        if (!UNIVERSAL_SIG_VALIDATOR.isValidSig(main, hash, mainSignature)) {
            revert Errors.Exchange_InvalidSignature(main);
        }
        if (!UNIVERSAL_SIG_VALIDATOR.isValidSig(subaccount, hash, subSignature)) {
            revert Errors.Exchange_InvalidSignature(subaccount);
        }

        IExchange.Account storage mainAccountData = accounts[main];
        mainAccountData.subaccounts.push(subaccount);

        IExchange.Account storage subaccountData = accounts[subaccount];
        subaccountData.main = main;
        subaccountData.accountType = IExchange.AccountType.Subaccount;

        emit IExchange.CreateSubaccount(main, subaccount);
    }

    function deleteSubaccount(
        mapping(address => IExchange.Account) storage accounts,
        Access access,
        IExchange exchange,
        IExchange.DeleteSubaccountParams memory params
    ) external {
        address main = params.main;
        address subaccount = params.subaccount;

        // Check if the main/sub account are main accounts
        if (accounts[main].accountType != IExchange.AccountType.Main) {
            revert Errors.Exchange_InvalidAccountType(main);
        }
        if (accounts[subaccount].accountType != IExchange.AccountType.Subaccount) {
            revert Errors.Exchange_InvalidAccountType(subaccount);
        }

        if (accounts[subaccount].state == IExchange.AccountState.Deleted) {
            revert Errors.Exchange_Subaccount_Deleted(subaccount);
        }

        // Check if the main account is the same
        if (main != accounts[subaccount].main) {
            revert Errors.Exchange_Subaccount_MainAccountMismatch(main, accounts[subaccount].main);
        }

        // Transfer all assets and debt to main account
        IClearingService clearingService = access.getClearingService();
        ISpot spotEngine = access.getSpotEngine();
        address[] memory supportedTokens = exchange.getSupportedTokenList();
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            _transferSubToMain(clearingService, spotEngine, token, main, subaccount);
        }

        // Check if the subaccount has no open position
        IPerp perpEngine = access.getPerpEngine();
        if (perpEngine.openPositions(subaccount) != 0) {
            revert Errors.Exchange_Subaccount_HasOpenPosition(subaccount);
        }

        bytes32 hash = exchange.hashTypedDataV4(keccak256(abi.encode(DELETE_SUBACCOUNT_TYPEHASH, main, subaccount)));
        if (!UNIVERSAL_SIG_VALIDATOR.isValidSig(main, hash, params.mainSignature)) {
            revert Errors.Exchange_InvalidSignature(main);
        }

        IExchange.Account storage subaccountData = accounts[subaccount];
        subaccountData.state = IExchange.AccountState.Deleted;

        IExchange.Account storage mainAccountData = accounts[main];
        uint256 len = mainAccountData.subaccounts.length;
        for (uint256 i = 0; i < len; i++) {
            if (mainAccountData.subaccounts[i] == subaccount) {
                mainAccountData.subaccounts[i] = mainAccountData.subaccounts[len - 1];
                mainAccountData.subaccounts.pop();
                break;
            }
        }
    }

    /// @dev Calls the clearing service to transfer the subaccount's balance to the main account
    function _transferSubToMain(
        IClearingService clearingService,
        ISpot spotEngine,
        address token,
        address main,
        address subaccount
    ) internal {
        int256 balance = spotEngine.getBalance(token, subaccount);
        if (balance != 0) {
            clearingService.transfer(subaccount, main, balance, token);
            emit IExchange.Transfer(token, subaccount, main, ZERO_ADDRESS, ZERO_NONCE, balance, TxStatus.Success);
        }
    }
}

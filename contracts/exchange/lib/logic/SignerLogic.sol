// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IExchange} from "../../interfaces/IExchange.sol";
import {Errors} from "../../lib/Errors.sol";
import {UNIVERSAL_SIG_VALIDATOR} from "../../share/Constants.sol";
import {GenericLogic} from "./GenericLogic.sol";

library SignerLogic {
    bytes32 public constant REGISTER_TYPEHASH = keccak256("Register(address key,string message,uint64 nonce)");
    bytes32 public constant REGISTER_SUBACCOUNT_SIGNER_TYPEHASH = keccak256(
        "RegisterSubaccountSigner(address main,address subaccount,address signer,string message,uint64 nonce)"
    );
    bytes32 public constant SIGN_KEY_TYPEHASH = keccak256("SignKey(address account)");

    function registerSigner(
        mapping(address => mapping(uint64 => bool)) storage isRegisterSignerNonceUsed,
        mapping(address => mapping(address => bool)) storage signingWallets,
        IExchange exchange,
        IExchange.AddSigningWallet memory data
    ) external {
        address sender = data.sender;
        address signer = data.signer;
        uint64 nonce = data.nonce;

        if (isRegisterSignerNonceUsed[sender][nonce]) {
            revert Errors.Exchange_AddSigningWallet_UsedNonce(sender, nonce);
        }
        isRegisterSignerNonceUsed[sender][nonce] = true;

        // verify signature of sender
        bytes32 registerHash = exchange.hashTypedDataV4(
            keccak256(abi.encode(REGISTER_TYPEHASH, signer, keccak256(abi.encodePacked(data.message)), nonce))
        );
        if (!UNIVERSAL_SIG_VALIDATOR.isValidSig(sender, registerHash, data.walletSignature)) {
            revert Errors.Exchange_InvalidSignature(sender);
        }

        // verify signature of authorized signer
        bytes32 signKeyHash = exchange.hashTypedDataV4(keccak256(abi.encode(SIGN_KEY_TYPEHASH, sender)));
        GenericLogic.verifySignature(signer, signKeyHash, data.signerSignature);

        signingWallets[sender][signer] = true;

        emit IExchange.RegisterSigner(sender, signer, nonce);
    }

    function registerSubaccountSigner(
        mapping(address => IExchange.Account) storage accounts,
        mapping(address => mapping(uint64 => bool)) storage isRegisterSignerNonceUsed,
        mapping(address => mapping(address => bool)) storage signingWallets,
        IExchange exchange,
        IExchange.RegisterSubaccountSignerParams memory params
    ) external {
        address main = params.main;
        address subaccount = params.subaccount;
        address signer = params.signer;

        if (accounts[main].accountType != IExchange.AccountType.Main) {
            revert Errors.Exchange_InvalidAccountType(main);
        }
        if (accounts[subaccount].accountType != IExchange.AccountType.Subaccount) {
            revert Errors.Exchange_InvalidAccountType(subaccount);
        }
        if (accounts[subaccount].state != IExchange.AccountState.Active) {
            revert Errors.Exchange_Subaccount_NotActive(subaccount);
        }
        if (main != accounts[subaccount].main) {
            revert Errors.Exchange_Subaccount_MainAccountMismatch(main, accounts[subaccount].main);
        }

        uint64 nonce = params.nonce;
        if (isRegisterSignerNonceUsed[main][nonce]) {
            revert Errors.Exchange_AddSigningWallet_UsedNonce(main, nonce);
        }
        isRegisterSignerNonceUsed[main][nonce] = true;

        // verify signature of sender
        bytes32 mainHash = exchange.hashTypedDataV4(
            keccak256(
                abi.encode(
                    REGISTER_SUBACCOUNT_SIGNER_TYPEHASH,
                    main,
                    subaccount,
                    signer,
                    keccak256(abi.encodePacked(params.message)),
                    nonce
                )
            )
        );
        if (!UNIVERSAL_SIG_VALIDATOR.isValidSig(main, mainHash, params.mainSignature)) {
            revert Errors.Exchange_InvalidSignature(main);
        }

        // verify signature of authorized signer
        bytes32 signerHash = exchange.hashTypedDataV4(keccak256(abi.encode(SIGN_KEY_TYPEHASH, subaccount)));
        GenericLogic.verifySignature(signer, signerHash, params.signerSignature);

        signingWallets[subaccount][signer] = true;

        emit IExchange.RegisterSigner(subaccount, signer, nonce);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {Access} from "./access/Access.sol";
import {IClearingService} from "./interfaces/IClearingService.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {IPerp} from "./interfaces/IPerp.sol";
import {ISpot} from "./interfaces/ISpot.sol";
import {IUniversalRouter} from "./interfaces/external/IUniversalRouter.sol";

/// @title ExchangeStorage
/// @author BSX
/// @notice Contract used as storage of the BSX Exchange contract.
/// @dev It defines the storage layout of the BSX Exchange contract.
// solhint-disable max-states-count
abstract contract ExchangeStorage {
    IClearingService public clearingService;
    ISpot public spotEngine;
    IPerp public perpEngine;
    IOrderBook public book;
    Access public access;

    EnumerableSet.AddressSet internal supportedTokens;
    mapping(address account => mapping(address signer => bool isAuthorized)) internal _signingWallets;
    mapping(address token => uint256 amount) internal _collectedFee;
    mapping(address account => mapping(uint64 registerSignerNonce => bool used)) public isRegisterSignerNonceUsed;
    mapping(address account => mapping(uint256 liquidationNonce => bool liquidated)) public isLiquidationNonceUsed;

    IUniversalRouter public universalRouter;
    uint256 private _lastResetBlockNumber; // deprecated
    int256 internal _sequencerFee;
    EnumerableSet.AddressSet private _userWallets; // deprecated
    uint256 public lastFundingRateUpdate;
    uint32 public executedTransactionCounter;
    address public feeRecipientAddress;
    bool private _isTwoPhaseWithdrawEnabled; // deprecated
    bool public canDeposit;
    bool public canWithdraw;
    bool public pauseBatchProcess;
    mapping(address account => mapping(uint64 withdrawNonce => bool used)) public isWithdrawNonceUsed;
    mapping(address account => mapping(uint256 swapNonce => bool used)) public isSwapNonceUsed;
}

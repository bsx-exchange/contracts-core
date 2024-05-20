// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Gateway} from "./abstracts/Gateway.sol";
import {IAccess} from "./interfaces/IAccess.sol";
import {IClearinghouse} from "./interfaces/IClearinghouse.sol";
import {IExchange} from "./interfaces/IExchange.sol";
import {ISpotEngine} from "./interfaces/ISpotEngine.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title Clearinghouse contract
/// @notice Manage insurance fund and spot balance
/// @dev This contract is upgradeable
contract Clearinghouse is Gateway, IClearinghouse, Initializable {
    IAccess public access;
    uint256 private _insuranceFund;

    function initialize(address _access) public initializer {
        if (_access == address(0)) {
            revert Errors.ZeroAddress();
        }

        access = IAccess(_access);
    }

    /// @inheritdoc IClearinghouse
    function deposit(address account, address token, uint256 amount) external override authorized {
        ISpotEngine spotEngine = _spotEngine();
        spotEngine.updateAccount(account, token, int256(amount));
        spotEngine.increaseTotalBalance(token, amount);
    }

    /// @inheritdoc IClearinghouse
    function withdraw(address account, address token, uint256 amount) external override authorized {
        ISpotEngine spotEngine = _spotEngine();
        spotEngine.updateAccount(account, token, -int256(amount));
        spotEngine.decreaseTotalBalance(token, amount);
    }

    /// @inheritdoc IClearinghouse
    function depositInsuranceFund(uint256 amount) external override authorized {
        _insuranceFund += amount;
    }

    /// @inheritdoc IClearinghouse
    function withdrawInsuranceFund(uint256 amount) external override authorized {
        if (amount > _insuranceFund) {
            revert InsufficientFund(_insuranceFund, amount);
        }
        _insuranceFund -= amount;
    }

    /// @inheritdoc IClearinghouse
    function coverLossWithInsuranceFund(address account, address token) external override authorized {
        ISpotEngine spotEngine = _spotEngine();
        int256 spotBalance = spotEngine.getBalance(account, token);
        if (spotBalance >= 0) {
            revert NoNeedToCover(account, token, spotBalance);
        }
        uint256 amount = uint256(-spotBalance);
        if (_insuranceFund < amount) {
            revert InsufficientFund(_insuranceFund, amount);
        }
        _insuranceFund -= amount;
        spotEngine.updateAccount(account, token, int256(amount));
    }

    /// @inheritdoc IClearinghouse
    function getInsuranceFund() external view override returns (uint256) {
        return _insuranceFund;
    }

    /// @inheritdoc Gateway
    function _isAuthorized(address caller) internal view override returns (bool) {
        return caller == access.getExchange();
    }

    function _spotEngine() internal view returns (ISpotEngine spotEngine) {
        IExchange exchange = IExchange(access.getExchange());
        spotEngine = exchange.spotEngine();
    }
}

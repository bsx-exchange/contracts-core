// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Access} from "./access/Access.sol";
import {IClearingService} from "./interfaces/IClearingService.sol";
import {ISpot} from "./interfaces/ISpot.sol";
import {Errors} from "./lib/Errors.sol";
import {BSX_TOKEN, USDC_TOKEN} from "./share/Constants.sol";

/// @title Clearinghouse contract
/// @notice Manage insurance fund and spot balance
/// @dev This contract is upgradeable
contract ClearingService is IClearingService, Initializable {
    using SafeCast for uint256;

    Access public access;
    InsuranceFund private _insuranceFund;

    // function initialize(address _access) public initializer {
    //     if (_access == address(0)) {
    //         revert Errors.ZeroAddress();
    //     }
    //     access = Access(_access);
    // }

    modifier onlySequencer() {
        if (
            msg.sender != address(access.getExchange()) && msg.sender != address(access.getOrderBook())
                && msg.sender != address(access.getVaultManager())
        ) {
            revert Errors.Unauthorized();
        }
        _;
    }

    /// @inheritdoc IClearingService
    function deposit(address account, uint256 amount, address token) external onlySequencer {
        ISpot spotEngine = access.getSpotEngine();
        int256 _amount = amount.toInt256();
        spotEngine.updateBalance(account, token, _amount);
        spotEngine.updateTotalBalance(token, _amount);
    }

    /// @inheritdoc IClearingService
    function withdraw(address account, uint256 amount, address token) external onlySequencer {
        ISpot spotEngine = access.getSpotEngine();
        int256 _amount = -amount.toInt256();
        spotEngine.updateBalance(account, token, _amount);
        spotEngine.updateTotalBalance(token, _amount);
    }

    /// @inheritdoc IClearingService
    function collectLiquidationFee(address account, uint64 nonce, uint256 amount, bool isFeeInBSX)
        external
        onlySequencer
    {
        if (isFeeInBSX) {
            _insuranceFund.inBSX += amount;
        } else {
            _insuranceFund.inUSDC += amount;
        }
        emit CollectLiquidationFee(account, nonce, amount, isFeeInBSX, _insuranceFund);
    }

    /// @inheritdoc IClearingService
    function depositInsuranceFund(address token, uint256 amount) external onlySequencer {
        if (amount == 0) {
            revert Errors.ClearingService_ZeroAmount();
        }

        if (token == USDC_TOKEN) {
            _insuranceFund.inUSDC += amount;
        } else if (token == BSX_TOKEN) {
            _insuranceFund.inBSX += amount;
        } else {
            revert Errors.ClearingService_InvalidToken(token);
        }
    }

    /// @inheritdoc IClearingService
    function withdrawInsuranceFund(address token, uint256 amount) external onlySequencer {
        if (amount == 0) {
            revert Errors.ClearingService_ZeroAmount();
        }
        if (token == USDC_TOKEN) {
            _insuranceFund.inUSDC -= amount;
        } else if (token == BSX_TOKEN) {
            _insuranceFund.inBSX -= amount;
        } else {
            revert Errors.ClearingService_InvalidToken(token);
        }
    }

    /// @inheritdoc IClearingService
    function coverLossWithInsuranceFund(address account, uint256 amount) external onlySequencer {
        ISpot spotEngine = ISpot(access.getSpotEngine());

        address collateralToken = USDC_TOKEN;
        int256 balance = spotEngine.getBalance(collateralToken, account);
        if (balance >= 0) {
            revert Errors.ClearingService_NoLoss(account, balance);
        }

        uint256 insuranceFundInUSDC = _insuranceFund.inUSDC;
        if (amount > insuranceFundInUSDC) {
            revert Errors.ClearingService_InsufficientFund(amount, insuranceFundInUSDC);
        }
        _insuranceFund.inUSDC -= amount;

        spotEngine.updateBalance(account, collateralToken, amount.toInt256());
    }

    /// @inheritdoc IClearingService
    function getInsuranceFundBalance() external view returns (InsuranceFund memory) {
        return _insuranceFund;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IClearingService.sol";
import "./access/Access.sol";
import "./interfaces/IExchange.sol";
import "./interfaces/ISpot.sol";
import "./interfaces/IPerp.sol";
import "./lib/MathHelper.sol";
import "./interfaces/IERC20Extend.sol";
import "./share/Constants.sol";
import "./share/RevertReason.sol";

contract ClearingService is IClearingService, OwnableUpgradeable {
    using SafeERC20 for IERC20Extend;
    Access public access;
    uint256 insuranceFund18D;

    function initialize(address _access) public initializer {
        __Ownable_init(msg.sender);
        if (_access == address(0)) {
            revert(INVALID_ADDRESS);
        }
        access = Access(_access);
    }

    function _onlyExchange() internal view {
        if (msg.sender != access.getExchange()) {
            revert(NOT_SEQUENCER);
        }
    }

    // function _onlyOrderBook() internal view {
    //     if (msg.sender != access.getOrderBook()) {
    //         revert(NOT_SEQUENCER);
    //     }
    // }

    modifier onlyExchange() {
        _onlyExchange();
        _;
    }

    // modifier onlyOrderBook() {
    //     _onlyOrderBook();
    //     _;
    // }

    // function _onlyGeneralAdmin() internal view {
    //     if (!access.hasRole(access.ADMIN_GENERAL_ROLE(), msg.sender)) {
    //         revert(NOT_ADMIN_GENERAL);
    //     }
    // }

    // modifier onlyGeneralAdmin() {
    //     _onlyGeneralAdmin();
    //     _;
    // }

    /// @inheritdoc IClearingService
    function deposit(
        address account,
        uint256 amount,
        address token,
        ISpot spotEngine
    ) external onlyExchange {
        ISpot.AccountDelta[] memory productDelta = new ISpot.AccountDelta[](1);
        productDelta[0] = ISpot.AccountDelta(token, account, int256(amount));
        spotEngine.modifyAccount(productDelta);
        spotEngine.setTotalBalance(token, amount, true);
    }

    /// @inheritdoc IClearingService
    function withdraw(
        address account,
        uint256 amount,
        address token,
        ISpot spotEngine
    ) external onlyExchange {
        ISpot.AccountDelta[] memory productDelta = new ISpot.AccountDelta[](1);
        productDelta[0] = ISpot.AccountDelta(token, account, -int256(amount));
        spotEngine.modifyAccount(productDelta);
        spotEngine.setTotalBalance(token, amount, false);
    }

    /// @inheritdoc IClearingService
    function depositInsuranceFund(uint256 amount) external onlyExchange {
        if (amount == 0) {
            revert(INVALID_AMOUNT);
        }
        insuranceFund18D += amount;
    }

    /// @inheritdoc IClearingService
    function withdrawInsuranceFundEmergency(
        uint256 amount
    ) external onlyExchange {
        if (amount == 0) {
            revert(INVALID_AMOUNT);
        }
        if (amount >= insuranceFund18D) {
            revert(INSUFFICIENT_BALANCE);
        }
        insuranceFund18D -= amount;
    }

    /**
     * @inheritdoc IClearingService
     */
    function getInsuranceFund() external view returns (uint256) {
        return insuranceFund18D;
    }

    // /**
    //  * @inheritdoc IClearingService
    //  */
    // function contributeToInsuranceFund(int256 amount) external onlyOrderBook {
    //     insuranceFund18D += uint256(amount);
    // }

    // WIP
    /// @inheritdoc IClearingService
    function insuranceCoverLost(
        address account,
        uint256 amount,
        ISpot spotEngine,
        address token
    ) external onlyExchange {
        if (amount > insuranceFund18D) {
            revert(AMOUNT_EXCEEDS_FUND);
        }
        int256 balance = spotEngine.getBalance(token, account);
        if (balance >= 0) {
            revert(SPOT_NOT_NEGATIVE);
        }
        ISpot.AccountDelta[] memory productDelta = new ISpot.AccountDelta[](1);
        insuranceFund18D -= amount;
        productDelta[0] = ISpot.AccountDelta(token, account, int256(amount));
        spotEngine.modifyAccount(productDelta);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IBsxOracle} from "./interfaces/IBsxOracle.sol";
import {Access} from "contracts/exchange/access/Access.sol";
import {IChainlinkAggregatorV3} from "contracts/external/chainlink/IChainlinkAggregatorV3.sol";

contract BsxOracle is Initializable, IBsxOracle {
    using SafeCast for int256;

    uint8 public constant SCALE_DECIMALS = 18;
    bytes32 public constant GENERAL_ROLE = keccak256("GENERAL_ROLE");

    Access public access;
    mapping(address token => address aggregator) public aggregators;

    modifier onlyRole(bytes32 role) {
        _checkRole(role, msg.sender);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(Access _access, address[] calldata _tokens, address[] calldata _aggregators)
        external
        initializer
    {
        access = _access;
        for (uint256 i = 0; i < _tokens.length; i++) {
            aggregators[_tokens[i]] = _aggregators[i];
        }
    }

    function setAggregator(address token, address aggregator) external onlyRole(GENERAL_ROLE) {
        aggregators[token] = aggregator;
    }

    function getTokenPriceInUsd(address token) external view override returns (uint256) {
        IChainlinkAggregatorV3 aggregator = IChainlinkAggregatorV3(aggregators[token]);
        (, int256 price,,,) = aggregator.latestRoundData();
        uint8 decimals = aggregator.decimals();
        return _scalePrice(price.toUint256(), decimals);
    }

    function _scalePrice(uint256 price, uint8 priceDecimals) internal pure returns (uint256) {
        if (priceDecimals < SCALE_DECIMALS) {
            return price * (10 ** uint256(SCALE_DECIMALS - priceDecimals));
        } else if (priceDecimals > SCALE_DECIMALS) {
            return price / (10 ** uint256(priceDecimals - SCALE_DECIMALS));
        }
        return price;
    }

    function _checkRole(bytes32 role, address account) internal view {
        if (!access.hasRole(role, account)) {
            revert IAccessControl.AccessControlUnauthorizedAccount(account, role);
        }
    }
}

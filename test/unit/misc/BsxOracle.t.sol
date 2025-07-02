// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {Access} from "contracts/exchange/access/Access.sol";
import {Roles} from "contracts/exchange/lib/Roles.sol";
import {IChainlinkAggregatorV3} from "contracts/external/chainlink/IChainlinkAggregatorV3.sol";
import {BsxOracle} from "contracts/misc/BsxOracle.sol";

contract BsxOracleTest is Test {
    using stdStorage for StdStorage;

    address private sequencer = makeAddr("sequencer");
    address private token = makeAddr("token");
    address private aggregator = makeAddr("aggregator");

    Access private access;
    BsxOracle private bsxOracle;

    function setUp() public {
        vm.startPrank(sequencer);

        access = new Access();
        stdstore.target(address(access)).sig("hasRole(bytes32,address)").with_key(Roles.ADMIN_ROLE).with_key(sequencer)
            .checked_write(true);
        access.grantRole(Roles.GENERAL_ROLE, sequencer);

        address[] memory tokens = new address[](1);
        tokens[0] = token;
        address[] memory aggregators = new address[](1);
        aggregators[0] = aggregator;

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(new BsxOracle()),
            sequencer,
            abi.encodeWithSelector(BsxOracle.initialize.selector, access, tokens, aggregators)
        );
        bsxOracle = BsxOracle(address(proxy));

        vm.stopPrank();
    }

    function test_setAggregator_succeed() public {
        address token2 = makeAddr("token2");
        address aggregator2 = makeAddr("aggregator2");

        assertEq(bsxOracle.aggregators(token2), address(0));

        vm.prank(sequencer);
        bsxOracle.setAggregator(token2, aggregator2);

        assertEq(bsxOracle.aggregators(token2), aggregator2);
    }

    function test_setAggregator_revertIfUnauthorized() public {
        address token2 = makeAddr("token2");
        address aggregator2 = makeAddr("aggregator2");

        address anyone = makeAddr("anyone");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, anyone, Roles.GENERAL_ROLE)
        );

        vm.startPrank(anyone);
        bsxOracle.setAggregator(token2, aggregator2);
    }

    function test_setStalePriceThreshold_succeed() public {
        uint256 stalePriceThreshold = 10 minutes;

        vm.prank(sequencer);
        bsxOracle.setStalePriceThreshold(token, stalePriceThreshold);

        assertEq(bsxOracle.stalePriceThresholds(token), stalePriceThreshold);
    }

    function test_setStalePriceThreshold_revertIfUnauthorized() public {
        uint256 stalePriceThreshold = 10 minutes;
        address anyone = makeAddr("anyone");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, anyone, Roles.GENERAL_ROLE)
        );

        vm.startPrank(anyone);
        bsxOracle.setStalePriceThreshold(token, stalePriceThreshold);
    }

    function test_getTokenPriceInUsd_properly() public {
        // aggregator decimals == scale decimals
        uint256 price = 2500;
        uint8 decimals = 18;
        vm.mockCall(
            aggregator,
            abi.encodeWithSelector(IChainlinkAggregatorV3.latestRoundData.selector),
            abi.encode(0, price * 10 ** decimals, 0, block.timestamp, 0)
        );
        vm.mockCall(aggregator, abi.encodeWithSelector(IChainlinkAggregatorV3.decimals.selector), abi.encode(decimals));
        assertEq(bsxOracle.getTokenPriceInUsd(token), price * 1e18);

        // aggregator decimals < scale decimals
        price = 80_000;
        decimals = 6;
        vm.mockCall(
            aggregator,
            abi.encodeWithSelector(IChainlinkAggregatorV3.latestRoundData.selector),
            abi.encode(0, price * 10 ** decimals, 0, block.timestamp, 0)
        );
        vm.mockCall(aggregator, abi.encodeWithSelector(IChainlinkAggregatorV3.decimals.selector), abi.encode(decimals));
        assertEq(bsxOracle.getTokenPriceInUsd(token), price * 1e18);

        // aggregator decimals > scale decimals
        price = 1;
        decimals = 20;
        vm.mockCall(
            aggregator,
            abi.encodeWithSelector(IChainlinkAggregatorV3.latestRoundData.selector),
            abi.encode(0, price * 10 ** decimals, 0, block.timestamp, 0)
        );
        vm.mockCall(aggregator, abi.encodeWithSelector(IChainlinkAggregatorV3.decimals.selector), abi.encode(decimals));
        assertEq(bsxOracle.getTokenPriceInUsd(token), price * 1e18);
    }
}

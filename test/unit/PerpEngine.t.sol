// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {Access} from "src/Access.sol";
import {PerpEngine} from "src/PerpEngine.sol";
import {Errors} from "src/libraries/Errors.sol";
import {Math} from "src/libraries/Math.sol";

contract PerpEngineTest is Test {
    using Math for int128;

    address private exchange = makeAddr("exchange");
    address private clearinghouse = makeAddr("clearinghouse");
    address private orderbook = makeAddr("orderbook");

    Access private access;
    PerpEngine private perpEngine;

    function setUp() public {
        access = new Access();
        access.initialize(address(this));
        access.setExchange(exchange);
        access.setClearinghouse(clearinghouse);
        access.setOrderbook(orderbook);

        perpEngine = new PerpEngine();
        perpEngine.initialize(address(access));
    }

    function test_initialize() public view {
        assertEq(address(perpEngine.access()), address(access));
    }

    function test_initialize_revertsIfSetZeroAddr() public {
        PerpEngine _perpEngine = new PerpEngine();
        vm.expectRevert(Errors.ZeroAddress.selector);
        _perpEngine.initialize(address(0));
    }

    function test_authorized() public {
        vm.prank(exchange);
        perpEngine.cumulateFundingRate(0, 0);

        vm.prank(clearinghouse);
        perpEngine.cumulateFundingRate(0, 0);

        vm.prank(orderbook);
        perpEngine.cumulateFundingRate(0, 0);
    }

    function test_updateFundingRate() public {
        vm.startPrank(exchange);

        uint8 productId = 0;
        int128[4] memory rates = [int128(-10), 20, -15, 30];
        int128 cumulativeFunding = 0;

        for (uint256 i = 0; i < rates.length; i++) {
            perpEngine.cumulateFundingRate(productId, rates[i]);
            cumulativeFunding += rates[i];
            assertEq(perpEngine.getMarketMetrics(productId).cumulativeFundingRate, cumulativeFunding);
        }
    }

    function test_updateFundingRate_revertsWhenUnauthorized() public {
        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        perpEngine.cumulateFundingRate(0, 0);
    }

    function test_settlePositionPnl_openNewPosition() public {
        vm.startPrank(exchange);

        uint8 productId = 0;
        address account = makeAddr("account");

        int128 cumulativeFR = perpEngine.cumulateFundingRate(productId, 2e16);

        int128 size = 10 * 1e18;
        int128 price = 50_000 * 1e18;
        int128 pnl = _goLong(productId, account, price, size);
        assertEq(pnl, 0);

        PerpEngine.OpenPosition memory position = perpEngine.getOpenPosition(productId, account);
        assertEq(position.baseAmount, size);
        assertEq(position.quoteAmount, -size.mul18D(price));
        assertEq(position.lastFunding, cumulativeFR);

        PerpEngine.MarketMetrics memory marketMetrics = perpEngine.getMarketMetrics(productId);
        assertEq(marketMetrics.openInterest, size);
    }

    function test_settlePositionPnl_closePosition() public {
        vm.startPrank(exchange);

        uint8 productId = 0;
        address account = makeAddr("account");

        int128 size = 1000 * 1e18;
        int128 price = 50_000 * 1e18;
        int128 beforeCumulativeFR = perpEngine.cumulateFundingRate(productId, 2e16);
        _goLong(productId, account, price, size);

        int128 newPrice = 60_000 * 1e18;
        int128 afterCumulativeFR = perpEngine.cumulateFundingRate(productId, 6e16);
        int128 pnl = _goShort(productId, account, newPrice, size);

        int128 fundingFee = (afterCumulativeFR - beforeCumulativeFR).mul18D(size);
        assertEq(pnl, (newPrice - price).mul18D(size) - fundingFee);

        PerpEngine.OpenPosition memory position = perpEngine.getOpenPosition(productId, account);
        assertEq(position.baseAmount, 0);
        assertEq(position.quoteAmount, 0);
        assertEq(position.lastFunding, afterCumulativeFR);

        PerpEngine.MarketMetrics memory marketMetrics = perpEngine.getMarketMetrics(productId);
        assertEq(marketMetrics.openInterest, 0);
    }

    function test_settlePositionPnl_changePosition() public {
        vm.startPrank(exchange);

        uint8 productId = 0;
        address account = makeAddr("account");

        // long position, size = 500, price = 50_000
        int128 size = 500 * 1e18;
        int128 price = 50_000 * 1e18;
        int128 beforeCumulativeFR = perpEngine.cumulateFundingRate(productId, 1e16);
        _goLong(productId, account, price, size);

        // short position, size = 800, price = 75_000
        int128 newSize = 800 * 1e18;
        int128 newPrice = 75_000 * 1e18;
        int128 afterCumulativeFR = perpEngine.cumulateFundingRate(productId, -3e16);
        int128 pnl = _goShort(productId, account, newPrice, newSize);

        int128 fundingFee = (afterCumulativeFR - beforeCumulativeFR).mul18D(size);
        assertEq(pnl, (newPrice - price).mul18D(size) - fundingFee);

        PerpEngine.OpenPosition memory position = perpEngine.getOpenPosition(productId, account);
        assertEq(position.baseAmount, -(newSize - size));
        assertEq(position.quoteAmount, newPrice.mul18D(newSize - size));
        assertEq(position.lastFunding, afterCumulativeFR);

        PerpEngine.MarketMetrics memory marketMetrics = perpEngine.getMarketMetrics(productId);
        assertEq(marketMetrics.openInterest, 0); // not counting short position
    }

    function test_settlePositionPnl_revertsWhenUnauthorized() public {
        uint8 productId = 0;
        address account = makeAddr("account");
        int128 baseAmount = 10;
        int128 quoteAmount = 10;

        vm.expectRevert(Errors.Gateway_Unauthorized.selector);
        perpEngine.settlePositionPnl(productId, account, baseAmount, quoteAmount);
    }

    function _goLong(uint8 productId, address account, int128 price, int128 size) internal returns (int128 pnl) {
        int128 deltaBaseAmount = size;
        int128 deltaQuoteAmount = -size.mul18D(price);
        pnl = perpEngine.settlePositionPnl(productId, account, deltaBaseAmount, deltaQuoteAmount);
    }

    function _goShort(uint8 productId, address account, int128 price, int128 size) internal returns (int128 pnl) {
        int128 deltaBaseAmount = -size;
        int128 deltaQuoteAmount = size.mul18D(price);
        pnl = perpEngine.settlePositionPnl(productId, account, deltaBaseAmount, deltaQuoteAmount);
    }
}

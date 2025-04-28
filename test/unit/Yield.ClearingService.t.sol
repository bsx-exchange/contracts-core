// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {Helper} from "../Helper.sol";
import {ERC20Simple} from "../mock/ERC20Simple.sol";
import {MockERC4626} from "../mock/MockERC4626.sol";
import {UniversalSigValidator} from "../mock/UniversalSigValidator.sol";

import {ClearingService, IClearingService} from "contracts/exchange/ClearingService.sol";
import {Exchange, IExchange} from "contracts/exchange/Exchange.sol";
import {OrderBook} from "contracts/exchange/OrderBook.sol";
import {Spot} from "contracts/exchange/Spot.sol";
import {Access} from "contracts/exchange/access/Access.sol";
import {ISwap} from "contracts/exchange/interfaces/ISwap.sol";
import {Errors} from "contracts/exchange/lib/Errors.sol";
import {MathHelper} from "contracts/exchange/lib/MathHelper.sol";
import {UNIVERSAL_SIG_VALIDATOR} from "contracts/exchange/share/Constants.sol";

contract YieldClearingServiceTest is Test {
    using stdStorage for StdStorage;
    using MathHelper for uint256;

    address private admin = makeAddr("admin");
    address private user;
    uint256 private userKey;

    address private token;
    address private vault;

    Access private access;
    Exchange private exchange;
    OrderBook private orderbook;
    Spot private spotEngine;
    ClearingService private clearingService;

    bytes32 public constant GENERAL_ROLE = keccak256("GENERAL_ROLE");
    bytes32 private constant SWAP_TYPEHASH = keccak256(
        "Swap(address account,address assetIn,uint256 amountIn,address assetOut,uint256 minAmountOut,uint256 nonce)"
    );

    function setUp() public {
        (user, userKey) = makeAddrAndKey("user");

        access = new Access();
        stdstore.target(address(access)).sig("hasRole(bytes32,address)").with_key(access.ADMIN_ROLE()).with_key(
            address(this)
        ).checked_write(true);
        access.grantRole(access.GENERAL_ROLE(), admin);

        clearingService = new ClearingService();
        stdstore.target(address(clearingService)).sig("access()").checked_write(address(access));

        exchange = new Exchange();
        stdstore.target(address(exchange)).sig("access()").checked_write(address(access));
        stdstore.target(address(exchange)).sig("clearingService()").checked_write(address(clearingService));

        spotEngine = new Spot();
        stdstore.target(address(spotEngine)).sig("access()").checked_write(address(access));

        orderbook = new OrderBook();
        stdstore.target(address(orderbook)).sig("clearingService()").checked_write(address(clearingService));
        stdstore.target(address(orderbook)).sig("spotEngine()").checked_write(address(spotEngine));
        stdstore.target(address(orderbook)).sig("access()").checked_write(address(access));
        stdstore.target(address(orderbook)).sig("getCollateralToken()").checked_write(token);

        access.setExchange(address(exchange));
        access.setOrderBook(address(orderbook));
        access.setSpotEngine(address(spotEngine));
        access.setClearingService(address(clearingService));

        bytes memory code = address(new UniversalSigValidator()).code;
        vm.etch(address(UNIVERSAL_SIG_VALIDATOR), code);

        token = address(new ERC20Simple(6));
        vault = address(new MockERC4626(ERC20Simple(token)));

        vm.prank(admin);
        exchange.addSupportedToken(token);
    }

    function test_addYieldAsset_succeeds() public {
        vm.prank(admin);

        vm.expectEmit();
        emit IClearingService.AddYieldAsset(token, vault);

        clearingService.addYieldAsset(token, vault);

        address yieldToken = clearingService.yieldAssets(token);
        assertEq(yieldToken, vault);
    }

    function test_addYieldAsset_revertsIfUnauthorized() public {
        address malicious = makeAddr("malicious");
        bytes32 role = access.GENERAL_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );

        vm.prank(malicious);
        clearingService.addYieldAsset(token, vault);
    }

    function test_addYieldAsset_revertsIfUnsupportedToken() public {
        address anyToken = makeAddr("anyToken");

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_TokenNotSupported.selector, anyToken));

        vm.prank(admin);
        clearingService.addYieldAsset(anyToken, vault);
    }

    function test_addYieldAsset_revertsIfInvalidVaultAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        vm.prank(admin);
        clearingService.addYieldAsset(token, address(0));

        address anotherVault = makeAddr("anotherVault");
        vm.mockCall(anotherVault, abi.encodeWithSignature("asset()"), abi.encode(address(1)));

        vm.expectRevert(
            abi.encodeWithSelector(Errors.ClearingService_YieldAsset_AssetMismatch.selector, token, anotherVault)
        );
        vm.prank(admin);
        clearingService.addYieldAsset(token, anotherVault);
    }

    function test_addYieldAsset_revertsIfAlreadyAdded() public {
        vm.startPrank(admin);

        clearingService.addYieldAsset(token, vault);

        vm.expectRevert(abi.encodeWithSelector(Errors.ClearingService_YieldAsset_AlreadyExists.selector, token, vault));
        clearingService.addYieldAsset(token, vault);

        vm.stopPrank();
    }

    function test_swapYieldAssetPermit_depositVault_succeeds() public {
        vm.prank(admin);
        clearingService.addYieldAsset(token, vault);

        // 1 share = 2 tokens
        ERC20Simple(token).mint(vault, 1);

        uint256 userBalance = 500e18;
        _depositSpotAccount(user, userBalance, token);

        uint256 nonce = 1;
        uint256 depositAssets = 300e18;
        uint256 mintShares = 150e18;
        ISwap.SwapParams memory params;
        params.account = user;
        params.assetIn = token;
        params.amountIn = depositAssets;
        params.assetOut = vault;
        params.minAmountOut = mintShares;
        params.nonce = nonce;
        params.signature = _signTypedDataHash(
            userKey,
            keccak256(
                abi.encode(
                    SWAP_TYPEHASH,
                    user,
                    params.assetIn,
                    params.amountIn,
                    params.assetOut,
                    params.minAmountOut,
                    params.nonce
                )
            )
        );

        vm.expectEmit(address(clearingService));
        emit IClearingService.SwapAssets(
            user,
            nonce,
            token,
            depositAssets,
            vault,
            mintShares,
            address(0),
            0,
            IClearingService.SwapType.DepositVault,
            IClearingService.ActionStatus.Success
        );

        vm.prank(address(exchange));
        clearingService.swapYieldAssetPermit(params);

        (uint256 userShares, uint256 price) = clearingService.vaultShares(user, vault);
        assertEq(userShares, mintShares);
        assertEq(price, 2e18);

        uint256 userBalanceAfter = userBalance - depositAssets;
        assertEq(spotEngine.getBalance(token, user), int256(userBalanceAfter));
        assertEq(spotEngine.getTotalBalance(token), userBalanceAfter);

        assertEq(spotEngine.getBalance(vault, user), int256(mintShares));
        assertEq(spotEngine.getTotalBalance(vault), mintShares);

        assertEq(IERC4626(vault).balanceOf(address(clearingService)), mintShares.convertFromScale(vault));
        assertEq(ERC20Simple(token).balanceOf(address(exchange)), userBalanceAfter.convertFromScale(token));
    }

    function test_swapYieldAssetPermit_redeemVault_succeeds() public {
        vm.prank(admin);
        clearingService.addYieldAsset(token, vault);

        uint256 userBalance = 500e18;
        _depositSpotAccount(user, userBalance, token);
        ISwap.SwapParams memory params;

        // 1. deposit to the vault
        uint256 mintShares = 300e18;
        uint256 depositAssets = 300e18;

        params.account = user;
        params.assetIn = token;
        params.amountIn = mintShares;
        params.assetOut = vault;
        params.minAmountOut = depositAssets;
        params.nonce = 1;
        params.signature = _signTypedDataHash(
            userKey,
            keccak256(
                abi.encode(
                    SWAP_TYPEHASH,
                    user,
                    params.assetIn,
                    params.amountIn,
                    params.assetOut,
                    params.minAmountOut,
                    params.nonce
                )
            )
        );
        vm.prank(address(exchange));
        clearingService.swapYieldAssetPermit(params);

        // 1 share = 2 tokens
        ERC20Simple(token).mint(vault, 300e6 + 1);

        // 2. redeem from the vault
        uint256 redeemShares = 50e18;
        uint256 withdrawAssets = 100e18;

        params.assetIn = vault;
        params.amountIn = redeemShares;
        params.assetOut = token;
        params.minAmountOut = withdrawAssets;
        params.nonce = 2;
        params.signature = _signTypedDataHash(
            userKey,
            keccak256(
                abi.encode(
                    SWAP_TYPEHASH,
                    user,
                    params.assetIn,
                    params.amountIn,
                    params.assetOut,
                    params.minAmountOut,
                    params.nonce
                )
            )
        );

        vm.expectEmit(address(clearingService));
        emit IClearingService.SwapAssets(
            user,
            params.nonce,
            vault,
            redeemShares,
            token,
            withdrawAssets,
            address(0),
            0,
            IClearingService.SwapType.RedeemVault,
            IClearingService.ActionStatus.Success
        );

        vm.prank(address(exchange));
        clearingService.swapYieldAssetPermit(params);

        (uint256 userShares, uint256 price) = clearingService.vaultShares(user, vault);
        assertEq(userShares, mintShares - redeemShares);
        assertEq(price, 1e18);

        uint256 userBalanceAfter = userBalance - depositAssets + withdrawAssets;
        assertEq(spotEngine.getBalance(token, user), int256(userBalanceAfter));
        assertEq(spotEngine.getTotalBalance(token), userBalanceAfter);

        assertEq(spotEngine.getBalance(vault, user), int256(userShares));
        assertEq(spotEngine.getTotalBalance(vault), userShares);

        assertEq(IERC4626(vault).balanceOf(address(clearingService)), userShares.convertFromScale(vault));
        assertEq(ERC20Simple(token).balanceOf(address(exchange)), userBalanceAfter.convertFromScale(token));
    }

    function test_swapYieldAssetPermit_revertsIfUnauthorized() public {
        ISwap.SwapParams memory params;

        vm.expectRevert(Errors.Unauthorized.selector);

        vm.prank(admin);
        clearingService.swapYieldAssetPermit(params);
    }

    function test_swapYieldAssetPermit_revertsIfNotMainAccount() public {
        ISwap.SwapParams memory params;
        params.account = user;

        vm.mockCall(
            address(exchange),
            abi.encodeWithSelector(IExchange.getAccountType.selector, user),
            abi.encode(IExchange.AccountType.Subaccount)
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.Exchange_InvalidAccountType.selector, user));

        vm.prank(address(exchange));
        clearingService.swapYieldAssetPermit(params);
    }

    function test_earnYieldAsset_succeeds() public {
        vm.prank(admin);
        clearingService.addYieldAsset(token, vault);

        // 1 share = 2 tokens
        ERC20Simple(token).mint(vault, 1);

        uint256 userBalance = 500e18;
        _depositSpotAccount(user, userBalance, token);

        uint256 depositAssets = 300e18;
        uint256 mintShares = 150e18;

        vm.expectEmit(address(clearingService));
        emit IClearingService.SwapAssets(
            user,
            0,
            token,
            depositAssets,
            vault,
            mintShares,
            address(0),
            0,
            IClearingService.SwapType.EarnYieldAsset,
            IClearingService.ActionStatus.Success
        );

        vm.prank(address(exchange));
        clearingService.earnYieldAsset(user, token, depositAssets);

        (uint256 userShares, uint256 price) = clearingService.vaultShares(user, vault);
        assertEq(userShares, mintShares);
        assertEq(price, 2e18);

        uint256 userBalanceAfter = userBalance - depositAssets;
        assertEq(spotEngine.getBalance(token, user), int256(userBalanceAfter));
        assertEq(spotEngine.getTotalBalance(token), userBalanceAfter);

        assertEq(spotEngine.getBalance(vault, user), int256(mintShares));
        assertEq(spotEngine.getTotalBalance(vault), mintShares);

        assertEq(IERC4626(vault).balanceOf(address(clearingService)), mintShares.convertFromScale(vault));
        assertEq(ERC20Simple(token).balanceOf(address(exchange)), userBalanceAfter.convertFromScale(token));
    }

    function test_earnYieldAsset_revertsIfUnauthorized() public {
        vm.expectRevert(Errors.Unauthorized.selector);

        vm.prank(admin);
        clearingService.earnYieldAsset(user, token, 0);
    }

    function test_earnYieldAsset_revertsIfYieldAssetNotExist() public {
        vm.expectRevert(Errors.ZeroAddress.selector);

        vm.prank(address(exchange));
        clearingService.earnYieldAsset(user, token, 0);
    }

    function test_liquidateYieldAssetIfNecessary_succeeds() public {
        vm.prank(admin);
        clearingService.addYieldAsset(token, vault);

        uint256 userBalanceBefore = 300e18;
        _depositSpotAccount(user, userBalanceBefore, token);
        ISwap.SwapParams memory params;

        // 1. deposit to the vault
        uint256 mintShares = userBalanceBefore;
        uint256 depositAssets = 300e18;

        params.account = user;
        params.assetIn = token;
        params.amountIn = mintShares;
        params.assetOut = vault;
        params.minAmountOut = depositAssets;
        params.nonce = 1;
        params.signature = _signTypedDataHash(
            userKey,
            keccak256(
                abi.encode(
                    SWAP_TYPEHASH,
                    user,
                    params.assetIn,
                    params.amountIn,
                    params.assetOut,
                    params.minAmountOut,
                    params.nonce
                )
            )
        );
        vm.prank(address(exchange));
        clearingService.swapYieldAssetPermit(params);

        // 2. decrease balance
        uint256 loss = 100e18;
        _decreaseSpotBalance(user, loss, token);

        // 3. increase price vault: 1->2
        ERC20Simple(token).mint(vault, 300e6 + 1);

        // 4. pull asset
        uint256 redeemShares = 50e18;
        vm.expectEmit(address(clearingService));
        emit IClearingService.SwapAssets(
            user,
            0,
            vault,
            redeemShares,
            token,
            loss,
            address(0),
            0,
            IClearingService.SwapType.LiquidateYieldAsset,
            IClearingService.ActionStatus.Success
        );

        vm.prank(address(exchange));
        clearingService.liquidateYieldAssetIfNecessary(user, token);

        (uint256 userShares, uint256 price) = clearingService.vaultShares(user, vault);
        assertEq(userShares, mintShares - redeemShares);
        assertEq(price, 1e18);

        assertEq(spotEngine.getBalance(token, user), 0);
        assertEq(spotEngine.getTotalBalance(token), loss);

        assertEq(spotEngine.getBalance(vault, user), int256(userShares));
        assertEq(spotEngine.getTotalBalance(vault), userShares);

        assertEq(IERC4626(vault).balanceOf(address(clearingService)), userShares.convertFromScale(vault));
        assertEq(ERC20Simple(token).balanceOf(address(exchange)), loss.convertFromScale(token));
    }

    function test_liquidateYieldAssetIfNecessary_revertsIfUnauthorized() public {
        vm.expectRevert(Errors.Unauthorized.selector);

        vm.prank(admin);
        clearingService.liquidateYieldAssetIfNecessary(user, token);
    }

    function test_innerSwapYieldAssetPermit_revertsIfCallerNotClearingService() public {
        address account;
        address assetIn;
        uint256 amountIn;
        address assetOut;
        uint256 minAmountOut;
        IClearingService.SwapType swapType;

        vm.expectRevert(Errors.ClearingService_InternalCall.selector);

        vm.prank(admin);
        clearingService.innerSwapYieldAsset(account, assetIn, amountIn, assetOut, minAmountOut, swapType);

        vm.expectRevert(Errors.ClearingService_InternalCall.selector);

        vm.prank(admin);
        clearingService.innerSwapYieldAsset(account, assetIn, amountIn, assetOut, minAmountOut, swapType);
    }

    function test_innerSwapYieldAssetPermit_deposit_revertsIfVaultAmountOutMismatch() public {
        vm.prank(admin);
        clearingService.addYieldAsset(token, vault);

        uint256 userBalance = 500e18;
        _depositSpotAccount(user, userBalance, token);

        uint256 mintShares = 300e18;
        uint256 depositAssets = 300e18;

        vm.mockCall(
            vault,
            abi.encodeWithSelector(
                IERC4626.deposit.selector, depositAssets.convertFromScale(token), address(clearingService)
            ),
            abi.encode(mintShares + 1)
        );

        vm.expectRevert(Errors.ClearingService_Vault_AmountOutTooLittle.selector);

        vm.prank(address(clearingService));
        clearingService.innerSwapYieldAsset(
            user, token, depositAssets, vault, mintShares, IClearingService.SwapType.DepositVault
        );
    }

    function test_innerSwapYieldAssetPermit_redeem_revertsIfVaultAmountOutMismatch() public {
        vm.prank(admin);
        clearingService.addYieldAsset(token, vault);

        uint256 userBalance = 500e18;
        _depositSpotAccount(user, userBalance, token);

        // deposit to the vault
        uint256 depositAssets = 300e18;
        vm.prank(address(clearingService));
        clearingService.innerSwapYieldAsset(
            user, token, depositAssets, vault, 0, IClearingService.SwapType.DepositVault
        );

        // redeem from the vault
        uint256 redeemShares = 200e18;
        uint256 withdrawAssets = 200e18;

        vm.mockCall(
            vault,
            abi.encodeWithSelector(
                IERC4626.redeem.selector,
                redeemShares.convertFromScale(vault),
                address(exchange),
                address(clearingService)
            ),
            abi.encode(withdrawAssets + 1)
        );

        vm.expectRevert(Errors.ClearingService_Vault_AmountOutTooLittle.selector);

        vm.prank(address(clearingService));
        clearingService.innerSwapYieldAsset(
            user, vault, redeemShares, token, withdrawAssets, IClearingService.SwapType.RedeemVault
        );
    }

    function _depositSpotAccount(address _account, uint256 _amount, address _token) private {
        vm.prank(address(exchange));
        clearingService.deposit(_account, _amount, _token);
        ERC20Simple(token).mint(address(exchange), _amount.convertFromScale(_token));
    }

    function _decreaseSpotBalance(address _account, uint256 _amount, address _token) private {
        vm.prank(address(clearingService));
        spotEngine.updateBalance(_account, _token, -int256(_amount));
    }

    function _signTypedDataHash(uint256 privateKey, bytes32 structHash) private view returns (bytes memory) {
        return Helper.signTypedDataHash(exchange, privateKey, structHash);
    }
}

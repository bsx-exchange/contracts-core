// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Test} from "forge-std/Test.sol";

import {Helper} from "../Helper.sol";
import {ERC1271} from "../mock/ERC1271.sol";
import {ERC20Simple} from "../mock/ERC20Simple.sol";

import {BSX1000x} from "contracts/1000x/BSX1000x.sol";
import {IBSX1000x} from "contracts/1000x/interfaces/IBSX1000x.sol";
import {Exchange, IExchange} from "contracts/exchange/Exchange.sol";
import {Access} from "contracts/exchange/access/Access.sol";
import {IERC3009Minimal} from "contracts/exchange/interfaces/external/IERC3009Minimal.sol";
import {Errors} from "contracts/exchange/lib/Errors.sol";

contract BSX1000xTest is Test {
    using Helper for uint256;

    Access private access;
    BSX1000x private bsx1000x;
    ERC20Simple private collateralToken;

    bool private constant NO_LIQUIDATION = false;
    bool private constant LIQUIDATION = true;
    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function setUp() public {
        access = new Access();
        access.initialize(address(this));

        // migrate new admin role
        access.migrateAdmin();
        access.grantRole(access.BSX1000_OPERATOR_ROLE(), address(this));
        access.grantRole(access.GENERAL_ROLE(), address(this));

        access.setExchange(address(new Exchange()));

        collateralToken = new ERC20Simple();

        bsx1000x = new BSX1000x();
        bsx1000x.initialize("BSX1000x", "1", address(access), address(collateralToken));
    }

    function test_initialize() public view {
        assertEq(address(bsx1000x.access()), address(access));
        assertEq(address(bsx1000x.collateralToken()), address(collateralToken));
    }

    function test_initialize_revertsIfSetZeroAddr() public {
        BSX1000x _bsx1000x = new BSX1000x();
        vm.expectRevert(Errors.ZeroAddress.selector);
        _bsx1000x.initialize("BSX1000x", "1", address(0), address(0));
    }

    function test_deposit() public {
        address account = makeAddr("account");
        uint256 totalAmount;
        uint8 tokenDecimals = collateralToken.decimals();

        vm.startPrank(account);

        for (uint256 i = 1; i < 5; i++) {
            uint256 rawAmount = i * 3000;
            collateralToken.mint(account, rawAmount);
            collateralToken.approve(address(bsx1000x), rawAmount);

            uint256 amount = rawAmount.convertTo18D(tokenDecimals);
            totalAmount += amount;
            vm.expectEmit(address(bsx1000x));
            emit IBSX1000x.Deposit(account, amount, totalAmount);
            bsx1000x.deposit(amount);

            IBSX1000x.Balance memory balance = bsx1000x.getBalance(account);
            assertEq(balance.available, totalAmount);
            assertEq(balance.locked, 0);
            assertEq(collateralToken.balanceOf(address(bsx1000x)), totalAmount.convertFrom18D(tokenDecimals));
        }
    }

    function test_deposit_withRecipient() public {
        address account = makeAddr("account");
        address recipient = makeAddr("recipient");
        uint256 totalAmount;
        uint8 tokenDecimals = collateralToken.decimals();

        vm.startPrank(account);

        for (uint256 i = 1; i < 5; i++) {
            uint256 rawAmount = i * 3000;
            collateralToken.mint(account, rawAmount);
            collateralToken.approve(address(bsx1000x), rawAmount);

            uint256 amount = rawAmount.convertTo18D(tokenDecimals);
            totalAmount += amount;
            vm.expectEmit(address(bsx1000x));
            emit IBSX1000x.Deposit(recipient, amount, totalAmount);
            bsx1000x.deposit(recipient, amount);

            IBSX1000x.Balance memory balance = bsx1000x.getBalance(recipient);
            assertEq(balance.available, totalAmount);
            assertEq(balance.locked, 0);
            assertEq(collateralToken.balanceOf(address(bsx1000x)), totalAmount.convertFrom18D(tokenDecimals));
        }
    }

    function test_deposit_revertsIfZeroAmount() public {
        address account = makeAddr("account");
        vm.expectRevert(IBSX1000x.ZeroAmount.selector);
        bsx1000x.deposit(account, 0);

        uint256 maxZeroScaledAmount = _maxZeroScaledAmount();
        vm.expectRevert(IBSX1000x.ZeroAmount.selector);
        bsx1000x.deposit(account, maxZeroScaledAmount);
    }

    function test_depositRaw() public {
        address account = makeAddr("account");
        address recipient = makeAddr("recipient");
        uint256 totalAmount;
        uint8 tokenDecimals = collateralToken.decimals();

        vm.startPrank(account);
        collateralToken.mint(account, 100 ether);
        collateralToken.approve(address(bsx1000x), 100 ether);

        for (uint256 i = 1; i < 5; i++) {
            uint256 rawAmount = i * 500_000;

            uint256 amount = rawAmount.convertTo18D(tokenDecimals);
            totalAmount += amount;

            emit IBSX1000x.Deposit(recipient, amount, totalAmount);
            bsx1000x.depositRaw(recipient, address(collateralToken), rawAmount);

            IBSX1000x.Balance memory balance = bsx1000x.getBalance(recipient);
            assertEq(balance.available, totalAmount);
            assertEq(balance.locked, 0);
            assertEq(collateralToken.balanceOf(address(bsx1000x)), totalAmount.convertFrom18D(tokenDecimals));
        }
    }

    function test_depositRaw_revertsIfZeroAmount() public {
        address account = makeAddr("account");
        vm.expectRevert(IBSX1000x.ZeroAmount.selector);
        bsx1000x.depositRaw(account, address(collateralToken), 0);
    }

    function test_depositRaw_revertsIfNotCollateralToken() public {
        address account = makeAddr("account");
        address invalidToken = makeAddr("invalidToken");
        vm.expectRevert(Errors.Exchange_NotCollateralToken.selector);
        bsx1000x.depositRaw(account, invalidToken, 1000);
    }

    function test_depositWithAuthorization() public {
        address account = makeAddr("account");
        uint256 totalAmount;
        uint8 decimals = collateralToken.decimals();
        uint256 mockValidTime = block.timestamp;
        bytes32 mockNonce = keccak256(abi.encode(account, mockValidTime));
        bytes memory mockSignature = abi.encode(account, mockValidTime, mockNonce);

        vm.startPrank(account);
        for (uint256 i = 1; i < 5; i++) {
            uint256 amount = i * 1e18;
            totalAmount += amount;

            vm.mockCall(
                address(collateralToken),
                abi.encodeWithSelector(
                    IERC3009Minimal.receiveWithAuthorization.selector,
                    account,
                    address(bsx1000x),
                    amount.convertFrom18D(decimals),
                    mockValidTime,
                    mockValidTime,
                    mockNonce,
                    mockSignature
                ),
                abi.encode()
            );

            vm.expectEmit(address(bsx1000x));
            emit IBSX1000x.Deposit(account, amount, totalAmount);
            bsx1000x.depositWithAuthorization(account, amount, mockValidTime, mockValidTime, mockNonce, mockSignature);

            IBSX1000x.Balance memory balance = bsx1000x.getBalance(account);
            assertEq(balance.available, totalAmount);
            assertEq(balance.locked, 0);
        }
    }

    function test_depositWithAuthorization_revertsIfZeroAmount() public {
        address account = makeAddr("account");
        uint128 zeroAmount = 0;
        vm.expectRevert(IBSX1000x.ZeroAmount.selector);
        bsx1000x.depositWithAuthorization(account, zeroAmount, 0, 0, 0, "");

        uint256 maxZeroScaledAmount = _maxZeroScaledAmount();
        vm.expectRevert(IBSX1000x.ZeroAmount.selector);
        bsx1000x.depositWithAuthorization(account, maxZeroScaledAmount, 0, 0, 0, "");
    }

    function test_withdraw_EOA() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        uint256 initAmount = 100 * 1e18;

        _deposit(account, initAmount);

        uint256 nonce = 1;
        uint256 withdrawAmount = 10 * 1e18;
        uint256 fee = 1 * 1e18;

        bytes32 structHash = keccak256(abi.encode(bsx1000x.WITHDRAW_TYPEHASH(), account, withdrawAmount, nonce));
        bytes memory signature = _signTypedDataHash(accountKey, structHash);

        uint256 fundBalanceBefore = bsx1000x.fundBalance();

        vm.expectEmit(address(bsx1000x));
        emit IBSX1000x.WithdrawSucceeded(account, nonce, withdrawAmount, fee, initAmount - withdrawAmount);
        bsx1000x.withdraw(account, withdrawAmount, fee, nonce, signature);

        IBSX1000x.Balance memory balance = bsx1000x.getBalance(account);
        assertEq(balance.available, initAmount - withdrawAmount);
        assertEq(balance.locked, 0);
        assertEq(bsx1000x.fundBalance(), fundBalanceBefore + fee);
        assertEq(collateralToken.balanceOf(account), (withdrawAmount - fee).convertFrom18D(collateralToken.decimals()));
        assertEq(
            collateralToken.balanceOf(address(bsx1000x)),
            (initAmount + fee - withdrawAmount).convertFrom18D(collateralToken.decimals())
        );
    }

    function test_withdraw_smartContract() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("owner");
        address contractAccount = address(new ERC1271(owner));
        uint256 initAmount = 100 * 1e18;

        _deposit(contractAccount, initAmount);

        uint256 nonce = 1;
        uint256 withdrawAmount = 10 * 1e18;
        uint256 fee = 1 * 1e18;

        bytes32 structHash = keccak256(abi.encode(bsx1000x.WITHDRAW_TYPEHASH(), contractAccount, withdrawAmount, nonce));
        bytes memory signature = _signTypedDataHash(ownerKey, structHash);

        uint256 fundBalanceBefore = bsx1000x.fundBalance();

        vm.expectEmit(address(bsx1000x));
        emit IBSX1000x.WithdrawSucceeded(contractAccount, nonce, withdrawAmount, fee, initAmount - withdrawAmount);
        bsx1000x.withdraw(contractAccount, withdrawAmount, fee, nonce, signature);

        IBSX1000x.Balance memory balance = bsx1000x.getBalance(contractAccount);
        assertEq(balance.available, initAmount - withdrawAmount);
        assertEq(balance.locked, 0);
        assertEq(bsx1000x.fundBalance(), fundBalanceBefore + fee);
        assertEq(
            collateralToken.balanceOf(contractAccount),
            (withdrawAmount - fee).convertFrom18D(collateralToken.decimals())
        );
        assertEq(
            collateralToken.balanceOf(address(bsx1000x)),
            (initAmount + fee - withdrawAmount).convertFrom18D(collateralToken.decimals())
        );
    }

    function test_withdraw_revertsIfUnauthorizedCaller() public {
        address account = makeAddr("account");
        uint256 amount = 1000;
        uint256 fee = 1000;
        uint256 nonce = 1;
        bytes memory signature = abi.encodePacked("signature");

        address malicious = makeAddr("malicious");
        bytes32 role = access.GENERAL_ROLE();
        vm.prank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        bsx1000x.withdraw(account, amount, fee, nonce, signature);
    }

    function test_withdraw_revertsIfZeroAmount() public {
        address account = makeAddr("account");
        uint256 zeroAmount = 0;
        uint256 fee;
        uint256 nonce;
        bytes memory signature;

        vm.expectRevert(IBSX1000x.ZeroAmount.selector);
        bsx1000x.withdraw(account, zeroAmount, fee, nonce, signature);

        uint256 maxZeroScaledAmount = _maxZeroScaledAmount();
        vm.expectRevert(IBSX1000x.ZeroAmount.selector);
        bsx1000x.withdraw(account, maxZeroScaledAmount, fee, nonce, signature);
    }

    function test_withdraw_revertsIfNonceUsed() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        uint256 initAmount = 100 * 1e18;

        _deposit(account, initAmount);

        uint256 nonce = 1;
        uint256 withdrawAmount = 10 * 1e18;
        uint256 fee = 100;

        bytes32 structHash = keccak256(abi.encode(bsx1000x.WITHDRAW_TYPEHASH(), account, withdrawAmount, nonce));
        bytes memory signature = _signTypedDataHash(accountKey, structHash);

        bsx1000x.withdraw(account, withdrawAmount, fee, nonce, signature);

        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.Withdraw_UsedNonce.selector, account, nonce));
        bsx1000x.withdraw(account, withdrawAmount, fee, nonce, signature);
    }

    function test_withdraw_EOA_revertsIfInvalidSignature() public {
        address account = makeAddr("account");
        (, uint256 maliciousKey) = makeAddrAndKey("malicious");

        uint256 nonce = 1;
        uint256 withdrawAmount = 10 * 1e18;
        uint256 fee = 1 * 1e18;

        bytes32 structHash = keccak256(abi.encode(bsx1000x.WITHDRAW_TYPEHASH(), account, withdrawAmount, nonce));

        bytes memory maliciousSignature = _signTypedDataHash(maliciousKey, structHash);

        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.InvalidSignature.selector, account));
        bsx1000x.withdraw(account, withdrawAmount, fee, nonce, maliciousSignature);
    }

    function test_withdraw_smartContract_revertsIfInvalidSignature() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("owner");
        address contractAccount = address(new ERC1271(owner));
        uint256 initAmount = 100 * 1e18;

        _deposit(contractAccount, initAmount);

        uint256 nonce = 1;
        uint256 withdrawAmount = 10 * 1e18;
        uint256 fee = 1 * 1e18;

        bytes32 structHash = keccak256(abi.encode(bsx1000x.WITHDRAW_TYPEHASH(), contractAccount, withdrawAmount, nonce));
        bytes memory signature = _signTypedDataHash(ownerKey, structHash);

        ERC1271(contractAccount).setNewOwner(makeAddr("newOwner"));

        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.InvalidSignature.selector, contractAccount));
        bsx1000x.withdraw(contractAccount, withdrawAmount, fee, nonce, signature);
    }

    function test_withdraw_revertsIfInsufficientFund() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        uint256 initAmount = 100 * 1e18;

        _deposit(account, initAmount);

        uint256 nonce = 1;
        uint256 withdrawAmount = initAmount + 1;
        uint256 fee = 0;

        bytes32 structHash = keccak256(abi.encode(bsx1000x.WITHDRAW_TYPEHASH(), account, withdrawAmount, nonce));
        bytes memory signature = _signTypedDataHash(accountKey, structHash);

        vm.expectRevert(IBSX1000x.InsufficientAccountBalance.selector);
        bsx1000x.withdraw(account, withdrawAmount, fee, nonce, signature);
    }

    function test_withdraw_revertsIfExceededMaximumWithdrawalFee() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        uint256 initAmount = 100 * 1e18;

        _deposit(account, initAmount);

        uint256 nonce = 1;
        uint256 withdrawAmount = initAmount;
        uint256 fee = bsx1000x.MAX_WITHDRAWAL_FEE() + 1;

        assertEq(bsx1000x.MAX_WITHDRAWAL_FEE(), 1 * 1e18);

        bytes32 structHash = keccak256(abi.encode(bsx1000x.WITHDRAW_TYPEHASH(), account, withdrawAmount, nonce));
        bytes memory signature = _signTypedDataHash(accountKey, structHash);

        vm.expectRevert(IBSX1000x.ExceededMaxWithdrawalFee.selector);
        bsx1000x.withdraw(account, withdrawAmount, fee, nonce, signature);
    }

    function test_depositFund() public {
        uint256 totalAmount;
        uint8 tokenDecimals = collateralToken.decimals();

        for (uint256 i = 1; i < 5; i++) {
            uint256 rawAmount = i * 3000;
            collateralToken.mint(address(this), rawAmount);
            collateralToken.approve(address(bsx1000x), rawAmount);

            uint256 amount = rawAmount.convertTo18D(tokenDecimals);
            totalAmount += amount;
            vm.expectEmit(address(bsx1000x));
            emit IBSX1000x.DepositFund(amount, totalAmount);
            bsx1000x.depositFund(amount);

            assertEq(bsx1000x.fundBalance(), totalAmount);
            assertEq(collateralToken.balanceOf(address(bsx1000x)), totalAmount.convertFrom18D(tokenDecimals));
        }
    }

    function test_depositFund_revertsIfZeroAmount() public {
        vm.expectRevert(IBSX1000x.ZeroAmount.selector);
        bsx1000x.depositFund(0);

        uint256 maxZeroScaledAmount = _maxZeroScaledAmount();
        vm.expectRevert(IBSX1000x.ZeroAmount.selector);
        bsx1000x.depositFund(maxZeroScaledAmount);
    }

    function test_withdrawFund() public {
        uint256 totalAmount = 10 * 1e18;
        uint8 tokenDecimals = collateralToken.decimals();

        uint256 totalRawAmount = totalAmount.convertFrom18D(tokenDecimals);
        collateralToken.mint(address(this), totalRawAmount);
        collateralToken.approve(address(bsx1000x), totalRawAmount);
        bsx1000x.depositFund(totalAmount);

        for (uint256 i = 1; i < 5; i++) {
            uint256 amount = 1e18;
            uint256 rawAmount = amount.convertFrom18D(tokenDecimals);

            vm.expectEmit(address(bsx1000x));
            emit IBSX1000x.WithdrawFund(amount, totalAmount - amount);
            bsx1000x.withdrawFund(amount);

            totalAmount -= amount;
            totalRawAmount -= rawAmount;
            assertEq(bsx1000x.fundBalance(), totalAmount);
            assertEq(collateralToken.balanceOf(address(bsx1000x)), totalRawAmount);
        }
    }

    function test_withdrawFund_revertsIfUnauthorizedCaller() public {
        address malicious = makeAddr("malicious");
        bytes32 role = access.GENERAL_ROLE();
        vm.prank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        bsx1000x.withdrawFund(1000);
    }

    function test_withdrawFund_revertsIfZeroAmount() public {
        vm.expectRevert(IBSX1000x.ZeroAmount.selector);
        bsx1000x.withdrawFund(0);

        uint256 maxZeroScaledAmount = _maxZeroScaledAmount();
        vm.expectRevert(IBSX1000x.ZeroAmount.selector);
        bsx1000x.depositFund(maxZeroScaledAmount);
    }

    function test_withdrawFund_revertsIfInsufficientFund() public {
        uint256 fundBalance = bsx1000x.fundBalance();
        vm.expectRevert(IBSX1000x.InsufficientFundBalance.selector);
        bsx1000x.withdrawFund(fundBalance + 1);
    }

    function test_getPosition_notExist() public {
        address account = makeAddr("account");
        uint256 nonce = 1;
        BSX1000x.Position memory position = bsx1000x.getPosition(account, nonce);
        assertEq(position.productId, 0);
        assertEq(position.margin, 0);
        assertEq(position.leverage, 0);
        assertEq(position.size, 0);
        assertEq(position.openPrice, 0);
        assertEq(position.closePrice, 0);
        assertEq(position.takeProfitPrice, 0);
        assertEq(position.liquidationPrice, 0);
        assertEq(uint8(position.status), uint8(IBSX1000x.PositionStatus.NotExist));
    }

    function test_openPosition_long() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 1 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = 1 * 1e18;
        order.price = 1000 * 1e18;
        order.takeProfitPrice = 1002 * 1e18;
        order.liquidationPrice = 999 * 1e18;
        order.fee = 1e16;

        uint256 fundBalanceBefore = bsx1000x.fundBalance();
        bytes memory signature = _signOpenOrder(signerKey, order);

        vm.expectEmit();
        emit IBSX1000x.OpenPosition(order.productId, order.account, order.nonce, order.fee);
        bsx1000x.openPosition(order, signature);

        uint256 fundBalanceAfter = bsx1000x.fundBalance();
        IBSX1000x.Balance memory accountBalanceAfter = bsx1000x.getBalance(account);

        assertEq(fundBalanceAfter, fundBalanceBefore + uint256(order.fee));
        assertEq(accountBalanceAfter.available, accountBalance - uint256(order.fee) - order.margin);
        assertEq(accountBalanceAfter.locked, order.margin);
        assertEq(
            fundBalanceBefore + accountBalance,
            fundBalanceAfter + accountBalanceAfter.available + accountBalanceAfter.locked
        );

        // check position state
        BSX1000x.Position memory position = bsx1000x.getPosition(account, order.nonce);
        assertEq(position.productId, order.productId);
        assertEq(position.margin, order.margin);
        assertEq(position.leverage, order.leverage);
        assertEq(position.size, order.size);
        assertEq(position.openPrice, order.price);
        assertEq(position.closePrice, 0);
        assertEq(position.takeProfitPrice, order.takeProfitPrice);
        assertEq(position.liquidationPrice, order.liquidationPrice);
        assertEq(uint8(position.status), uint8(IBSX1000x.PositionStatus.Open));
    }

    function test_openPosition_short() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 1 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = -1 * 1e18;
        order.price = 1000 * 1e18;
        order.takeProfitPrice = 999 * 1e18;
        order.liquidationPrice = 1001 * 1e18;
        order.fee = 1e16;

        uint256 fundBalanceBefore = bsx1000x.fundBalance();
        bytes memory signature = _signOpenOrder(signerKey, order);

        vm.expectEmit();
        emit IBSX1000x.OpenPosition(order.productId, order.account, order.nonce, order.fee);
        bsx1000x.openPosition(order, signature);

        uint256 fundBalanceAfter = bsx1000x.fundBalance();
        IBSX1000x.Balance memory accountBalanceAfter = bsx1000x.getBalance(account);

        assertEq(fundBalanceAfter, fundBalanceBefore + uint256(order.fee));
        assertEq(accountBalanceAfter.available, accountBalance - uint256(order.fee) - order.margin);
        assertEq(accountBalanceAfter.locked, order.margin);
        assertEq(
            fundBalanceBefore + accountBalance,
            fundBalanceAfter + accountBalanceAfter.available + accountBalanceAfter.locked
        );

        // check position state
        BSX1000x.Position memory position = bsx1000x.getPosition(account, order.nonce);
        assertEq(position.productId, order.productId);
        assertEq(position.margin, order.margin);
        assertEq(position.leverage, order.leverage);
        assertEq(position.size, order.size);
        assertEq(position.openPrice, order.price);
        assertEq(position.closePrice, 0);
        assertEq(position.takeProfitPrice, order.takeProfitPrice);
        assertEq(position.liquidationPrice, order.liquidationPrice);
        assertEq(uint8(position.status), uint8(IBSX1000x.PositionStatus.Open));
    }

    function test_openPosition_revertsIfUnauthorizedCaller() public {
        BSX1000x.Order memory order;
        bytes memory signature;
        address malicious = makeAddr("malicious");
        bytes32 role = access.BSX1000_OPERATOR_ROLE();
        vm.prank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        bsx1000x.openPosition(order, signature);
    }

    function test_openPosition_revertsIfUnauthorizedSigner() public {
        address account = makeAddr("account");
        (address maliciousSigner, uint256 maliciousSignerKey) = makeAddrAndKey("maliciousSigner");

        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 1 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = 1 * 1e18;
        order.price = 1000 * 1e18;
        order.takeProfitPrice = 1002 * 1e18;
        order.liquidationPrice = 999 * 1e18;
        order.fee = 1e16;

        bytes memory signature = _signOpenOrder(maliciousSignerKey, order);
        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.UnauthorizedSigner.selector, account, maliciousSigner));
        bsx1000x.openPosition(order, signature);
    }

    function test_openPosition_revertsIfNonceUsed() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();
        _deposit(account, 100 * 1e18);

        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 1 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = 1 * 1e18;
        order.price = 1000 * 1e18;
        order.takeProfitPrice = 1002 * 1e18;
        order.liquidationPrice = 999 * 1e18;
        order.fee = 1e16;

        bytes memory signature = _signOpenOrder(signerKey, order);
        bsx1000x.openPosition(order, signature);

        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.PositionExisted.selector, account, order.nonce));
        bsx1000x.openPosition(order, signature);
    }

    function test_openPosition_revertsIfExceedMaxLevegrage() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);

        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 1 * 1e18;
        order.size = 1 * 1e18;
        order.price = 1000 * 1e18;
        order.takeProfitPrice = 1002 * 1e18;
        order.liquidationPrice = 999 * 1e18;
        order.fee = 1e16;

        assertEq(bsx1000x.MAX_LEVERAGE(), 1000e18);
        order.leverage = 1001 * 1e18;

        bytes memory signature = _signOpenOrder(signerKey, order);
        vm.expectRevert(IBSX1000x.ExceededMaxLeverage.selector);
        bsx1000x.openPosition(order, signature);
    }

    function test_openPosition_revertsIfExceedNotionalAmount() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);

        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.takeProfitPrice = 1002 * 1e18;
        order.liquidationPrice = 999 * 1e18;
        order.fee = 1e16;

        order.margin = 1 * 1e18;
        order.leverage = 1000 * 1e18;

        order.size = 1 * 1e18 + 1e18;
        order.price = 1000 * 1e18;

        bytes memory signature = _signOpenOrder(signerKey, order);
        vm.expectRevert(IBSX1000x.ExceededNotionalAmount.selector);
        bsx1000x.openPosition(order, signature);
    }

    function test_openPosition_revertsIfInvalidTakeProfitPrice() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);

        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 1 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = 1 * 1e18;
        order.price = 1000 * 1e18;
        order.liquidationPrice = 999 * 1e18;
        order.fee = 1e16;

        // not profit
        order.takeProfitPrice = 999 * 1e18;
        bytes memory signature = _signOpenOrder(signerKey, order);
        vm.expectRevert(IBSX1000x.InvalidTakeProfitPrice.selector);
        bsx1000x.openPosition(order, signature);

        // exceed max profit
        assertEq(bsx1000x.MAX_PROFIT_FACTOR(), 3);
        order.takeProfitPrice = 1003 * 1e18 + 1e18;
        signature = _signOpenOrder(signerKey, order);
        vm.expectRevert(IBSX1000x.InvalidTakeProfitPrice.selector);
        bsx1000x.openPosition(order, signature);
    }

    function test_openPosition_revertsIfInvalidLiquidationPrice() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);

        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 1 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = 1 * 1e18;
        order.price = 1000 * 1e18;
        order.takeProfitPrice = 1002 * 1e18;
        order.fee = 1e16;

        // profitable price
        order.liquidationPrice = 1001 * 1e18;
        bytes memory signature = _signOpenOrder(signerKey, order);
        vm.expectRevert(IBSX1000x.InvalidLiquidationPrice.selector);
        bsx1000x.openPosition(order, signature);

        // exceed max loss
        assertEq(bsx1000x.MAX_LOSS_FACTOR(), -1);
        order.liquidationPrice = 999 * 1e18 - 1e18;
        signature = _signOpenOrder(signerKey, order);
        vm.expectRevert(IBSX1000x.InvalidLiquidationPrice.selector);
        bsx1000x.openPosition(order, signature);
    }

    function test_openPosition_revertsIfInvalidOrderFee() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);

        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 1 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = 1 * 1e18;
        order.price = 1000 * 1e18;
        order.takeProfitPrice = 1002 * 1e18;
        order.liquidationPrice = 999 * 1e18;

        order.fee = 1 * 1e18 + 1;

        // profitable price
        bytes memory signature = _signOpenOrder(signerKey, order);
        vm.expectRevert(IBSX1000x.InvalidOrderFee.selector);
        bsx1000x.openPosition(order, signature);
    }

    function test_openPosition_revertsIfInsufficientBalance() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();
        _deposit(account, 10 * 1e18);

        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.leverage = 1000 * 1e18;
        order.size = 1 * 1e18;
        order.price = 1000 * 1e18;
        order.takeProfitPrice = 1002 * 1e18;
        order.liquidationPrice = 999 * 1e18;

        // insufficient balance for margin
        order.margin = 10 * 1e18 + 1;
        order.fee = 0;
        bytes memory signature = _signOpenOrder(signerKey, order);
        vm.expectRevert(IBSX1000x.InsufficientAccountBalance.selector);
        bsx1000x.openPosition(order, signature);

        // insufficient balance for fee
        order.margin = 10 * 1e18;
        order.fee = 1;
        signature = _signOpenOrder(signerKey, order);
        vm.expectRevert(IBSX1000x.InsufficientAccountBalance.selector);
        bsx1000x.openPosition(order, signature);
    }

    function test_openPosition_withCredit_long() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 10 * 1e18;
        order.leverage = 100 * 1e18;
        order.size = 1 * 1e18;
        order.price = 1000 * 1e18;
        order.takeProfitPrice = 1002 * 1e18;
        order.liquidationPrice = 999 * 1e18;
        order.fee = 1e16;
        uint256 credit = 4 * 1e18;

        uint256 fundBalanceBefore = bsx1000x.fundBalance();
        bytes memory signature = _signOpenOrder(signerKey, order);

        vm.expectEmit();
        emit IBSX1000x.OpenPosition(order.productId, order.account, order.nonce, order.fee);
        bsx1000x.openPosition(order, credit, signature);

        uint256 fundBalanceAfter = bsx1000x.fundBalance();
        IBSX1000x.Balance memory accountBalanceAfter = bsx1000x.getBalance(account);

        assertEq(fundBalanceAfter, fundBalanceBefore + uint256(order.fee) - credit);
        assertEq(accountBalanceAfter.available, accountBalance - uint256(order.fee) - (order.margin - credit));
        assertEq(accountBalanceAfter.locked, order.margin - credit);
        assertEq(
            fundBalanceBefore + accountBalance,
            fundBalanceAfter + accountBalanceAfter.available + accountBalanceAfter.locked + credit
        );

        // check position state
        BSX1000x.Position memory position = bsx1000x.getPosition(account, order.nonce);
        assertEq(position.productId, order.productId);
        assertEq(position.margin, order.margin);
        assertEq(position.leverage, order.leverage);
        assertEq(position.size, order.size);
        assertEq(position.openPrice, order.price);
        assertEq(position.closePrice, 0);
        assertEq(position.takeProfitPrice, order.takeProfitPrice);
        assertEq(position.liquidationPrice, order.liquidationPrice);
        assertEq(uint8(position.status), uint8(IBSX1000x.PositionStatus.Open));
    }

    function test_openPosition_withCredit_short() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 10 * 1e18;
        order.leverage = 100 * 1e18;
        order.size = -1 * 1e18;
        order.price = 1000 * 1e18;
        order.takeProfitPrice = 999 * 1e18;
        order.liquidationPrice = 1001 * 1e18;
        order.fee = 0;
        uint256 credit = 5 * 1e18;

        uint256 fundBalanceBefore = bsx1000x.fundBalance();
        bytes memory signature = _signOpenOrder(signerKey, order);

        vm.expectEmit();
        emit IBSX1000x.OpenPosition(order.productId, order.account, order.nonce, order.fee);
        bsx1000x.openPosition(order, credit, signature);

        uint256 fundBalanceAfter = bsx1000x.fundBalance();
        IBSX1000x.Balance memory accountBalanceAfter = bsx1000x.getBalance(account);

        assertEq(fundBalanceAfter, fundBalanceBefore + uint256(order.fee) - credit);
        assertEq(accountBalanceAfter.available, accountBalance - uint256(order.fee) - (order.margin - credit));
        assertEq(accountBalanceAfter.locked, order.margin - credit);
        assertEq(
            fundBalanceBefore + accountBalance,
            fundBalanceAfter + accountBalanceAfter.available + accountBalanceAfter.locked + credit
        );

        // check position state
        BSX1000x.Position memory position = bsx1000x.getPosition(account, order.nonce);
        assertEq(position.productId, order.productId);
        assertEq(position.margin, order.margin);
        assertEq(position.leverage, order.leverage);
        assertEq(position.size, order.size);
        assertEq(position.openPrice, order.price);
        assertEq(position.closePrice, 0);
        assertEq(position.takeProfitPrice, order.takeProfitPrice);
        assertEq(position.liquidationPrice, order.liquidationPrice);
        assertEq(uint8(position.status), uint8(IBSX1000x.PositionStatus.Open));
    }

    function test_openPosition_revertsIfInvalidCredit() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 10 * 1e18;
        order.leverage = 100 * 1e18;
        order.size = -1 * 1e18;
        order.price = 1000 * 1e18;
        order.takeProfitPrice = 999 * 1e18;
        order.liquidationPrice = 1001 * 1e18;
        order.fee = 0;
        bytes memory signature = _signOpenOrder(signerKey, order);

        uint256 credit = 6 * 1e18;

        vm.expectRevert(IBSX1000x.InvalidCredit.selector);
        bsx1000x.openPosition(order, credit, signature);
    }

    function test_closePosition_long_withProfit() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        // open position
        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 10 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = 1 * 1e18;
        order.price = 10_000 * 1e18;
        order.takeProfitPrice = 10_025 * 1e18;
        order.liquidationPrice = 9998 * 1e18;
        order.fee = 1e16;
        bytes memory openSignature = _signOpenOrder(signerKey, order);
        vm.expectEmit();
        emit IBSX1000x.OpenPosition(order.productId, order.account, order.nonce, order.fee);
        bsx1000x.openPosition(order, openSignature);

        // close position
        uint128 closePrice = 10_015 * 1e18;
        int256 closePositionFee = 2e16;
        int256 pnl = 15 * 1e18;
        bytes memory closeSignature = _signCloseOrder(signerKey, order);

        IBSX1000x.Balance memory accountBalanceBefore = bsx1000x.getBalance(account);
        uint256 fundBalanceBefore = bsx1000x.fundBalance();

        vm.expectEmit();
        emit IBSX1000x.ClosePosition(
            order.productId, order.account, order.nonce, pnl, closePositionFee, IBSX1000x.ClosePositionReason.Normal
        );
        bsx1000x.closePosition(
            order.productId, order.account, order.nonce, closePrice, pnl, closePositionFee, closeSignature
        );

        BSX1000x.Position memory position = bsx1000x.getPosition(account, order.nonce);
        IBSX1000x.Balance memory accountBalanceAfter = bsx1000x.getBalance(account);
        uint256 fundBalanceAfter = bsx1000x.fundBalance();

        assertEq(fundBalanceAfter, fundBalanceBefore - uint256(pnl) + uint256(closePositionFee));
        assertEq(
            accountBalanceAfter.available,
            accountBalanceBefore.available + uint256(pnl) - uint256(closePositionFee) + order.margin
        );
        assertEq(accountBalanceAfter.locked, 0);
        assertEq(
            fundBalanceBefore + accountBalanceBefore.available + accountBalanceBefore.locked,
            fundBalanceAfter + accountBalanceAfter.available
        );

        // check position state
        assertEq(position.productId, order.productId);
        assertEq(position.margin, order.margin);
        assertEq(position.leverage, order.leverage);
        assertEq(position.size, order.size);
        assertEq(position.openPrice, order.price);
        assertEq(position.closePrice, closePrice);
        assertEq(position.takeProfitPrice, order.takeProfitPrice);
        assertEq(position.liquidationPrice, order.liquidationPrice);
        assertEq(uint8(position.status), uint8(IBSX1000x.PositionStatus.Closed));
    }

    function test_closePosition_short_withProfit() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        // open position
        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 10 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = -1 * 1e18;
        order.price = 10_000 * 1e18;
        order.takeProfitPrice = 9985 * 1e18;
        order.liquidationPrice = 10_009 * 1e18;
        order.fee = 1e16;
        bytes memory openSignature = _signOpenOrder(signerKey, order);
        vm.expectEmit();
        emit IBSX1000x.OpenPosition(order.productId, order.account, order.nonce, order.fee);
        bsx1000x.openPosition(order, openSignature);

        // close position
        uint128 closePrice = 9990 * 1e18;
        int256 closePositionFee = 2e16;
        int256 pnl = 10 * 1e18;
        bytes memory closeSignature = _signCloseOrder(signerKey, order);

        IBSX1000x.Balance memory accountBalanceBefore = bsx1000x.getBalance(account);
        uint256 fundBalanceBefore = bsx1000x.fundBalance();

        vm.expectEmit();
        emit IBSX1000x.ClosePosition(
            order.productId, order.account, order.nonce, pnl, closePositionFee, IBSX1000x.ClosePositionReason.Normal
        );
        bsx1000x.closePosition(
            order.productId, order.account, order.nonce, closePrice, pnl, closePositionFee, closeSignature
        );

        BSX1000x.Position memory position = bsx1000x.getPosition(account, order.nonce);
        IBSX1000x.Balance memory accountBalanceAfter = bsx1000x.getBalance(account);
        uint256 fundBalanceAfter = bsx1000x.fundBalance();

        assertEq(fundBalanceAfter, fundBalanceBefore - uint256(pnl) + uint256(closePositionFee));
        assertEq(
            accountBalanceAfter.available,
            accountBalanceBefore.available + uint256(pnl) - uint256(closePositionFee) + order.margin
        );
        assertEq(accountBalanceAfter.locked, 0);
        assertEq(
            fundBalanceBefore + accountBalanceBefore.available + accountBalanceBefore.locked,
            fundBalanceAfter + accountBalanceAfter.available
        );

        // check position state
        assertEq(position.productId, order.productId);
        assertEq(position.margin, order.margin);
        assertEq(position.leverage, order.leverage);
        assertEq(position.size, order.size);
        assertEq(position.openPrice, order.price);
        assertEq(position.closePrice, closePrice);
        assertEq(position.takeProfitPrice, order.takeProfitPrice);
        assertEq(position.liquidationPrice, order.liquidationPrice);
        assertEq(uint8(position.status), uint8(IBSX1000x.PositionStatus.Closed));
    }

    function test_closePosition_withCredit_withProfit() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        // open position
        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 10 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = 1 * 1e18;
        order.price = 10_000 * 1e18;
        order.takeProfitPrice = 10_025 * 1e18;
        order.liquidationPrice = 9998 * 1e18;
        order.fee = 1e16;
        uint256 credit = 2 * 1e17;
        {
            bytes memory openSignature = _signOpenOrder(signerKey, order);
            vm.expectEmit();
            emit IBSX1000x.OpenPosition(order.productId, order.account, order.nonce, order.fee);
            bsx1000x.openPosition(order, credit, openSignature);
        }

        // close position
        uint128 closePrice = 10_015 * 1e18;
        int256 closePositionFee = 2e16;
        int256 pnl = 15 * 1e18;
        bytes memory closeSignature = _signCloseOrder(signerKey, order);

        IBSX1000x.Balance memory accountBalanceBefore = bsx1000x.getBalance(account);
        uint256 fundBalanceBefore = bsx1000x.fundBalance();

        vm.expectEmit();
        emit IBSX1000x.ClosePosition(
            order.productId, order.account, order.nonce, pnl, closePositionFee, IBSX1000x.ClosePositionReason.Normal
        );
        bsx1000x.closePosition(
            order.productId, order.account, order.nonce, closePrice, pnl, closePositionFee, closeSignature
        );

        BSX1000x.Position memory position = bsx1000x.getPosition(account, order.nonce);
        IBSX1000x.Balance memory accountBalanceAfter = bsx1000x.getBalance(account);
        uint256 fundBalanceAfter = bsx1000x.fundBalance();

        assertEq(fundBalanceAfter, fundBalanceBefore - uint256(pnl) + uint256(closePositionFee));
        assertEq(
            accountBalanceAfter.available,
            accountBalanceBefore.available + uint256(pnl) - uint256(closePositionFee) + order.margin
        );
        assertEq(accountBalanceAfter.locked, 0);
        assertEq(
            fundBalanceBefore + accountBalanceBefore.available + accountBalanceBefore.locked + credit,
            fundBalanceAfter + accountBalanceAfter.available
        );

        // check position state
        assertEq(position.productId, order.productId);
        assertEq(position.margin, order.margin);
        assertEq(position.leverage, order.leverage);
        assertEq(position.size, order.size);
        assertEq(position.openPrice, order.price);
        assertEq(position.closePrice, closePrice);
        assertEq(position.takeProfitPrice, order.takeProfitPrice);
        assertEq(position.liquidationPrice, order.liquidationPrice);
        assertEq(uint8(position.status), uint8(IBSX1000x.PositionStatus.Closed));
    }

    function test_closePosition_revertsIfUnauthorizedCaller() public {
        address account;
        uint32 productId;
        uint256 nonce;
        uint128 closePrice;
        int256 pnl;
        int256 fee;
        bytes memory signature;

        address malicious = makeAddr("malicious");
        bytes32 role = access.BSX1000_OPERATOR_ROLE();
        vm.prank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        bsx1000x.closePosition(productId, account, nonce, closePrice, pnl, fee, signature);
    }

    function test_closePosition_revertsIfPositionNotExist() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);

        // open position
        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 10 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = 1 * 1e18;
        order.price = 10_000 * 1e18;
        order.takeProfitPrice = 10_025 * 1e18;
        order.liquidationPrice = 9998 * 1e18;
        order.fee = 1e16;

        // close position
        uint128 closePrice;
        int256 closePositionFee;
        int256 pnl;
        bytes memory closeSignature = _signCloseOrder(signerKey, order);

        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.PositionNotOpening.selector, account, order.nonce));
        bsx1000x.closePosition(
            order.productId, order.account, order.nonce, closePrice, pnl, closePositionFee, closeSignature
        );
    }

    function test_closePosition_revertsIfProductIdMismatch() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        // open position
        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 10 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = -1 * 1e18;
        order.price = 10_000 * 1e18;
        order.takeProfitPrice = 9985 * 1e18;
        order.liquidationPrice = 10_009 * 1e18;
        order.fee = 1e16;
        bytes memory openSignature = _signOpenOrder(signerKey, order);
        bsx1000x.openPosition(order, openSignature);

        // close position
        uint32 invalidProductId = 2;
        order.productId = invalidProductId;
        uint128 closePrice = 9975 * 1e18;
        int256 closePositionFee = 2e16;
        int256 pnl;
        bytes memory closeSignature = _signCloseOrder(signerKey, order);

        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.ProductIdMismatch.selector));
        bsx1000x.closePosition(
            invalidProductId, order.account, order.nonce, closePrice, pnl, closePositionFee, closeSignature
        );
    }

    function test_closePosition_revertsIfInvalidClosePrice() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        // open long position
        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 10 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = 1 * 1e18;
        order.price = 10_000 * 1e18;
        order.takeProfitPrice = 10_005 * 1e18;
        order.liquidationPrice = 9995 * 1e18;
        order.fee = 1e16;
        bytes memory openSignature = _signOpenOrder(signerKey, order);
        bsx1000x.openPosition(order, openSignature);

        int256 closePositionFee;
        int256 pnl;

        // long: close price exceed take profit price
        uint128 closePrice = order.takeProfitPrice + 1;
        bytes memory closeSignature = _signCloseOrder(signerKey, order);
        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.InvalidClosePrice.selector));
        bsx1000x.closePosition(
            order.productId, order.account, order.nonce, closePrice, pnl, closePositionFee, closeSignature
        );

        // long: close price exceed liquidation price
        closePrice = order.liquidationPrice - 1;
        closeSignature = _signCloseOrder(signerKey, order);
        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.InvalidClosePrice.selector));
        bsx1000x.closePosition(
            order.productId, order.account, order.nonce, closePrice, pnl, closePositionFee, closeSignature
        );

        // open short position
        order.size = -1 * 1e18;
        order.takeProfitPrice = 9995 * 1e18;
        order.liquidationPrice = 10_005 * 1e18;
        order.nonce = 12;
        openSignature = _signOpenOrder(signerKey, order);
        bsx1000x.openPosition(order, openSignature);

        // short: close price exceed take profit price
        closePrice = order.takeProfitPrice - 1;
        closeSignature = _signCloseOrder(signerKey, order);
        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.InvalidClosePrice.selector));
        bsx1000x.closePosition(
            order.productId, order.account, order.nonce, closePrice, pnl, closePositionFee, closeSignature
        );

        // short: close price exceed liquidation price
        closePrice = order.liquidationPrice + 1;
        closeSignature = _signCloseOrder(signerKey, order);
        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.InvalidClosePrice.selector));
        bsx1000x.closePosition(
            order.productId, order.account, order.nonce, closePrice, pnl, closePositionFee, closeSignature
        );
    }

    function test_closePosition_revertsIfInvalidPnl() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        // open position
        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 10 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = 1 * 1e18;
        order.price = 10_000 * 1e18;
        order.takeProfitPrice = 10_005 * 1e18;
        order.liquidationPrice = 9995 * 1e18;
        order.fee = 1e16;
        bytes memory openSignature = _signOpenOrder(signerKey, order);
        bsx1000x.openPosition(order, openSignature);

        // profit exceed max allowed
        uint128 closePrice = order.takeProfitPrice;
        int256 closePositionFee = 2e16;
        int256 pnl = 31 * 1e18;
        bytes memory closeSignature = _signCloseOrder(signerKey, order);
        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.InvalidPnl.selector));
        bsx1000x.closePosition(
            order.productId, order.account, order.nonce, closePrice, pnl, closePositionFee, closeSignature
        );

        // loss exceed max allowed
        closePrice = order.liquidationPrice;
        closePositionFee = 2e16;
        pnl = -11 * 1e18;
        closeSignature = _signCloseOrder(signerKey, order);
        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.InvalidPnl.selector));
        bsx1000x.closePosition(
            order.productId, order.account, order.nonce, closePrice, pnl, closePositionFee, closeSignature
        );
    }

    function test_closePosition_revertsIfInvalidOrderFee() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        // open position
        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 10 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = 1 * 1e18;
        order.price = 10_000 * 1e18;
        order.takeProfitPrice = 10_030 * 1e18;
        order.liquidationPrice = 9990 * 1e18;
        order.fee = 1e16;
        bytes memory openSignature = _signOpenOrder(signerKey, order);
        vm.expectEmit();
        emit IBSX1000x.OpenPosition(order.productId, order.account, order.nonce, order.fee);
        bsx1000x.openPosition(order, openSignature);

        // fee is greater than margin
        uint128 closePrice = 10_020 * 1e18;
        int256 closePositionFee = 10 * 1e18 + 1;
        int256 pnl = 20 * 1e18;
        bytes memory closeSignature = _signCloseOrder(signerKey, order);
        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.InvalidOrderFee.selector));
        bsx1000x.closePosition(
            order.productId, order.account, order.nonce, closePrice, pnl, closePositionFee, closeSignature
        );

        // fee + |loss| is greater than margin
        // margin = 10, loss = 7, fee = 4
        closePrice = 9993 * 1e18;
        closePositionFee = 4 * 1e18;
        pnl = -7 * 1e18;
        closeSignature = _signCloseOrder(signerKey, order);
        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.InvalidOrderFee.selector));
        bsx1000x.closePosition(
            order.productId, order.account, order.nonce, closePrice, pnl, closePositionFee, closeSignature
        );
    }

    function test_closePosition_revertsIfInsufficientFundBalance() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        // open position
        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 10 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = 1 * 1e18;
        order.price = 10_000 * 1e18;
        order.takeProfitPrice = 10_030 * 1e18;
        order.liquidationPrice = 9995 * 1e18;
        order.fee = 1e16;
        bytes memory openSignature = _signOpenOrder(signerKey, order);
        bsx1000x.openPosition(order, openSignature);

        uint128 closePrice = 10_030 * 1e18;
        int256 closePositionFee = 10 * 1e18;
        int256 pnl = 30 * 1e18;
        bytes memory closeSignature = _signCloseOrder(signerKey, order);
        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.InsufficientFundBalance.selector));
        bsx1000x.closePosition(
            order.productId, order.account, order.nonce, closePrice, pnl, closePositionFee, closeSignature
        );
    }

    function test_forceClosePosition_withCredit_takeProfit() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        // open position
        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 10 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = 1 * 1e18;
        order.price = 10_000 * 1e18;
        order.takeProfitPrice = 10_020 * 1e18;
        order.liquidationPrice = 9990 * 1e18;
        order.fee = 2e18;
        uint256 credit = 5 * 1e18;
        {
            bytes memory openSignature = _signOpenOrder(signerKey, order);
            vm.expectEmit();
            emit IBSX1000x.OpenPosition(order.productId, order.account, order.nonce, order.fee);
            bsx1000x.openPosition(order, credit, openSignature);
        }

        // force close position
        int256 pnl = 20 * 1e18;
        int256 closePositionFee = 1e18;

        IBSX1000x.Balance memory accountBalanceBefore = bsx1000x.getBalance(account);
        uint256 fundBalanceBefore = bsx1000x.fundBalance();

        vm.expectEmit();
        emit IBSX1000x.ClosePosition(
            order.productId, order.account, order.nonce, pnl, closePositionFee, IBSX1000x.ClosePositionReason.TakeProfit
        );
        bsx1000x.forceClosePosition(
            order.productId, order.account, order.nonce, pnl, closePositionFee, IBSX1000x.ClosePositionReason.TakeProfit
        );

        IBSX1000x.Position memory position = bsx1000x.getPosition(account, order.nonce);
        IBSX1000x.Balance memory accountBalanceAfter = bsx1000x.getBalance(account);
        uint256 fundBalanceAfter = bsx1000x.fundBalance();

        assertEq(fundBalanceAfter, fundBalanceBefore - uint256(pnl) + uint256(closePositionFee));
        assertEq(
            accountBalanceAfter.available,
            accountBalanceBefore.available + uint256(pnl) - uint256(closePositionFee) + order.margin
        );
        assertEq(accountBalanceAfter.locked, 0);
        assertEq(
            fundBalanceBefore + accountBalanceBefore.available + accountBalanceBefore.locked + credit,
            fundBalanceAfter + accountBalanceAfter.available
        );

        // check position state
        assertEq(position.productId, order.productId);
        assertEq(position.margin, order.margin);
        assertEq(position.leverage, order.leverage);
        assertEq(position.size, order.size);
        assertEq(position.openPrice, order.price);
        assertEq(position.closePrice, order.takeProfitPrice);
        assertEq(position.takeProfitPrice, order.takeProfitPrice);
        assertEq(position.liquidationPrice, order.liquidationPrice);
        assertEq(uint8(position.status), uint8(IBSX1000x.PositionStatus.TakeProfit));
    }

    function test_forceClosePosition_long_takeProfit() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        // open position
        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 10 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = 1 * 1e18;
        order.price = 10_000 * 1e18;
        order.takeProfitPrice = 10_020 * 1e18;
        order.liquidationPrice = 9990 * 1e18;
        order.fee = 2e18;
        bytes memory openSignature = _signOpenOrder(signerKey, order);
        vm.expectEmit();
        emit IBSX1000x.OpenPosition(order.productId, order.account, order.nonce, order.fee);
        bsx1000x.openPosition(order, openSignature);

        // force close position
        int256 pnl = 20 * 1e18;
        int256 closePositionFee = 1e18;

        IBSX1000x.Balance memory accountBalanceBefore = bsx1000x.getBalance(account);
        uint256 fundBalanceBefore = bsx1000x.fundBalance();

        vm.expectEmit();
        emit IBSX1000x.ClosePosition(
            order.productId, order.account, order.nonce, pnl, closePositionFee, IBSX1000x.ClosePositionReason.TakeProfit
        );
        bsx1000x.forceClosePosition(
            order.productId, order.account, order.nonce, pnl, closePositionFee, IBSX1000x.ClosePositionReason.TakeProfit
        );

        IBSX1000x.Position memory position = bsx1000x.getPosition(account, order.nonce);
        IBSX1000x.Balance memory accountBalanceAfter = bsx1000x.getBalance(account);
        uint256 fundBalanceAfter = bsx1000x.fundBalance();

        assertEq(fundBalanceAfter, fundBalanceBefore - uint256(pnl) + uint256(closePositionFee));
        assertEq(
            accountBalanceAfter.available,
            accountBalanceBefore.available + uint256(pnl) - uint256(closePositionFee) + order.margin
        );
        assertEq(accountBalanceAfter.locked, 0);
        assertEq(
            fundBalanceBefore + accountBalanceBefore.available + accountBalanceBefore.locked,
            fundBalanceAfter + accountBalanceAfter.available
        );

        // check position state
        assertEq(position.productId, order.productId);
        assertEq(position.margin, order.margin);
        assertEq(position.leverage, order.leverage);
        assertEq(position.size, order.size);
        assertEq(position.openPrice, order.price);
        assertEq(position.closePrice, order.takeProfitPrice);
        assertEq(position.takeProfitPrice, order.takeProfitPrice);
        assertEq(position.liquidationPrice, order.liquidationPrice);
        assertEq(uint8(position.status), uint8(IBSX1000x.PositionStatus.TakeProfit));
    }

    function test_forceClosePosition_short_takeProfit() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        // open position
        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 3;
        order.margin = 5 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = -1 * 1e18;
        order.price = 5000 * 1e18;
        order.takeProfitPrice = 4997 * 1e18;
        order.liquidationPrice = 5001 * 1e18;
        order.fee = 1e18;
        bytes memory openSignature = _signOpenOrder(signerKey, order);
        vm.expectEmit();
        emit IBSX1000x.OpenPosition(order.productId, order.account, order.nonce, order.fee);
        bsx1000x.openPosition(order, openSignature);

        // force close position
        int256 pnl = 3 * 1e18;
        int256 closePositionFee = 2e18;

        IBSX1000x.Balance memory accountBalanceBefore = bsx1000x.getBalance(account);
        uint256 fundBalanceBefore = bsx1000x.fundBalance();

        vm.expectEmit();
        emit IBSX1000x.ClosePosition(
            order.productId, order.account, order.nonce, pnl, closePositionFee, IBSX1000x.ClosePositionReason.TakeProfit
        );
        bsx1000x.forceClosePosition(
            order.productId, order.account, order.nonce, pnl, closePositionFee, IBSX1000x.ClosePositionReason.TakeProfit
        );

        IBSX1000x.Position memory position = bsx1000x.getPosition(account, order.nonce);
        IBSX1000x.Balance memory accountBalanceAfter = bsx1000x.getBalance(account);
        uint256 fundBalanceAfter = bsx1000x.fundBalance();

        assertEq(fundBalanceAfter, fundBalanceBefore - uint256(pnl) + uint256(closePositionFee));
        assertEq(
            accountBalanceAfter.available,
            accountBalanceBefore.available + uint256(pnl) - uint256(closePositionFee) + order.margin
        );
        assertEq(accountBalanceAfter.locked, 0);
        assertEq(
            fundBalanceBefore + accountBalanceBefore.available + accountBalanceBefore.locked,
            fundBalanceAfter + accountBalanceAfter.available
        );

        // check position state
        assertEq(position.productId, order.productId);
        assertEq(position.margin, order.margin);
        assertEq(position.leverage, order.leverage);
        assertEq(position.size, order.size);
        assertEq(position.openPrice, order.price);
        assertEq(position.closePrice, order.takeProfitPrice);
        assertEq(position.takeProfitPrice, order.takeProfitPrice);
        assertEq(position.liquidationPrice, order.liquidationPrice);
        assertEq(uint8(position.status), uint8(IBSX1000x.PositionStatus.TakeProfit));
    }

    function test_forceClosePosition_long_liquidation() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        // open position
        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 3;
        order.margin = 15 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = 1 * 1e18;
        order.price = 15_000 * 1e18;
        order.takeProfitPrice = 15_030 * 1e18;
        order.liquidationPrice = 14_990 * 1e18;
        order.fee = 1e18;
        bytes memory openSignature = _signOpenOrder(signerKey, order);
        vm.expectEmit();
        emit IBSX1000x.OpenPosition(order.productId, order.account, order.nonce, order.fee);
        bsx1000x.openPosition(order, openSignature);

        // force close position
        int256 pnl = -10 * 1e18;
        int256 closePositionFee = 2e18;

        IBSX1000x.Balance memory accountBalanceBefore = bsx1000x.getBalance(account);
        uint256 fundBalanceBefore = bsx1000x.fundBalance();

        vm.expectEmit();
        emit IBSX1000x.ClosePosition(
            order.productId,
            order.account,
            order.nonce,
            pnl,
            closePositionFee,
            IBSX1000x.ClosePositionReason.Liquidation
        );
        bsx1000x.forceClosePosition(
            order.productId,
            order.account,
            order.nonce,
            pnl,
            closePositionFee,
            IBSX1000x.ClosePositionReason.Liquidation
        );

        IBSX1000x.Position memory position = bsx1000x.getPosition(account, order.nonce);
        IBSX1000x.Balance memory accountBalanceAfter = bsx1000x.getBalance(account);
        uint256 fundBalanceAfter = bsx1000x.fundBalance();

        assertEq(fundBalanceAfter, fundBalanceBefore + uint256(-pnl) + uint256(closePositionFee));
        assertEq(
            accountBalanceAfter.available,
            accountBalanceBefore.available - uint256(-pnl) - uint256(closePositionFee) + order.margin
        );
        assertEq(accountBalanceAfter.locked, 0);
        assertEq(
            fundBalanceBefore + accountBalanceBefore.available + accountBalanceBefore.locked,
            fundBalanceAfter + accountBalanceAfter.available
        );

        // check position state
        assertEq(position.productId, order.productId);
        assertEq(position.margin, order.margin);
        assertEq(position.leverage, order.leverage);
        assertEq(position.size, order.size);
        assertEq(position.openPrice, order.price);
        assertEq(position.closePrice, order.liquidationPrice);
        assertEq(position.takeProfitPrice, order.takeProfitPrice);
        assertEq(position.liquidationPrice, order.liquidationPrice);
        assertEq(uint8(position.status), uint8(IBSX1000x.PositionStatus.Liquidated));
    }

    function test_forceClosePosition_short_liquidation() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        // open position
        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 3;
        order.margin = 5 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = -1 * 1e18;
        order.price = 5000 * 1e18;
        order.takeProfitPrice = 4997 * 1e18;
        order.liquidationPrice = 5004 * 1e18;
        order.fee = 1e18;
        bytes memory openSignature = _signOpenOrder(signerKey, order);
        vm.expectEmit();
        emit IBSX1000x.OpenPosition(order.productId, order.account, order.nonce, order.fee);
        bsx1000x.openPosition(order, openSignature);

        // force close position
        int256 pnl = -4 * 1e18;
        int256 closePositionFee = 1e18;

        IBSX1000x.Balance memory accountBalanceBefore = bsx1000x.getBalance(account);
        uint256 fundBalanceBefore = bsx1000x.fundBalance();

        vm.expectEmit();
        emit IBSX1000x.ClosePosition(
            order.productId,
            order.account,
            order.nonce,
            pnl,
            closePositionFee,
            IBSX1000x.ClosePositionReason.Liquidation
        );
        bsx1000x.forceClosePosition(
            order.productId,
            order.account,
            order.nonce,
            pnl,
            closePositionFee,
            IBSX1000x.ClosePositionReason.Liquidation
        );

        IBSX1000x.Position memory position = bsx1000x.getPosition(account, order.nonce);
        IBSX1000x.Balance memory accountBalanceAfter = bsx1000x.getBalance(account);
        uint256 fundBalanceAfter = bsx1000x.fundBalance();

        assertEq(fundBalanceAfter, fundBalanceBefore + uint256(-pnl) + uint256(closePositionFee));
        assertEq(
            accountBalanceAfter.available,
            accountBalanceBefore.available - uint256(-pnl) - uint256(closePositionFee) + order.margin
        );
        assertEq(accountBalanceAfter.locked, 0);
        assertEq(
            fundBalanceBefore + accountBalanceBefore.available + accountBalanceBefore.locked,
            fundBalanceAfter + accountBalanceAfter.available
        );

        // check position state
        assertEq(position.productId, order.productId);
        assertEq(position.margin, order.margin);
        assertEq(position.leverage, order.leverage);
        assertEq(position.size, order.size);
        assertEq(position.openPrice, order.price);
        assertEq(position.closePrice, order.liquidationPrice);
        assertEq(position.takeProfitPrice, order.takeProfitPrice);
        assertEq(position.liquidationPrice, order.liquidationPrice);
        assertEq(uint8(position.status), uint8(IBSX1000x.PositionStatus.Liquidated));
    }

    function test_forceClosePosition_revertsIfUnauthorizedCaller() public {
        address account;
        uint32 productId;
        uint256 nonce;
        int256 pnl;
        int256 fee;

        address malicious = makeAddr("malicious");
        bytes32 role = access.BSX1000_OPERATOR_ROLE();
        vm.prank(malicious);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, malicious, role)
        );
        bsx1000x.forceClosePosition(productId, account, nonce, pnl, fee, IBSX1000x.ClosePositionReason.Liquidation);
    }

    function test_forceClosePosition_revertsIfPositionNotExist() public {
        // open position
        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = makeAddr("account");
        order.nonce = 1;
        int256 pnl;

        // close position
        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.PositionNotOpening.selector, order.account, order.nonce));
        bsx1000x.forceClosePosition(
            order.productId, order.account, order.nonce, pnl, order.fee, IBSX1000x.ClosePositionReason.Liquidation
        );
    }

    function test_forceClosePosition_revertsIfProductIdMismatch() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        // open position
        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 10 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = -1 * 1e18;
        order.price = 10_000 * 1e18;
        order.takeProfitPrice = 9985 * 1e18;
        order.liquidationPrice = 10_009 * 1e18;
        order.fee = 1e16;
        int256 pnl;
        bytes memory openSignature = _signOpenOrder(signerKey, order);
        bsx1000x.openPosition(order, openSignature);

        // close position
        uint32 invalidProductId = 2;
        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.ProductIdMismatch.selector));
        bsx1000x.forceClosePosition(
            invalidProductId, order.account, order.nonce, pnl, order.fee, IBSX1000x.ClosePositionReason.Liquidation
        );
    }

    function test_forceClosePosition_revertsIfInvalidReason() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        // open position
        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 10 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = -1 * 1e18;
        order.price = 10_000 * 1e18;
        order.takeProfitPrice = 9985 * 1e18;
        order.liquidationPrice = 10_009 * 1e18;
        order.fee = 1e16;
        int256 pnl;
        bytes memory openSignature = _signOpenOrder(signerKey, order);
        bsx1000x.openPosition(order, openSignature);

        // close position
        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.InvalidClosePositionReason.selector));
        bsx1000x.forceClosePosition(
            order.productId, order.account, order.nonce, pnl, order.fee, IBSX1000x.ClosePositionReason.Normal
        );
    }

    function test_forceClosePosition_revertsIfInvalidPnl() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        // open position
        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 10 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = 1 * 1e18;
        order.price = 10_000 * 1e18;
        order.takeProfitPrice = 10_030 * 1e18;
        order.liquidationPrice = 9995 * 1e18;
        order.fee = 1e16;
        bytes memory openSignature = _signOpenOrder(signerKey, order);
        vm.expectEmit();
        emit IBSX1000x.OpenPosition(order.productId, order.account, order.nonce, order.fee);
        bsx1000x.openPosition(order, openSignature);

        // profit is negative
        int256 closePositionFee = 2e16;
        int256 pnl = -1 * 1e18;
        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.InvalidPnl.selector));
        bsx1000x.forceClosePosition(
            order.productId, order.account, order.nonce, pnl, closePositionFee, IBSX1000x.ClosePositionReason.TakeProfit
        );

        // profit exceed max allowed
        pnl = 31 * 1e18;
        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.InvalidPnl.selector));
        bsx1000x.forceClosePosition(
            order.productId, order.account, order.nonce, pnl, closePositionFee, IBSX1000x.ClosePositionReason.TakeProfit
        );

        // loss is positive
        pnl = 1 * 1e18;
        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.InvalidPnl.selector));
        bsx1000x.forceClosePosition(
            order.productId,
            order.account,
            order.nonce,
            pnl,
            closePositionFee,
            IBSX1000x.ClosePositionReason.Liquidation
        );

        // loss exceed max allowed
        pnl = -11 * 1e18;
        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.InvalidPnl.selector));
        bsx1000x.forceClosePosition(
            order.productId,
            order.account,
            order.nonce,
            pnl,
            closePositionFee,
            IBSX1000x.ClosePositionReason.Liquidation
        );
    }

    function test_forceClosePosition_revertsIfInvalidOrderFee() public {
        (address account, uint256 accountKey) = makeAddrAndKey("account");
        (, uint256 signerKey) = makeAddrAndKey("signer");
        _authorizeSigner(accountKey, signerKey);
        _depositFund();

        uint256 accountBalance = 100 * 1e18;
        _deposit(account, accountBalance);

        // open position
        BSX1000x.Order memory order;
        order.productId = 1;
        order.account = account;
        order.nonce = 5;
        order.margin = 10 * 1e18;
        order.leverage = 1000 * 1e18;
        order.size = 1 * 1e18;
        order.price = 10_000 * 1e18;
        order.takeProfitPrice = 10_005 * 1e18;
        order.liquidationPrice = 9995 * 1e18;
        order.fee = 1e16;
        bytes memory openSignature = _signOpenOrder(signerKey, order);
        vm.expectEmit();
        emit IBSX1000x.OpenPosition(order.productId, order.account, order.nonce, order.fee);
        bsx1000x.openPosition(order, openSignature);

        // fee is greater than margin
        int256 closePositionFee = 10 * 1e18 + 1;
        int256 pnl = 5 * 1e18;
        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.InvalidOrderFee.selector));
        bsx1000x.forceClosePosition(
            order.productId, order.account, order.nonce, pnl, closePositionFee, IBSX1000x.ClosePositionReason.TakeProfit
        );

        // fee + |loss| is greater than margin
        // margin = 10, loss = 5, fee = 6
        closePositionFee = 6 * 1e18;
        pnl = -5 * 1e18;
        vm.expectRevert(abi.encodeWithSelector(IBSX1000x.InvalidOrderFee.selector));
        bsx1000x.forceClosePosition(
            order.productId,
            order.account,
            order.nonce,
            pnl,
            closePositionFee,
            IBSX1000x.ClosePositionReason.Liquidation
        );
    }

    function _signTypedDataHash(uint256 privateKey, bytes32 structHash) private view returns (bytes memory signature) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            bsx1000x.eip712Domain();
        bytes32 domainSeparator = keccak256(
            abi.encode(TYPE_HASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract)
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function _authorizeSigner(uint256 accountKey, uint256 signerKey) private {
        address account = vm.addr(accountKey);
        address signer = vm.addr(signerKey);

        vm.mockCall(
            access.getExchange(),
            abi.encodeWithSelector(IExchange.isSigningWallet.selector, account, signer),
            abi.encode(true)
        );

        assertEq(bsx1000x.isAuthorizedSigner(account, signer), true);
    }

    function _deposit(address account, uint256 amount) private {
        vm.startPrank(account);

        uint8 tokenDecimals = collateralToken.decimals();
        uint256 rawAmount = amount.convertFrom18D(tokenDecimals);
        collateralToken.mint(account, rawAmount);
        collateralToken.approve(address(bsx1000x), rawAmount);

        bsx1000x.deposit(amount);

        vm.stopPrank();
    }

    function _depositFund() private {
        uint256 amount = 1_000_000_000 * 1e18;
        uint8 tokenDecimals = collateralToken.decimals();
        uint256 rawAmount = amount.convertFrom18D(tokenDecimals);
        collateralToken.mint(address(this), rawAmount);
        collateralToken.approve(address(bsx1000x), rawAmount);

        bsx1000x.depositFund(amount);
    }

    function _signOpenOrder(uint256 signerKey, IBSX1000x.Order memory order) private view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                bsx1000x.OPEN_POSITION_TYPEHASH(),
                order.productId,
                order.account,
                order.nonce,
                order.margin,
                order.leverage
            )
        );
        return _signTypedDataHash(signerKey, structHash);
    }

    function _signCloseOrder(uint256 signerKey, IBSX1000x.Order memory order) private view returns (bytes memory) {
        bytes32 structHash =
            keccak256(abi.encode(bsx1000x.CLOSE_POSITION_TYPEHASH(), order.productId, order.account, order.nonce));
        return _signTypedDataHash(signerKey, structHash);
    }

    function _maxZeroScaledAmount() private view returns (uint256) {
        return uint256(1).convertTo18D(collateralToken.decimals()) - 1;
    }
}

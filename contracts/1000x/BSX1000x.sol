// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {Access} from "../exchange/access/Access.sol";
import {IExchange} from "../exchange/interfaces/IExchange.sol";
import {IERC20Extend} from "../exchange/interfaces/external/IERC20Extend.sol";
import {IERC3009Minimal} from "../exchange/interfaces/external/IERC3009Minimal.sol";
import {Errors} from "../exchange/lib/Errors.sol";
import {MathHelper} from "../exchange/lib/MathHelper.sol";
import {IBSX1000x} from "./interfaces/IBSX1000x.sol";

/// @title BSX1000x contract
/// @notice Manage the token balance states
/// @dev This contract is upgradeable.
contract BSX1000x is IBSX1000x, Initializable, EIP712Upgradeable {
    using SafeERC20 for IERC20Extend;
    using MathHelper for int128;
    using MathHelper for int256;
    using MathHelper for uint128;
    using MathHelper for uint256;

    bytes32 public constant OPEN_POSITION_TYPEHASH =
        keccak256("OpenPosition(uint32 productId,address account,uint256 nonce,uint128 margin,uint128 leverage)");
    bytes32 public constant CLOSE_POSITION_TYPEHASH =
        keccak256("ClosePosition(uint32 productId,address account,uint256 nonce)");

    bytes32 public constant WITHDRAW_TYPEHASH = keccak256("Withdraw(address account,uint256 amount,uint256 nonce)");

    uint128 public constant MAX_LEVERAGE = 1000 * 10 ** 18;
    int256 public constant MAX_PROFIT_FACTOR = 3;
    int256 public constant MAX_LOSS_FACTOR = -1;
    uint256 public constant MAX_WITHDRAWAL_FEE = 10 ** 18; // $1
    int128 internal constant MARGIN_ERR = 1e16;

    /// @inheritdoc IBSX1000x
    Access public access;

    /// @inheritdoc IBSX1000x
    IERC20Extend public collateralToken;

    /// @inheritdoc IBSX1000x
    uint256 public fundBalance;

    /// @inheritdoc IBSX1000x
    mapping(address account => mapping(uint256 nonce => bool)) public isWithdrawNonceUsed;

    mapping(address account => Balance) private _balance;

    mapping(address account => mapping(uint256 nonce => Position)) private _position;

    mapping(address account => mapping(uint256 nonce => uint256)) private _credit;

    function _checkRole(bytes32 role, address account) internal view {
        if (!access.hasRole(role, account)) {
            revert IAccessControl.AccessControlUnauthorizedAccount(account, role);
        }
    }

    modifier onlyRole(bytes32 role) {
        _checkRole(role, msg.sender);
        _;
    }

    function initialize(
        string memory name,
        string memory version,
        address _access,
        address _collateralToken
    ) external initializer {
        __EIP712_init(name, version);
        if (_access == address(0) || _collateralToken == address(0)) {
            revert Errors.ZeroAddress();
        }
        access = Access(_access);
        collateralToken = IERC20Extend(_collateralToken);
    }

    /// @inheritdoc IBSX1000x
    function deposit(uint256 amount) public {
        deposit(msg.sender, amount);
    }

    /// @inheritdoc IBSX1000x
    function deposit(address account, uint256 amount) public {
        (uint256 roundDownAmount, uint256 rawAmount) = amount.roundDownAndConvertFromScale(address(collateralToken));
        if (roundDownAmount == 0 || rawAmount == 0) revert ZeroAmount();

        collateralToken.safeTransferFrom(msg.sender, address(this), rawAmount);

        uint256 newBalance = _balance[account].available + roundDownAmount;
        _balance[account].available = newBalance;

        emit Deposit(account, roundDownAmount, newBalance);
    }

    /// @inheritdoc IBSX1000x
    function depositRaw(address account, address token, uint256 rawAmount) public {
        if (token != address(collateralToken)) {
            revert Errors.Exchange_NotCollateralToken();
        }
        if (rawAmount == 0) revert ZeroAmount();

        collateralToken.safeTransferFrom(msg.sender, address(this), rawAmount);

        uint256 amount = uint256(rawAmount).convertToScale(token);
        uint256 newBalance = _balance[account].available + amount;
        _balance[account].available = newBalance;

        emit Deposit(account, amount, newBalance);
    }

    /// @inheritdoc IBSX1000x
    function depositWithAuthorization(
        address account,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        (uint256 roundDownAmount, uint256 rawAmount) = amount.roundDownAndConvertFromScale(address(collateralToken));
        if (roundDownAmount == 0 || rawAmount == 0) revert ZeroAmount();

        IERC3009Minimal(address(collateralToken)).receiveWithAuthorization(
            account, address(this), rawAmount, validAfter, validBefore, nonce, signature
        );

        uint256 newBalance = _balance[account].available + roundDownAmount;
        _balance[account].available = newBalance;

        emit Deposit(account, roundDownAmount, newBalance);
    }

    /// @inheritdoc IBSX1000x
    function withdraw(
        address account,
        uint256 amount,
        uint256 fee,
        uint256 nonce,
        bytes memory signature
    ) public onlyRole(access.GENERAL_ROLE()) {
        uint256 netAmount = amount - fee;
        uint256 amountToTransfer = netAmount.convertFromScale(address(collateralToken));
        if (amount == 0 || amountToTransfer == 0) revert ZeroAmount();

        bytes32 withdrawHash = _hashTypedDataV4(keccak256(abi.encode(WITHDRAW_TYPEHASH, account, amount, nonce)));
        if (!SignatureChecker.isValidSignatureNow(account, withdrawHash, signature)) {
            revert InvalidSignature(account);
        }

        if (isWithdrawNonceUsed[account][nonce]) {
            revert Withdraw_UsedNonce(account, nonce);
        }
        isWithdrawNonceUsed[account][nonce] = true;

        if (fee > MAX_WITHDRAWAL_FEE) {
            revert ExceededMaxWithdrawalFee();
        }

        uint256 accountBalance = _balance[account].available;
        if (accountBalance < amount) {
            revert InsufficientAccountBalance();
        }

        uint256 newBalance = accountBalance - amount;
        _balance[account].available = newBalance;
        fundBalance = fundBalance + fee;

        collateralToken.safeTransfer(account, amountToTransfer);

        emit WithdrawSucceeded(account, nonce, amount, fee, newBalance);
    }

    /// @inheritdoc IBSX1000x
    function openPosition(Order calldata order, bytes memory signature) external {
        openPosition(order, 0, signature);
    }

    /// @inheritdoc IBSX1000x
    function openPosition(
        Order calldata order,
        uint256 credit,
        bytes memory signature
    ) public onlyRole(access.BSX1000_OPERATOR_ROLE()) {
        bytes32 orderHash = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    OPEN_POSITION_TYPEHASH, order.productId, order.account, order.nonce, order.margin, order.leverage
                )
            )
        );
        _validateAuthorization(order.account, orderHash, signature);

        // validate order
        Position storage position = _position[order.account][order.nonce];
        if (position.status != PositionStatus.NotExist) {
            revert PositionExisted(order.account, order.nonce);
        }
        if (order.leverage > MAX_LEVERAGE) {
            revert ExceededMaxLeverage();
        }
        if (order.price.mul18D(uint128(order.size.abs())) > order.leverage.mul18D(order.margin) + uint128(MARGIN_ERR)) {
            revert ExceededNotionalAmount();
        }
        int128 targetProfit = order.size.mul18D(order.takeProfitPrice.safeInt128() - order.price.safeInt128());
        if (targetProfit < 0 || targetProfit > order.margin.safeInt128() * MAX_PROFIT_FACTOR + MARGIN_ERR) {
            revert InvalidTakeProfitPrice();
        }
        int128 liquidationLoss = order.size.mul18D(order.liquidationPrice.safeInt128() - order.price.safeInt128());
        if (liquidationLoss > 0 || liquidationLoss < order.margin.safeInt128() * MAX_LOSS_FACTOR - MARGIN_ERR) {
            revert InvalidLiquidationPrice();
        }
        if (order.fee >= order.margin.safeInt128()) {
            revert InvalidOrderFee();
        }

        // update balance
        _lockMargin(order.account, order.nonce, order.margin, credit);

        Balance storage accountBalance = _balance[order.account];
        int256 newBalance = (accountBalance.available.safeInt256() - order.fee);
        if (newBalance < 0) {
            revert InsufficientAccountBalance();
        }
        accountBalance.available = newBalance.safeUInt256();

        fundBalance = (fundBalance.safeInt256() + order.fee).safeUInt256();

        // update position
        position.status = PositionStatus.Open;
        position.productId = order.productId;
        position.margin = order.margin;
        position.leverage = order.leverage;
        position.size = order.size;
        position.openPrice = order.price;
        position.takeProfitPrice = order.takeProfitPrice;
        position.liquidationPrice = order.liquidationPrice;

        emit OpenPosition(order.productId, order.account, order.nonce, order.fee);
    }

    /// @inheritdoc IBSX1000x
    function closePosition(
        uint32 productId,
        address account,
        uint256 nonce,
        uint128 closePrice,
        int256 pnl,
        int256 fee,
        bytes memory signature
    ) external onlyRole(access.BSX1000_OPERATOR_ROLE()) {
        bytes32 closeOrderHash =
            _hashTypedDataV4(keccak256(abi.encode(CLOSE_POSITION_TYPEHASH, productId, account, nonce)));
        _validateAuthorization(account, closeOrderHash, signature);

        // update position
        Position storage position = _position[account][nonce];
        if (position.status != PositionStatus.Open) {
            revert PositionNotOpening(account, nonce);
        }
        if (position.productId != productId) {
            revert ProductIdMismatch();
        }
        bool isLong = position.size > 0;
        if (isLong && (closePrice < position.liquidationPrice || closePrice > position.takeProfitPrice)) {
            revert InvalidClosePrice();
        }
        if (!isLong && (closePrice > position.liquidationPrice || closePrice < position.takeProfitPrice)) {
            revert InvalidClosePrice();
        }
        position.status = PositionStatus.Closed;
        position.closePrice = closePrice;

        int256 expectedPnl = position.size.mul18D(closePrice.safeInt128() - position.openPrice.safeInt128());
        if (pnl > expectedPnl + MARGIN_ERR || pnl < expectedPnl - MARGIN_ERR) {
            revert InvalidPnl();
        }

        if (fee > position.margin.safeInt128() || fee > position.margin.safeInt128() + pnl) {
            revert InvalidOrderFee();
        }

        // update balance
        _unlockMargin(account, nonce, position.margin);
        _updateBalanceAfterClosingPosition(account, pnl, fee);

        emit ClosePosition(productId, account, nonce, pnl, fee, ClosePositionReason.Normal);
    }

    /// @inheritdoc IBSX1000x
    function forceClosePosition(
        uint32 productId,
        address account,
        uint256 nonce,
        int256 pnl,
        int256 fee,
        ClosePositionReason reason
    ) external onlyRole(access.BSX1000_OPERATOR_ROLE()) {
        // update position
        Position storage position = _position[account][nonce];
        if (position.status != PositionStatus.Open) {
            revert PositionNotOpening(account, nonce);
        }
        if (position.productId != productId) {
            revert ProductIdMismatch();
        }

        if (reason == ClosePositionReason.Liquidation) {
            position.status = PositionStatus.Liquidated;
            position.closePrice = position.liquidationPrice;
        } else if (reason == ClosePositionReason.TakeProfit) {
            position.status = PositionStatus.TakeProfit;
            position.closePrice = position.takeProfitPrice;
        } else {
            revert InvalidClosePositionReason();
        }

        int256 expectedPnl = position.size.mul18D(position.closePrice.safeInt128() - position.openPrice.safeInt128());
        if (pnl > expectedPnl + MARGIN_ERR || pnl < expectedPnl - MARGIN_ERR) {
            revert InvalidPnl();
        }

        if (fee > position.margin.safeInt128() || fee > position.margin.safeInt128() + pnl) {
            revert InvalidOrderFee();
        }

        // update balance
        _unlockMargin(account, nonce, position.margin);
        _updateBalanceAfterClosingPosition(account, pnl, fee);

        emit ClosePosition(productId, account, nonce, pnl, fee, reason);
    }

    /// @inheritdoc IBSX1000x
    function depositFund(uint256 amount) external {
        (uint256 roundDownAmount, uint256 rawAmount) = amount.roundDownAndConvertFromScale(address(collateralToken));
        if (roundDownAmount == 0 || rawAmount == 0) revert ZeroAmount();
        collateralToken.safeTransferFrom(msg.sender, address(this), rawAmount);

        uint256 newFundBalance = fundBalance + roundDownAmount;
        fundBalance = newFundBalance;

        emit DepositFund(roundDownAmount, newFundBalance);
    }

    /// @inheritdoc IBSX1000x
    function withdrawFund(uint256 amount) external onlyRole(access.GENERAL_ROLE()) {
        if (amount > fundBalance) {
            revert InsufficientFundBalance();
        }

        uint256 amountToTransfer = amount.convertFromScale(address(collateralToken));
        if (amount == 0 || amountToTransfer == 0) revert ZeroAmount();
        collateralToken.safeTransfer(msg.sender, amountToTransfer);

        uint256 newFundBalance = fundBalance - amount;
        fundBalance = newFundBalance;

        emit WithdrawFund(amount, newFundBalance);
    }

    /// @inheritdoc IBSX1000x
    function isAuthorizedSigner(address account, address signer) public view returns (bool) {
        return IExchange(access.getExchange()).isSigningWallet(account, signer);
    }

    /// @inheritdoc IBSX1000x
    function getBalance(address account) external view returns (Balance memory) {
        return _balance[account];
    }

    /// @inheritdoc IBSX1000x
    function getPosition(address account, uint256 nonce) external view returns (Position memory) {
        return _position[account][nonce];
    }

    function _lockMargin(address account, uint256 nonce, uint256 margin, uint256 credit) internal {
        uint256 accountBalance = _balance[account].available;
        uint256 lockAmount = margin - credit;
        if (credit > lockAmount || credit > fundBalance) {
            revert InvalidCredit();
        }
        if (accountBalance < lockAmount) {
            revert InsufficientAccountBalance();
        }
        _balance[account].available = accountBalance - lockAmount;
        _balance[account].locked += lockAmount;
        _credit[account][nonce] = credit;
        fundBalance -= credit;
    }

    function _unlockMargin(address account, uint256 nonce, uint256 margin) internal {
        uint256 credit = _credit[account][nonce];
        uint256 lockedMargin = margin - credit;
        _balance[account].locked -= lockedMargin;
        _balance[account].available += margin;

        delete _credit[account][nonce];
    }

    function _updateBalanceAfterClosingPosition(address account, int256 pnl, int256 fee) internal {
        Balance storage accountBalance = _balance[account];
        int256 updatedAccountBalance = accountBalance.available.safeInt256() + pnl - fee;
        accountBalance.available = updatedAccountBalance > 0 ? updatedAccountBalance.safeUInt256() : 0;

        int256 newFundBalance = fundBalance.safeInt256() - pnl + fee;
        if (newFundBalance < 0) {
            revert InsufficientFundBalance();
        }
        fundBalance = newFundBalance.safeUInt256();
    }

    function _validateAuthorization(address account, bytes32 digest, bytes memory signature) internal view {
        address signer = ECDSA.recover(digest, signature);
        if (!isAuthorizedSigner(account, signer)) {
            revert UnauthorizedSigner(account, signer);
        }
    }
}

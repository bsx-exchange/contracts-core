// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/IClearingService.sol";
import "./interfaces/IOrderBook.sol";
import "./lib/LibOrder.sol";
import "./lib/MathHelper.sol";
import "./share/Constants.sol";
import "./interfaces/ISpot.sol";
import "./interfaces/IPerp.sol";
import "./access/Access.sol";
import "./interfaces/IFee.sol";
import "./share/RevertReason.sol";

/**
 * @title OrderBook contract
 * @author BSX
 * @notice This contract is only used for matching orders.
 */
contract OrderBook is Initializable, OwnableUpgradeable, IOrderBook {
    using MathHelper for int128;

    IClearingService public clearingService;
    ISpot public spotEngine;
    IPerp public perpEngine;
    Access public access;
    //manage the fullfiled amount of an order
    mapping(bytes32 => uint128) public filled;
    mapping(address => mapping(uint64 => bool)) public isNonceUsed;

    FeeCollection public feeCollection;
    mapping(uint8 => int256) public sequencerFee; //deprecated
    address public collateralToken;
    int256 totalSequencerFee;

    function initialize(
        address _clearingService,
        address _spotEngine,
        address _perpEngine,
        address _access,
        address _collateralToken
    ) public initializer {
        __Ownable_init(msg.sender);
        if (
            _clearingService == address(0) ||
            _spotEngine == address(0) ||
            _perpEngine == address(0) ||
            _access == address(0) ||
            _collateralToken == address(0)
        ) {
            revert(INVALID_ADDRESS);
        }
        clearingService = IClearingService(_clearingService);
        spotEngine = ISpot(_spotEngine);
        perpEngine = IPerp(_perpEngine);
        access = Access(_access);
        collateralToken = _collateralToken;
    }

    struct BalanceInfo {
        IPerp.Balance makerBalance;
        IPerp.Balance takerBalance;
    }

    function _onlySequencer() internal view {
        if (msg.sender != access.getExchange()) {
            revert(NOT_SEQUENCER);
        }
    }

    modifier onlySequencer() {
        _onlySequencer();
        _;
    }

    // function _onlyGeneralAdmin() internal view {
    //     if (!access.hasRole(access.ADMIN_GENERAL_ROLE(), msg.sender)) {
    //         revert(NOT_ADMIN_GENERAL);
    //     }
    // }

    // modifier onlyGeneralAdmin() {
    //     _onlyGeneralAdmin();
    //     _;
    // }

    /// @inheritdoc IOrderBook
    function matchOrders(
        LibOrder.SignedOrder memory maker,
        LibOrder.SignedOrder memory taker,
        OrderHash memory digest,
        uint8 productIndex,
        uint128 takerSequencerFee,
        Fee memory matchFee
    ) external onlySequencer {
        if (maker.isLiquidation && taker.isLiquidation) {
            revert(REQUIRE_ONE_LIQUIDATION_ORDER);
        }
        if (maker.order.orderSide == taker.order.orderSide) {
            revert(INVALID_MATCH_SIDE);
        }
        if (maker.order.sender == taker.order.sender) {
            revert(DUPLICATE_ADDRESS);
        }
        if (
            0 > takerSequencerFee || takerSequencerFee > MAX_TAKER_SEQUENCER_FEE
        ) {
            revert(INVALID_SEQUENCER_FEES);
        }

        uint128 fillAmount = MathHelper.min(
            maker.order.size - filled[digest.maker],
            taker.order.size - filled[digest.taker]
        );
        _verifyUsedNonce(maker.order.sender, maker.order.nonce);
        _verifyUsedNonce(taker.order.sender, taker.order.nonce);

        Delta memory takerDelta;
        Delta memory makerDelta;
        uint128 price;

        if (taker.order.orderSide == OrderSide.SELL) {
            price = MathHelper.max(maker.order.price, taker.order.price);
            takerDelta.productAmount = -int128(fillAmount);
            makerDelta.productAmount = int128(fillAmount);
            takerDelta.quoteAmount = int128(price).mul18D(int128(fillAmount));
            makerDelta.quoteAmount = -takerDelta.quoteAmount;
        } else {
            price = maker.order.price;
            takerDelta.productAmount = int128(fillAmount);
            makerDelta.productAmount = -int128(fillAmount);
            makerDelta.quoteAmount = int128(price).mul18D(int128(fillAmount));
            takerDelta.quoteAmount = -makerDelta.quoteAmount;
        }
        if (
            matchFee.maker >
            MathHelper.abs(makerDelta.quoteAmount.mul18D(MAX_MATCH_FEES)) ||
            matchFee.taker >
            MathHelper.abs(takerDelta.quoteAmount.mul18D(MAX_MATCH_FEES))
        ) {
            revert(INVALID_FEES);
        }
        makerDelta.quoteAmount = makerDelta.quoteAmount - matchFee.maker;
        takerDelta.quoteAmount = takerDelta.quoteAmount - matchFee.taker;
        updateFeeCollection(matchFee.maker);
        updateFeeCollection(matchFee.taker);

        //sequencer fee application
        if (filled[digest.taker] == 0) {
            totalSequencerFee += int128(takerSequencerFee);
            takerDelta.quoteAmount -= int128(takerSequencerFee);
        }

        filled[digest.maker] += fillAmount;
        filled[digest.taker] += fillAmount;
        if (maker.order.size == filled[digest.maker]) {
            isNonceUsed[maker.order.sender][maker.order.nonce] = true;
        }
        if (taker.order.size == filled[digest.taker]) {
            isNonceUsed[taker.order.sender][taker.order.nonce] = true;
        }
        (makerDelta.quoteAmount, makerDelta.productAmount) = settleBalance(
            productIndex,
            maker.order.sender,
            makerDelta.productAmount,
            makerDelta.quoteAmount,
            price
        );

        //handle taker position settle
        (takerDelta.quoteAmount, takerDelta.productAmount) = settleBalance(
            productIndex,
            taker.order.sender,
            takerDelta.productAmount,
            takerDelta.quoteAmount,
            price
        );

        {
            IPerp.AccountDelta[]
                memory productDeltas = new IPerp.AccountDelta[](2);

            productDeltas[0] = createAccountDelta(
                productIndex,
                maker.order.sender,
                makerDelta.productAmount,
                makerDelta.quoteAmount
            );
            productDeltas[1] = createAccountDelta(
                productIndex,
                taker.order.sender,
                takerDelta.productAmount,
                takerDelta.quoteAmount
            );

            _modifyAccounts(productDeltas);
        }
        bool isLiquidation = taker.isLiquidation;
        emit OrderMatched(
            productIndex,
            maker.order.sender,
            taker.order.sender,
            maker.order.orderSide,
            maker.order.nonce,
            taker.order.nonce,
            fillAmount,
            price,
            matchFee,
            isLiquidation
        );
    }

    /**
     * @dev This internal function is used to call modify account function depends on the quote address.
     * If the quote address is QUOTE_ADDRESS, it will call perpEngine.modifyAccount.
     * Otherwise, it will call spotEngine.modifyAccount.
     * @param _accountDeltas The information of the account to modify
     */
    function _modifyAccounts(
        IPerp.AccountDelta[] memory _accountDeltas
    ) internal {
        perpEngine.modifyAccount(_accountDeltas);
    }

    function updateFeeCollection(int128 _feeAmount) internal {
        feeCollection.perpFeeCollection += _feeAmount;
    }

    /**
     * @dev This function is used to claim fee.
     * @notice This function can only be called by the exchange contract.
     *
     */
    function claimTradingFees() external onlySequencer returns (int256) {
        int256 totalFees = feeCollection.perpFeeCollection;
        feeCollection.perpFeeCollection = 0;
        return totalFees;
    }

    /**
     * @dev This helper function is used to create an account delta.
     * @param productIndex Product id
     * @param account Account address
     * @param amount Amount of product token
     * @param quoteAmount Amount of quote
     * @return Account delta
     */
    function createAccountDelta(
        uint8 productIndex,
        address account,
        int128 amount,
        int128 quoteAmount
    ) internal pure returns (IPerp.AccountDelta memory) {
        return
            IPerp.AccountDelta({
                productIndex: productIndex,
                account: account,
                amount: amount,
                quoteAmount: quoteAmount
            });
    }

    function _verifyUsedNonce(address user, uint64 nonce) internal view {
        if (isNonceUsed[user][nonce]) {
            revert(NONCE_USED);
        }
    }

    function isMatched(
        address _userA,
        uint64 _nonceA,
        address _userB,
        uint64 _nonceB
    ) external view returns (bool) {
        return isNonceUsed[_userA][_nonceA] || isNonceUsed[_userB][_nonceB];
    }

    function settleBalance(
        uint8 _productIndex,
        address _account,
        int128 _matchSize,
        int128 _quote,
        uint128 _price
    ) internal returns (int128, int128) {
        ISpot.AccountDelta[] memory accountDeltas = new ISpot.AccountDelta[](1);
        IPerp.Balance memory balance = perpEngine.getBalance(
            _account,
            _productIndex
        );
        IPerp.FundingRate memory fundingRate = perpEngine.getFundingRate(
            _productIndex
        );

        //pay funding first
        int128 funding = (fundingRate.cumulativeFunding18D -
            balance.lastFunding).mul18D(balance.size);
        int128 newQuote = _quote + balance.quoteBalance - funding;
        int128 newSize = balance.size + _matchSize;
        int128 amountToSettle;
        if (balance.size.mul18D(newSize) < 0) {
            amountToSettle = newQuote + newSize.mul18D(int128(_price));
        } else {
            if (newSize == 0) {
                amountToSettle = newQuote;
            }
        }
        accountDeltas[0] = ISpot.AccountDelta(
            collateralToken,
            _account,
            amountToSettle
        );
        spotEngine.modifyAccount(accountDeltas);
        newQuote = newQuote - amountToSettle;
        return (newQuote, newSize);
    }

    function claimSequencerFees() external onlySequencer returns (int256) {
        int totalFees = totalSequencerFee;
        totalSequencerFee = 0;
        return totalFees;
    }

    function getCollateralToken() external view returns (address) {
        return collateralToken;
    }

    function getTradingFees() external view returns (int128) {
        return feeCollection.perpFeeCollection;
    }

    function getSequencerFees() external view returns (int256) {
        return totalSequencerFee;
    }
}

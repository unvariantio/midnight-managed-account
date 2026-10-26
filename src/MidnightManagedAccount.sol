// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IBuyCallback, IRepayCallback} from "midnight/src/interfaces/ICallbacks.sol";
import {IMidnight, Market, Offer} from "midnight/src/interfaces/IMidnight.sol";
import {CALLBACK_SUCCESS, WAD} from "midnight/src/libraries/ConstantsLib.sol";
import {IdLib} from "midnight/src/libraries/IdLib.sol";
import {SafeTransferLib} from "midnight/src/libraries/SafeTransferLib.sol";
import {UtilsLib} from "midnight/src/libraries/UtilsLib.sol";
import {LimitKeys} from "./LimitKeys.sol";
import {MidnightManagedAccountLimits} from "./MidnightManagedAccountLimits.sol";

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice A Midnight account whose operators manage the owner's position within owner-configured limits.
/// @dev The account holds no funds. Paying operations pull the exact amount from the treasury just in time, so the
/// treasury's ERC20 allowance doubles as a kill switch. Payment callbacks are bound to the in-flight operation.
contract MidnightManagedAccount is MidnightManagedAccountLimits, IBuyCallback, IRepayCallback {
    using UtilsLib for uint256;

    enum PaymentKind {
        None,
        Buy,
        Repay
    }

    error InvalidTreasury();
    error AccountPaused();
    error NotOperator();
    error InvalidOfferSide();
    error MarketMatured();
    error MarketNotEnabled();
    error DebtLimitExceeded();
    error InsufficientAssetsOut();
    error ExcessiveAssetsIn();
    error BorrowRateAboveLimit();
    error LendRateBelowLimit();
    error ApproveFailed();
    error ReentrantCall();
    error OnlyMidnight();
    error UnexpectedCallback();
    error PaymentNotConsumed();

    event SetTreasury(address indexed treasury);
    event Borrow(
        address indexed operator, bytes32 indexed marketId, address indexed receiver, uint256 units,
        uint256 sellerAssets, uint256 debtAfter
    );
    event Lend(
        address indexed operator, bytes32 indexed marketId, uint256 units, uint256 buyerAssets, uint256 pendingFee
    );
    event Withdraw(address indexed operator, bytes32 indexed marketId, address indexed receiver, uint256 units);
    event Repay(address indexed operator, bytes32 indexed marketId, uint256 units);
    event SupplyCollateral(address indexed operator, bytes32 indexed marketId, uint256 collateralIndex, uint256 assets);
    event WithdrawCollateral(
        address indexed operator, bytes32 indexed marketId, address indexed receiver, uint256 collateralIndex,
        uint256 assets
    );
    event Sweep(address indexed token, address indexed receiver, uint256 amount);

    address public immutable MIDNIGHT;

    address public treasury;

    bool transient entered;

    PaymentKind transient expectedPayment;
    bytes32 transient expectedMarketId;
    uint256 transient expectedMaxAssets;
    uint256 transient expectedUnits;

    uint256 transient lendPendingFee;

    modifier operate() {
        _startOperation(false);
        _;
        entered = false;
    }

    /// @dev Stays available while paused so that a freeze cannot leave the position undefended.
    modifier operateRiskReducing() {
        _startOperation(true);
        _;
        entered = false;
    }

    function _startOperation(bool allowedWhilePaused) private {
        require(!entered, ReentrantCall());
        entered = true;
        require(allowedWhilePaused || !paused, AccountPaused());
        require(isOperator[msg.sender], NotOperator());
    }

    constructor(address owner, address midnight) MidnightManagedAccountLimits(owner) {
        MIDNIGHT = midnight;
        treasury = owner;
        emit SetTreasury(owner);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), InvalidTreasury());
        treasury = newTreasury;
        emit SetTreasury(newTreasury);
    }

    function borrow(Offer memory offer, bytes memory ratifierData, uint256 units, address receiver,
        uint256 minAssetsOut
    ) external operate returns (uint256 buyerAssets, uint256 sellerAssets) {
        require(offer.buy, InvalidOfferSide());
        require(offer.market.maturity > block.timestamp, MarketMatured());

        bytes32 marketId = IdLib.toId(offer.market);
        MarketConfig memory config = marketConfig[marketId];
        require(config.enabled, MarketNotEnabled());

        _consumeLimit(LimitKeys.borrowUnits(marketId), units);
        _consumeLimit(LimitKeys.borrowUnits(marketId, msg.sender), units);
        _consumeLimit(LimitKeys.tokenBorrowUnits(offer.market.loanToken), units);

        (buyerAssets, sellerAssets) = IMidnight(MIDNIGHT).take(offer, ratifierData, units, OWNER, receiver, address(0), bytes(""));

        require(sellerAssets > 0 && sellerAssets >= minAssetsOut, InsufficientAssetsOut());

        // Rate ceiling: units <= assets * (1 + maxBorrowRate * timeToMaturity).
        uint256 interestFactor = uint256(config.maxBorrowRate) * (offer.market.maturity - block.timestamp);
        require(units <= sellerAssets + sellerAssets.mulDivDown(interestFactor, WAD), BorrowRateAboveLimit());

        // Taking nets against existing credit, so check the resulting debt instead of an exact delta.
        uint256 debtAfter = IMidnight(MIDNIGHT).debt(marketId, OWNER);
        require(debtAfter <= config.maxDebt, DebtLimitExceeded());

        _consumeLimit(LimitKeys.borrowAssetsOut(marketId, receiver), sellerAssets);

        emit Borrow(msg.sender, marketId, receiver, units, sellerAssets, debtAfter);
    }

    function lend(Offer memory offer, bytes memory ratifierData, uint256 units, uint256 maxAssetsIn)
        external
        operate
        returns (uint256 buyerAssets, uint256 sellerAssets)
    {
        require(!offer.buy, InvalidOfferSide());
        require(offer.market.maturity > block.timestamp, MarketMatured());

        bytes32 marketId = IdLib.toId(offer.market);
        MarketConfig memory config = marketConfig[marketId];
        require(config.enabled, MarketNotEnabled());

        _expectPayment(PaymentKind.Buy, marketId, maxAssetsIn, units);

        (buyerAssets, sellerAssets) = IMidnight(MIDNIGHT).take(offer, ratifierData, units, OWNER, address(0), address(this), bytes(""));

        _assertConsumed();

        uint256 pendingFee = lendPendingFee;
        lendPendingFee = 0;

        // Rate floor on net proceeds: units - pendingFee >= assets * (1 + minLendRate * timeToMaturity).
        uint256 interestFactor = uint256(config.minLendRate) * (offer.market.maturity - block.timestamp);
        require(units >= pendingFee + buyerAssets + buyerAssets.mulDivUp(interestFactor, WAD), LendRateBelowLimit());

        _consumeLimit(LimitKeys.lendAssets(marketId), buyerAssets);
        _consumeLimit(LimitKeys.lendAssets(marketId, msg.sender), buyerAssets);
        _consumeLimit(LimitKeys.tokenLendAssets(offer.market.loanToken), buyerAssets);

        emit Lend(msg.sender, marketId, units, buyerAssets, pendingFee);
    }

    function withdraw(Market memory market, uint256 units, address receiver) external operate {
        bytes32 marketId = IdLib.toId(market);

        _consumeLimit(LimitKeys.withdrawAssets(marketId, receiver), units);
        IMidnight(MIDNIGHT).withdraw(market, units, OWNER, receiver);

        emit Withdraw(msg.sender, marketId, receiver, units);
    }

    function repay(Market memory market, uint256 units) external operateRiskReducing {
        bytes32 marketId = IdLib.toId(market);

        _consumeLimit(LimitKeys.repayAssets(marketId), units);

        _expectPayment(PaymentKind.Repay, marketId, units, units);

        IMidnight(MIDNIGHT).repay(market, units, OWNER, address(this), bytes(""));

        _assertConsumed();

        emit Repay(msg.sender, marketId, units);
    }

    /// @dev Midnight's supplyCollateral has no callback, so the treasury pull happens before the call.
    function supplyCollateral(Market memory market, uint256 collateralIndex, uint256 assets)
        external
        operateRiskReducing
    {
        bytes32 marketId = IdLib.toId(market);
        address token = market.collateralParams[collateralIndex].token;

        _consumeLimit(LimitKeys.collateralAssetsIn(marketId, token), assets);

        _fundMidnight(token, assets);
        IMidnight(MIDNIGHT).supplyCollateral(market, collateralIndex, assets, OWNER);

        emit SupplyCollateral(msg.sender, marketId, collateralIndex, assets);
    }

    function withdrawCollateral(Market memory market, uint256 collateralIndex, uint256 assets, address receiver)
        external
        operate
    {
        bytes32 marketId = IdLib.toId(market);
        address token = market.collateralParams[collateralIndex].token;

        _consumeLimit(LimitKeys.collateralAssetsOut(marketId, token, receiver), assets);
        IMidnight(MIDNIGHT).withdrawCollateral(market, collateralIndex, assets, OWNER, receiver);

        emit WithdrawCollateral(msg.sender, marketId, receiver, collateralIndex, assets);
    }

    function onBuy(bytes32 id, Market memory market, uint256 buyerAssets, uint256 units, uint256 pendingFeeIncrease,
        address buyer, bytes memory
    ) external returns (bytes32) {
        _consumeExpectation(PaymentKind.Buy, id, buyer, buyerAssets, units);
        lendPendingFee = pendingFeeIncrease;

        _fundMidnight(market.loanToken, buyerAssets);
        return CALLBACK_SUCCESS;
    }

    function onRepay(bytes32 id, Market memory market, uint256 units, address onBehalf, bytes memory)
        external
        returns (bytes32)
    {
        _consumeExpectation(PaymentKind.Repay, id, onBehalf, units, units);

        _fundMidnight(market.loanToken, units);
        return CALLBACK_SUCCESS;
    }

    function sweep(address token, address receiver, uint256 amount) external onlyOwner {
        SafeTransferLib.safeTransfer(token, receiver, amount);
        emit Sweep(token, receiver, amount);
    }

    function _expectPayment(PaymentKind kind, bytes32 marketId, uint256 maxAssets, uint256 units) internal {
        expectedPayment = kind;
        expectedMarketId = marketId;
        expectedMaxAssets = maxAssets;
        expectedUnits = units;
    }

    /// @dev A foreign offer whose callback points at this account fails these checks or the single-use consumption.
    function _consumeExpectation(PaymentKind kind, bytes32 id, address account, uint256 assets, uint256 units)
        internal
    {
        require(msg.sender == MIDNIGHT, OnlyMidnight());
        require(
            expectedPayment == kind && id == expectedMarketId && account == OWNER && units == expectedUnits,
            UnexpectedCallback()
        );
        require(assets <= expectedMaxAssets, ExcessiveAssetsIn());
        _expectPayment(PaymentKind.None, bytes32(0), 0, 0);
    }

    function _assertConsumed() internal view {
        require(expectedPayment == PaymentKind.None, PaymentNotConsumed());
    }

    /// @dev Midnight pulls the whole approval within the same call, leaving no residual allowance.
    function _fundMidnight(address token, uint256 amount) internal {
        SafeTransferLib.safeTransferFrom(token, treasury, address(this), amount);
        (bool success, bytes memory returndata) =
            token.call(abi.encodeCall(IERC20Approve.approve, (MIDNIGHT, amount)));
        require(success && (returndata.length == 0 || abi.decode(returndata, (bool))), ApproveFailed());
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BaseTest, LLTV, LIQUIDATION_CURSOR} from "midnight/test/BaseTest.sol";
import {Market, Offer, CollateralParams} from "midnight/src/interfaces/IMidnight.sol";
import {MAX_TICK} from "midnight/src/libraries/TickLib.sol";
import {LimitKeys} from "../src/LimitKeys.sol";
import {MidnightManagedAccount} from "../src/MidnightManagedAccount.sol";

abstract contract MMABase is BaseTest {
    uint128 internal constant BIG = type(uint128).max;

    MidnightManagedAccount internal mma;
    address internal owner;
    address internal treasury;
    address internal operator;
    address internal freezer;
    address internal receiver;
    Market internal market;
    bytes32 internal marketId;

    function setUp() public virtual override {
        super.setUp();

        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        operator = makeAddr("operator");
        freezer = makeAddr("freezer");
        receiver = makeAddr("receiver");

        CollateralParams[] memory params = new CollateralParams[](2);
        params[0] = CollateralParams(address(collateralToken1), LLTV, LIQUIDATION_CURSOR, address(oracle1));
        params[1] = CollateralParams(address(collateralToken2), LLTV, LIQUIDATION_CURSOR, address(oracle2));
        market.chainId = block.chainid;
        market.midnight = address(midnight);
        market.loanToken = address(loanToken);
        market.collateralParams = sortCollateralParams(params);
        market.maturity = vm.getBlockTimestamp() + 30 days;
        marketId = toId(market);

        mma = new MidnightManagedAccount(owner, address(midnight));

        vm.prank(owner);
        midnight.setIsAuthorized(address(mma), true, owner);

        vm.startPrank(treasury);
        loanToken.approve(address(mma), type(uint256).max);
        collateralToken1.approve(address(mma), type(uint256).max);
        collateralToken2.approve(address(mma), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(owner);
        mma.setTreasury(treasury);
        mma.setOperator(operator, true);
        mma.setFreezer(freezer, true);
        mma.setMarketConfig(marketId, BIG, 1e9, 0, true);
        mma.setPaused(false);
        vm.stopPrank();

        _setLimit(LimitKeys.borrowUnits(marketId), BIG, 0);
        _setLimit(LimitKeys.borrowUnits(marketId, operator), BIG, 0);
        _setLimit(LimitKeys.tokenBorrowUnits(address(loanToken)), BIG, 0);
        _setLimit(LimitKeys.borrowAssetsOut(marketId, receiver), BIG, 0);
        _setLimit(LimitKeys.lendAssets(marketId), BIG, 0);
        _setLimit(LimitKeys.lendAssets(marketId, operator), BIG, 0);
        _setLimit(LimitKeys.tokenLendAssets(address(loanToken)), BIG, 0);
        _setLimit(LimitKeys.withdrawAssets(marketId, receiver), BIG, 0);
        _setLimit(LimitKeys.repayAssets(marketId), BIG, 0);
        _setLimit(LimitKeys.collateralAssetsIn(marketId, _collateralToken(0)), BIG, 0);
        _setLimit(LimitKeys.collateralAssetsOut(marketId, _collateralToken(0), receiver), BIG, 0);
    }

    function _setLimit(bytes32 key, uint128 maxAmount, uint128 refillPerSecond) internal {
        vm.prank(owner);
        mma.setLimit(key, maxAmount, refillPerSecond);
    }

    function _collateralToken(uint256 index) internal view returns (address) {
        return market.collateralParams[index].token;
    }

    function _buyOffer() internal view returns (Offer memory offer) {
        offer.market = market;
        offer.buy = true;
        offer.maker = lender;
        offer.maxUnits = type(uint128).max;
        offer.continuousFeeCap = type(uint256).max;
        offer.ratifier = address(dummyRatifier);
        offer.expiry = vm.getBlockTimestamp() + 200;
        offer.tick = MAX_TICK;
    }

    function _sellOffer() internal view returns (Offer memory offer) {
        offer.market = market;
        offer.maker = borrower;
        offer.receiverIfMakerIsSeller = borrower;
        offer.maxUnits = type(uint128).max;
        offer.continuousFeeCap = type(uint256).max;
        offer.ratifier = address(dummyRatifier);
        offer.expiry = vm.getBlockTimestamp() + 200;
        offer.tick = MAX_TICK;
    }

    function _borrow(uint256 units) internal returns (uint256 buyerAssets, uint256 sellerAssets) {
        collateralize(market, owner, units);
        deal(address(loanToken), lender, units);
        vm.prank(operator);
        return mma.borrow(_buyOffer(), hex"", units, receiver, 0);
    }

    function _lend(uint256 units) internal returns (uint256 buyerAssets, uint256 sellerAssets) {
        collateralize(market, borrower, units);
        deal(address(loanToken), treasury, units);
        vm.prank(operator);
        return mma.lend(_sellOffer(), hex"", units, units);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "midnight/test/erc20s/ERC20.sol";
import {Offer} from "midnight/src/interfaces/IMidnight.sol";
import {TickLib, MAX_TICK} from "midnight/src/libraries/TickLib.sol";
import {WAD} from "midnight/src/libraries/ConstantsLib.sol";
import {UtilsLib} from "midnight/src/libraries/UtilsLib.sol";
import {LimitKeys} from "../src/LimitKeys.sol";
import {MidnightManagedAccount} from "../src/MidnightManagedAccount.sol";
import {MidnightManagedAccountLimits} from "../src/MidnightManagedAccountLimits.sol";
import {MMABase} from "./MMABase.sol";

contract MidnightManagedAccountTest is MMABase {
    using UtilsLib for uint256;

    function test_Borrow() public {
        (, uint256 sellerAssets) = _borrow(100e18);
        assertEq(sellerAssets, 100e18);
        assertEq(loanToken.balanceOf(receiver), 100e18);
        assertEq(midnight.debt(marketId, owner), 100e18);
    }

    function test_BorrowConsumesOperatorBucket() public {
        _setLimit(LimitKeys.borrowUnits(marketId, operator), 150e18, 0);
        _borrow(100e18);
        assertEq(mma.availableLimit(LimitKeys.borrowUnits(marketId, operator)), 50e18);
    }

    function test_BorrowRequiresOperatorBucket() public {
        _setLimit(LimitKeys.borrowUnits(marketId, operator), 0, 0);
        vm.prank(operator);
        vm.expectPartialRevert(MidnightManagedAccountLimits.LimitNotConfigured.selector);
        mma.borrow(_buyOffer(), hex"", 100e18, receiver, 0);
    }

    function test_BorrowOnlyOperator() public {
        vm.expectRevert(MidnightManagedAccount.NotOperator.selector);
        mma.borrow(_buyOffer(), hex"", 1e18, receiver, 0);
    }

    function test_BorrowWrongOfferSide() public {
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccount.InvalidOfferSide.selector);
        mma.borrow(_sellOffer(), hex"", 1e18, receiver, 0);
    }

    function test_BorrowMarketNotEnabled() public {
        vm.prank(owner);
        mma.setMarketConfig(marketId, BIG, 1e9, 0, false);
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccount.MarketNotEnabled.selector);
        mma.borrow(_buyOffer(), hex"", 1e18, receiver, 0);
    }

    function test_BorrowMaturedMarket() public {
        Offer memory offer = _buyOffer();
        vm.warp(market.maturity);
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccount.MarketMatured.selector);
        mma.borrow(offer, hex"", 1e18, receiver, 0);
    }

    function test_BorrowMinAssetsOut() public {
        collateralize(market, owner, 100e18);
        deal(address(loanToken), lender, 100e18);
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccount.InsufficientAssetsOut.selector);
        mma.borrow(_buyOffer(), hex"", 100e18, receiver, 100e18 + 1);
    }

    function test_BorrowRateCeiling() public {
        vm.prank(owner);
        mma.setMarketConfig(marketId, BIG, 0, 0, true);
        collateralize(market, owner, 100e18);
        deal(address(loanToken), lender, 100e18);
        Offer memory offer = _buyOffer();
        offer.tick = MAX_TICK - 4;
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccount.BorrowRateAboveLimit.selector);
        mma.borrow(offer, hex"", 100e18, receiver, 0);
    }

    function test_BorrowDebtLimit() public {
        vm.prank(owner);
        mma.setMarketConfig(marketId, 50e18, 1e9, 0, true);
        collateralize(market, owner, 100e18);
        deal(address(loanToken), lender, 100e18);
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccount.DebtLimitExceeded.selector);
        mma.borrow(_buyOffer(), hex"", 100e18, receiver, 0);
    }

    function test_BorrowReceiverAllowlist() public {
        collateralize(market, owner, 100e18);
        deal(address(loanToken), lender, 100e18);
        vm.prank(operator);
        vm.expectPartialRevert(MidnightManagedAccountLimits.LimitNotConfigured.selector);
        mma.borrow(_buyOffer(), hex"", 100e18, makeAddr("other"), 0);
    }

    function test_Lend() public {
        (uint256 buyerAssets,) = _lend(100e18);
        assertEq(buyerAssets, 100e18);
        assertEq(loanToken.balanceOf(treasury), 0);
        assertEq(loanToken.balanceOf(address(mma)), 0);
        assertEq(loanToken.allowance(address(mma), address(midnight)), 0);
    }

    function test_LendWrongOfferSide() public {
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccount.InvalidOfferSide.selector);
        mma.lend(_buyOffer(), hex"", 1e18, 1e18);
    }

    function test_LendMaturedMarket() public {
        Offer memory offer = _sellOffer();
        vm.warp(market.maturity);
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccount.MarketMatured.selector);
        mma.lend(offer, hex"", 1e18, 1e18);
    }

    function test_LendMaxAssetsIn() public {
        collateralize(market, borrower, 100e18);
        deal(address(loanToken), treasury, 100e18);
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccount.ExcessiveAssetsIn.selector);
        mma.lend(_sellOffer(), hex"", 100e18, 100e18 - 1);
    }

    function test_LendRateFloor() public {
        vm.prank(owner);
        mma.setMarketConfig(marketId, BIG, 1e9, 1, true);
        collateralize(market, borrower, 100e18);
        deal(address(loanToken), treasury, 100e18);
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccount.LendRateBelowLimit.selector);
        mma.lend(_sellOffer(), hex"", 100e18, 100e18);
    }

    function test_LendRateFloorNetsContinuousFee() public {
        uint256 units = 100e18;
        uint256 fee = 3e8;
        uint256 tick = 4292;
        midnight.setDefaultContinuousFee(address(loanToken), fee);

        Offer memory offer = _sellOffer();
        offer.tick = tick;

        uint256 ttm = market.maturity - vm.getBlockTimestamp();
        uint256 assets = units.mulDivUp(TickLib.tickToPrice(tick), WAD);
        uint256 pendingFee = units.mulDivDown(fee * ttm, WAD);
        uint64 boundaryRate = uint64((units - pendingFee - assets) * WAD / (assets * ttm));

        vm.prank(owner);
        mma.setMarketConfig(marketId, BIG, 1e9, boundaryRate, true);
        collateralize(market, borrower, units);
        deal(address(loanToken), treasury, units);
        vm.prank(operator);
        (uint256 buyerAssets,) = mma.lend(offer, hex"", units, units);
        assertEq(buyerAssets, assets);

        vm.prank(owner);
        mma.setMarketConfig(marketId, BIG, 1e9, boundaryRate + 1, true);
        collateralize(market, borrower, units);
        deal(address(loanToken), treasury, units);
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccount.LendRateBelowLimit.selector);
        mma.lend(offer, hex"", units, units);
    }

    function test_LendConsumesTokenAggregate() public {
        _setLimit(LimitKeys.tokenLendAssets(address(loanToken)), 150e18, 0);
        _lend(100e18);
        assertEq(mma.availableLimit(LimitKeys.tokenLendAssets(address(loanToken))), 50e18);
    }

    function test_LendRequiresTokenAggregate() public {
        _setLimit(LimitKeys.tokenLendAssets(address(loanToken)), 0, 0);
        collateralize(market, borrower, 1e18);
        deal(address(loanToken), treasury, 1e18);
        vm.prank(operator);
        vm.expectPartialRevert(MidnightManagedAccountLimits.LimitNotConfigured.selector);
        mma.lend(_sellOffer(), hex"", 1e18, 1e18);
    }

    function test_Repay() public {
        _borrow(100e18);
        deal(address(loanToken), treasury, 100e18);
        vm.prank(operator);
        mma.repay(market, 100e18);
        assertEq(midnight.debt(marketId, owner), 0);
        assertEq(loanToken.balanceOf(treasury), 0);
        assertEq(loanToken.balanceOf(address(mma)), 0);
        assertEq(loanToken.allowance(address(mma), address(midnight)), 0);
    }

    function test_Withdraw() public {
        _lend(100e18);
        deal(address(loanToken), borrower, 100e18);
        vm.prank(borrower);
        midnight.repay(market, 100e18, borrower, address(0), hex"");
        vm.prank(operator);
        mma.withdraw(market, 100e18, receiver);
        assertEq(loanToken.balanceOf(receiver), 100e18);
    }

    function test_WithdrawReceiverAllowlist() public {
        vm.prank(operator);
        vm.expectPartialRevert(MidnightManagedAccountLimits.LimitNotConfigured.selector);
        mma.withdraw(market, 1e18, makeAddr("other"));
    }

    function test_SupplyAndWithdrawCollateral() public {
        address token = market.collateralParams[0].token;
        deal(token, treasury, 10e18);
        vm.prank(operator);
        mma.supplyCollateral(market, 0, 10e18);
        assertEq(ERC20(token).balanceOf(treasury), 0);
        assertEq(ERC20(token).balanceOf(address(mma)), 0);
        vm.prank(operator);
        mma.withdrawCollateral(market, 0, 10e18, receiver);
        assertEq(ERC20(token).balanceOf(receiver), 10e18);
    }

    function test_CollateralBucketsAreTokenScoped() public {
        address token = market.collateralParams[1].token;
        deal(token, treasury, 10e18);
        vm.prank(operator);
        vm.expectPartialRevert(MidnightManagedAccountLimits.LimitNotConfigured.selector);
        mma.supplyCollateral(market, 1, 10e18);
    }

    function test_WithdrawCollateralReceiverAllowlist() public {
        address token = market.collateralParams[0].token;
        deal(token, treasury, 10e18);
        vm.prank(operator);
        mma.supplyCollateral(market, 0, 10e18);
        _setLimit(LimitKeys.collateralAssetsOut(marketId, _collateralToken(0), makeAddr("other")), 0, 0);
        vm.prank(operator);
        vm.expectPartialRevert(MidnightManagedAccountLimits.LimitNotConfigured.selector);
        mma.withdrawCollateral(market, 0, 10e18, makeAddr("other"));
    }

    function test_BorrowRevertsWhilePaused() public {
        vm.prank(freezer);
        mma.freeze();
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccount.AccountPaused.selector);
        mma.borrow(_buyOffer(), hex"", 1e18, receiver, 0);
    }

    function test_LendRevertsWhilePaused() public {
        vm.prank(freezer);
        mma.freeze();
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccount.AccountPaused.selector);
        mma.lend(_sellOffer(), hex"", 1e18, 1e18);
    }

    function test_WithdrawRevertsWhilePaused() public {
        vm.prank(freezer);
        mma.freeze();
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccount.AccountPaused.selector);
        mma.withdraw(market, 1e18, receiver);
    }

    function test_WithdrawCollateralRevertsWhilePaused() public {
        vm.prank(freezer);
        mma.freeze();
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccount.AccountPaused.selector);
        mma.withdrawCollateral(market, 0, 1e18, receiver);
    }

    function test_RepayWorksWhilePaused() public {
        _borrow(100e18);
        deal(address(loanToken), treasury, 100e18);
        vm.prank(freezer);
        mma.freeze();
        vm.prank(operator);
        mma.repay(market, 100e18);
        assertEq(midnight.debt(marketId, owner), 0);
    }

    function test_SupplyCollateralWorksWhilePaused() public {
        address token = market.collateralParams[0].token;
        deal(token, treasury, 10e18);
        vm.prank(freezer);
        mma.freeze();
        vm.prank(operator);
        mma.supplyCollateral(market, 0, 10e18);
        assertEq(ERC20(token).balanceOf(treasury), 0);
    }

    function test_FrozenOperatorCannotRepay() public {
        _borrow(100e18);
        deal(address(loanToken), treasury, 100e18);
        vm.prank(freezer);
        mma.freezeOperator(operator);
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccount.NotOperator.selector);
        mma.repay(market, 100e18);
    }

    function test_OnBuyOnlyMidnight() public {
        vm.expectRevert(MidnightManagedAccount.OnlyMidnight.selector);
        mma.onBuy(marketId, market, 1e18, 1e18, 0, owner, hex"");
    }

    function test_OnRepayOnlyMidnight() public {
        vm.expectRevert(MidnightManagedAccount.OnlyMidnight.selector);
        mma.onRepay(marketId, market, 1e18, owner, hex"");
    }

    function test_OnBuyWithoutExpectationReverts() public {
        vm.prank(address(midnight));
        vm.expectRevert(MidnightManagedAccount.UnexpectedCallback.selector);
        mma.onBuy(marketId, market, 1e18, 1e18, 0, owner, hex"");
    }

    function test_OnRepayWithoutExpectationReverts() public {
        vm.prank(address(midnight));
        vm.expectRevert(MidnightManagedAccount.UnexpectedCallback.selector);
        mma.onRepay(marketId, market, 1e18, owner, hex"");
    }

    function test_ForeignOfferCallbackCannotPullTreasury() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        midnight.setIsAuthorized(address(dummyRatifier), true, attacker);

        Offer memory offer = _buyOffer();
        offer.maker = attacker;
        offer.callback = address(mma);

        collateralize(market, borrower, 100e18);
        vm.prank(borrower);
        vm.expectRevert(MidnightManagedAccount.UnexpectedCallback.selector);
        midnight.take(offer, hex"", 100e18, borrower, borrower, address(0), hex"");
    }

    function test_SweepOnlyOwner() public {
        deal(address(loanToken), address(mma), 5e18);
        vm.expectRevert(MidnightManagedAccountLimits.OnlyOwner.selector);
        mma.sweep(address(loanToken), receiver, 5e18);
        vm.prank(owner);
        mma.sweep(address(loanToken), receiver, 5e18);
        assertEq(loanToken.balanceOf(receiver), 5e18);
    }

    function test_SetTreasuryOnlyOwner() public {
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccountLimits.OnlyOwner.selector);
        mma.setTreasury(operator);
    }

    function test_SetTreasuryZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(MidnightManagedAccount.InvalidTreasury.selector);
        mma.setTreasury(address(0));
    }
}

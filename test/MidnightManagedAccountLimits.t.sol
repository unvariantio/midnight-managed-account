// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {MidnightManagedAccountLimits} from "../src/MidnightManagedAccountLimits.sol";

contract LimitsHarness is MidnightManagedAccountLimits {
    constructor(address owner) MidnightManagedAccountLimits(owner) {}

    function consume(bytes32 key, uint256 amount) external {
        _consumeLimit(key, amount);
    }
}

contract MidnightManagedAccountLimitsTest is Test {
    LimitsHarness internal limits;
    address internal freezer = makeAddr("freezer");
    address internal operator = makeAddr("operator");
    bytes32 internal key = keccak256("key");

    function setUp() public {
        limits = new LimitsHarness(address(this));
        limits.setFreezer(freezer, true);
        limits.setOperator(operator, true);
    }

    function _available() internal view returns (uint256) {
        return limits.availableLimit(key);
    }

    function test_ZeroOwnerReverts() public {
        vm.expectRevert(MidnightManagedAccountLimits.InvalidOwner.selector);
        new LimitsHarness(address(0));
    }

    function test_PausedByDefault() public view {
        assertTrue(limits.paused());
    }

    function test_ConsumeUnconfiguredReverts() public {
        vm.expectPartialRevert(MidnightManagedAccountLimits.LimitNotConfigured.selector);
        limits.consume(key, 1);
    }

    function test_NewBucketStartsFull() public {
        limits.setLimit(key, 100, 0);
        assertEq(_available(), 100);
    }

    function test_ConsumeDecrements() public {
        limits.setLimit(key, 100, 0);
        limits.consume(key, 60);
        assertEq(_available(), 40);
    }

    function test_ConsumeExceedingReverts() public {
        limits.setLimit(key, 100, 0);
        vm.expectPartialRevert(MidnightManagedAccountLimits.LimitExceeded.selector);
        limits.consume(key, 101);
    }

    function test_RefillIsLinearAndClamped() public {
        limits.setLimit(key, 100, 1);
        limits.consume(key, 100);
        assertEq(_available(), 0);
        vm.warp(vm.getBlockTimestamp() + 40);
        assertEq(_available(), 40);
        vm.warp(vm.getBlockTimestamp() + 1000);
        assertEq(_available(), 100);
    }

    function test_ReconfigurePreservesBalance() public {
        limits.setLimit(key, 100, 0);
        limits.consume(key, 60);
        limits.setLimit(key, 100, 0);
        assertEq(_available(), 40);
    }

    function test_ReconfigureClampsToNewMax() public {
        limits.setLimit(key, 100, 0);
        limits.setLimit(key, 50, 0);
        assertEq(_available(), 50);
    }

    function test_RemovalDenies() public {
        limits.setLimit(key, 100, 0);
        limits.setLimit(key, 0, 0);
        vm.expectPartialRevert(MidnightManagedAccountLimits.LimitNotConfigured.selector);
        limits.consume(key, 1);
    }

    function test_RemoveThenSetRefills() public {
        limits.setLimit(key, 100, 0);
        limits.consume(key, 100);
        limits.setLimit(key, 0, 0);
        limits.setLimit(key, 100, 0);
        assertEq(_available(), 100);
    }

    function test_SetLimitOnlyOwner() public {
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccountLimits.OnlyOwner.selector);
        limits.setLimit(key, 100, 0);
    }

    function test_SetMarketConfigOnlyOwner() public {
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccountLimits.OnlyOwner.selector);
        limits.setMarketConfig(key, 1, 1, 1, true);
    }

    function test_FreezerFreezes() public {
        limits.setPaused(false);
        vm.prank(freezer);
        limits.freeze();
        assertTrue(limits.paused());
    }

    function test_FreezerCannotUnpause() public {
        vm.prank(freezer);
        vm.expectRevert(MidnightManagedAccountLimits.OnlyOwner.selector);
        limits.setPaused(false);
    }

    function test_FreezerFreezesOperator() public {
        vm.prank(freezer);
        limits.freezeOperator(operator);
        assertFalse(limits.isOperator(operator));
    }

    function test_FreezerCannotEnableOperator() public {
        vm.prank(freezer);
        vm.expectRevert(MidnightManagedAccountLimits.OnlyOwner.selector);
        limits.setOperator(operator, true);
    }

    function test_NonFreezerCannotFreeze() public {
        vm.prank(operator);
        vm.expectRevert(MidnightManagedAccountLimits.OnlyOwnerOrFreezer.selector);
        limits.freeze();
    }
}

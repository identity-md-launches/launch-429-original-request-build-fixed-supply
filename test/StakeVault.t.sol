// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StakeVault} from "../src/StakeVault.sol";

contract StakeVaultTest is Test {
    LaunchToken private token;
    StakeVault private vault;
    address private constant OWNER = address(0x1234);
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    uint256 private start;

    function setUp() public {
        vm.warp(1_000_000);
        start = vm.getBlockTimestamp();
        token = new LaunchToken();
        vault = new StakeVault(address(token), OWNER, 7 days);
        token.transfer(OWNER, 10_000 ether);
        token.transfer(ALICE, 1_000 ether);
        token.transfer(BOB, 1_000 ether);
        vm.prank(OWNER);
        token.approve(address(vault), type(uint256).max);
        vm.prank(ALICE);
        token.approve(address(vault), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(vault), type(uint256).max);
    }

    function _stake(address account, uint256 amount) private {
        vm.prank(account);
        vault.stake(amount);
    }

    function _fund(uint256 amount) private {
        vm.prank(OWNER);
        vault.fundRewards(amount);
    }

    function _claim(address account) private returns (uint256 amount) {
        vm.prank(account);
        amount = vault.claimRewards();
    }

    function test_constructorConfigurationAndValidation() public {
        assertEq(address(vault.token()), address(token));
        assertEq(vault.owner(), OWNER);
        assertEq(vault.lockDuration(), 7 days);
        assertEq(vault.REWARD_DURATION(), 7 days);
        vm.expectRevert(StakeVault.InvalidToken.selector);
        new StakeVault(address(0), OWNER, 7 days);
        vm.expectRevert(StakeVault.InvalidToken.selector);
        new StakeVault(ALICE, OWNER, 7 days);
        vm.expectRevert(StakeVault.InvalidOwner.selector);
        new StakeVault(address(token), address(0), 7 days);
        vm.expectRevert(StakeVault.InvalidLock.selector);
        new StakeVault(address(token), OWNER, 0);
        vm.expectRevert(StakeVault.InvalidLock.selector);
        new StakeVault(address(token), OWNER, uint256(type(uint64).max) + 1);
    }

    function test_stakeAndWithdrawExactlyAtLockBoundary() public {
        _stake(ALICE, 100 ether);
        assertEq(vault.balanceOf(ALICE), 100 ether);
        assertEq(vault.totalStaked(), 100 ether);
        assertEq(vault.unlockAt(ALICE), start + 7 days);
        assertEq(token.balanceOf(address(vault)), 100 ether);
        vm.warp(start + 7 days - 1);
        vm.expectRevert(abi.encodeWithSelector(StakeVault.StakeLocked.selector, start + 7 days));
        vm.prank(ALICE);
        vault.withdraw(100 ether);
        vm.warp(start + 7 days);
        vm.prank(ALICE);
        vault.withdraw(40 ether);
        assertEq(vault.unlockAt(ALICE), start + 7 days);
        assertEq(vault.balanceOf(ALICE), 60 ether);
        vm.prank(ALICE);
        vault.withdraw(60 ether);
        assertEq(vault.unlockAt(ALICE), 0);
        assertEq(vault.totalStaked(), 0);
        assertEq(token.balanceOf(ALICE), 1_000 ether);
    }

    function test_topUpResetsOnlyCallersEntireLock() public {
        _stake(ALICE, 100 ether);
        _stake(BOB, 100 ether);
        vm.warp(start + 6 days);
        _stake(ALICE, 1);
        assertEq(vault.unlockAt(ALICE), start + 13 days);
        assertEq(vault.unlockAt(BOB), start + 7 days);
        vm.warp(start + 7 days);
        vm.expectRevert(abi.encodeWithSelector(StakeVault.StakeLocked.selector, start + 13 days));
        vm.prank(ALICE);
        vault.withdraw(1);
        vm.prank(BOB);
        vault.withdraw(100 ether);
        vm.warp(start + 13 days);
        vm.prank(ALICE);
        vault.withdraw(100 ether + 1);
    }

    function test_invalidAmountsAndUnapprovedDepositAreAtomic() public {
        vm.expectRevert(StakeVault.ZeroAmount.selector);
        vm.prank(ALICE);
        vault.stake(0);
        vm.expectRevert(StakeVault.ZeroAmount.selector);
        vm.prank(ALICE);
        vault.withdraw(0);
        vm.expectRevert(StakeVault.ZeroAmount.selector);
        vm.prank(OWNER);
        vault.fundRewards(0);
        vm.prank(ALICE);
        token.approve(address(vault), 0);
        vm.expectRevert();
        vm.prank(ALICE);
        vault.stake(100 ether);
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.unlockAt(ALICE), 0);
        vm.expectRevert(StakeVault.InsufficientStake.selector);
        vm.prank(ALICE);
        vault.withdraw(1);
        vm.prank(OWNER);
        token.approve(address(vault), 0);
        vm.expectRevert();
        vm.prank(OWNER);
        vault.fundRewards(100 ether);
        assertEq(vault.rewardReserve(), 0);
        assertEq(vault.periodFinish(), 0);
    }

    function test_pauseDoesNotStopClaimsWithdrawalsOrFunding() public {
        _stake(ALICE, 100 ether);
        _fund(700 ether);
        vm.prank(OWNER);
        vault.setDepositsPaused(true);
        vm.expectRevert(StakeVault.DepositsPaused.selector);
        vm.prank(BOB);
        vault.stake(100 ether);
        vm.warp(start + 7 days);
        assertEq(_claim(ALICE), 700 ether);
        vm.prank(ALICE);
        vault.withdraw(100 ether);
        _fund(700 ether);
        vm.prank(OWNER);
        vault.setDepositsPaused(false);
        _stake(BOB, 100 ether);
        assertEq(vault.balanceOf(BOB), 100 ether);
    }

    function test_onlyOwnerCanPauseOrFundAndOwnerCannotWithdrawUserStake() public {
        _stake(ALICE, 100 ether);
        vm.expectRevert(StakeVault.Unauthorized.selector);
        vm.prank(ALICE);
        vault.setDepositsPaused(true);
        vm.expectRevert(StakeVault.Unauthorized.selector);
        vm.prank(ALICE);
        vault.fundRewards(100 ether);
        vm.warp(start + 7 days);
        vm.expectRevert(StakeVault.InsufficientStake.selector);
        vm.prank(OWNER);
        vault.withdraw(100 ether);
        assertEq(_claim(OWNER), 0);
        bytes[4] memory selectors = [
            abi.encodeWithSignature("withdrawFor(address,uint256)", ALICE, 100 ether),
            abi.encodeWithSignature("recoverERC20(address,uint256)", address(token), 100 ether),
            abi.encodeWithSignature("emergencyWithdraw()"),
            abi.encodeWithSignature("transferOwnership(address)", ALICE)
        ];
        for (uint256 i; i < selectors.length; ++i) {
            vm.prank(OWNER);
            (bool ok,) = address(vault).call(selectors[i]);
            assertFalse(ok);
        }
        assertEq(vault.balanceOf(ALICE), 100 ether);
        assertEq(token.balanceOf(address(vault)), 100 ether);
    }

    function test_singleStakerEarnsOverTimeCanClaimWhileLockedAndCannotDoubleClaim() public {
        _stake(ALICE, 100 ether);
        _fund(700 ether);
        assertEq(vault.earned(ALICE), 0);
        vm.warp(start + 1 days);
        assertEq(vault.earned(ALICE), 100 ether);
        assertEq(_claim(ALICE), 100 ether);
        assertEq(_claim(ALICE), 0);
        assertEq(vault.rewardReserve(), 600 ether);
        assertEq(vault.balanceOf(ALICE), 100 ether);
        vm.warp(start + 7 days);
        assertEq(_claim(ALICE), 600 ether);
        vm.warp(start + 700 days);
        assertEq(_claim(ALICE), 0);
        assertEq(token.balanceOf(address(vault)), 100 ether);
    }

    function test_rewardsAreProportionalToStake() public {
        _stake(ALICE, 100 ether);
        _stake(BOB, 300 ether);
        _fund(700 ether);
        vm.warp(start + 7 days);
        assertEq(_claim(ALICE), 175 ether);
        assertEq(_claim(BOB), 525 ether);
        assertEq(vault.rewardReserve(), 0);
        assertEq(token.balanceOf(address(vault)), vault.totalStaked());
    }

    function test_lateEntryDoesNotEarnHistoricalRewards() public {
        _stake(ALICE, 100 ether);
        _fund(700 ether);
        vm.warp(start + 3 days + 12 hours);
        _stake(BOB, 100 ether);
        assertEq(vault.earned(BOB), 0);
        vm.warp(start + 7 days);
        assertEq(_claim(ALICE), 525 ether);
        assertEq(_claim(BOB), 175 ether);
    }

    function test_withdrawalPreservesEarnedRewardsAndStopsNewEarnings() public {
        _stake(ALICE, 100 ether);
        _stake(BOB, 100 ether);
        vm.warp(start + 7 days);
        _fund(700 ether);
        vm.warp(start + 10 days + 12 hours);
        vm.prank(ALICE);
        vault.withdraw(100 ether);
        assertEq(vault.earned(ALICE), 175 ether);
        vm.warp(start + 14 days);
        assertEq(_claim(ALICE), 175 ether);
        assertEq(_claim(BOB), 525 ether);
        assertEq(vault.balanceOf(ALICE), 0);
    }

    function test_topUpPreservesEarnedAndReschedulesOnlyUnvested() public {
        _stake(ALICE, 100 ether);
        _fund(700 ether);
        vm.warp(start + 3 days + 12 hours);
        _fund(350 ether);
        assertEq(vault.earned(ALICE), 350 ether);
        assertEq(vault.periodReward(), 700 ether);
        assertEq(vault.periodFinish(), vm.getBlockTimestamp() + 7 days);
        assertEq(_claim(ALICE), 350 ether);
        vm.warp(start + 10 days + 12 hours);
        assertEq(_claim(ALICE), 700 ether);
        assertEq(vault.rewardReserve(), 0);
    }

    function test_emptyIntervalsAreNotAwardedToNextDepositorAndRecycleOnFunding() public {
        _fund(700 ether);
        vm.warp(start + 3 days + 12 hours);
        _stake(ALICE, 100 ether);
        assertEq(vault.unallocatedRewards(), 350 ether);
        assertEq(vault.earned(ALICE), 0);
        vm.warp(start + 7 days);
        assertEq(_claim(ALICE), 350 ether);
        assertEq(vault.rewardReserve(), 350 ether);
        _fund(350 ether);
        assertEq(vault.periodReward(), 700 ether);
        assertEq(vault.unallocatedRewards(), 0);
        vm.warp(start + 14 days);
        assertEq(_claim(ALICE), 700 ether);
        assertEq(vault.rewardReserve(), 0);
    }

    function test_fundingAfterFullyIdlePeriodRecyclesWholePool() public {
        _fund(700 ether);
        vm.warp(start + 14 days);
        _fund(1 ether);
        assertEq(vault.periodReward(), 701 ether);
        _stake(ALICE, 1 ether);
        vm.warp(start + 21 days);
        assertEq(_claim(ALICE), 701 ether);
    }

    function test_oneWeiRewardIsNotLostToIntegerRateRounding() public {
        _stake(ALICE, 1);
        _fund(1);
        vm.warp(start + 7 days - 1);
        assertEq(_claim(ALICE), 0);
        vm.warp(start + 7 days);
        assertEq(_claim(ALICE), 1);
        assertEq(vault.rewardReserve(), 0);
    }

    function test_stakingBeforeFundingAndAfterFinishDoesNotEarn() public {
        _stake(ALICE, 100 ether);
        vm.warp(start + 7 days);
        assertEq(_claim(ALICE), 0);
        _fund(700 ether);
        vm.warp(start + 21 days);
        _stake(BOB, 100 ether);
        vm.warp(start + 28 days);
        assertEq(_claim(ALICE), 700 ether);
        assertEq(_claim(BOB), 0);
    }

    function test_directDonationsAreNeitherPrincipalNorScheduledRewards() public {
        _stake(ALICE, 100 ether);
        token.transfer(address(vault), 200 ether);
        _fund(700 ether);
        vm.warp(start + 7 days);
        assertEq(_claim(ALICE), 700 ether);
        vm.prank(ALICE);
        vault.withdraw(100 ether);
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.rewardReserve(), 0);
        assertEq(token.balanceOf(address(vault)), 200 ether);
    }

    function testFuzz_twoStakersConserveRewards(uint96 aliceStake, uint96 bobStake, uint96 funding) public {
        uint256 a = bound(aliceStake, 1, 1_000 ether);
        uint256 b = bound(bobStake, 1, 1_000 ether);
        uint256 f = bound(funding, 1, 10_000 ether);
        _stake(ALICE, a);
        _stake(BOB, b);
        _fund(f);
        vm.warp(start + 7 days);
        uint256 aliceReward = _claim(ALICE);
        uint256 bobReward = _claim(BOB);
        assertApproxEqAbs(aliceReward, f * a / (a + b), 1);
        assertApproxEqAbs(bobReward, f * b / (a + b), 1);
        assertLe(aliceReward + bobReward, f);
        assertEq(vault.rewardReserve(), f - aliceReward - bobReward);
        vm.prank(ALICE);
        vault.withdraw(a);
        vm.prank(BOB);
        vault.withdraw(b);
        assertEq(token.balanceOf(address(vault)), vault.rewardReserve());
    }
}

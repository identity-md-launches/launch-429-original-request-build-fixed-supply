// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {StakeVault} from "src/StakeVault.sol";

/// @notice Independent boundary and economic properties supplementing the accepted functional suite.
/// forge-config: default.fuzz.runs = 1000
contract StakeVaultPropertiesTest is Test {
    uint256 private constant SUPPLY = 1e27;
    uint256 private constant DURATION = 7 days;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    LaunchToken private token;
    StakeVault private vault;

    function setUp() public {
        vm.warp(1_000_000);
        token = new LaunchToken();
        vault = new StakeVault(address(token), address(this), DURATION);
        token.approve(address(vault), type(uint256).max);
        vm.prank(ALICE);
        token.approve(address(vault), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(vault), type(uint256).max);
    }

    function test_entireSupplyCanBeStakedAndWithdrawnWhilePaused() public {
        _giveAndStake(ALICE, SUPPLY);
        vault.setDepositsPaused(true);
        vm.warp(vault.unlockAt(ALICE));
        vm.prank(ALICE);
        vault.withdraw(SUPPLY);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.unlockAt(ALICE), 0);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_oneWeiStakeCanEarnAllRemainingSupply() public {
        _giveAndStake(ALICE, 1);
        vault.fundRewards(SUPPLY - 1);
        vm.warp(vault.periodFinish());
        vm.prank(ALICE);
        assertEq(vault.claimRewards(), SUPPLY - 1);
        assertEq(vault.rewardReserve(), 0);
        assertEq(token.balanceOf(address(vault)), 1, "principal survives the maximum reward index");
        vm.prank(ALICE);
        vault.withdraw(1);
        assertEq(token.balanceOf(ALICE), SUPPLY);
    }

    function test_constructorRejectsVaultAsItsOwnOwner() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(StakeVault.InvalidOwner.selector);
        new StakeVault(address(token), predicted, DURATION);
    }

    function test_maximumLockRemainsEnforcedAfterRewardsFinish() public {
        _checkCustomLock(type(uint64).max);
    }

    function test_oneSecondLockDoesNotShortenRewardSchedule() public {
        StakeVault shortVault = new StakeVault(address(token), address(this), 1);
        token.approve(address(shortVault), type(uint256).max);
        shortVault.stake(1 ether);
        shortVault.fundRewards(DURATION * 1 ether);
        vm.warp(vm.getBlockTimestamp() + 1);
        shortVault.withdraw(1 ether);
        assertEq(shortVault.claimRewards(), 1 ether);
        vm.warp(shortVault.periodFinish());
        assertEq(shortVault.claimRewards(), 0);
        assertEq(shortVault.unallocatedRewards(), (DURATION - 1) * 1 ether);
        assertEq(shortVault.rewardReserve(), (DURATION - 1) * 1 ether);
    }

    function testFuzz_customLockUsesConstructorValue(uint256 lockSeed) public {
        _checkCustomLock(bound(lockSeed, DURATION + 1, type(uint64).max));
    }

    function _checkCustomLock(uint256 lockSeconds) private {
        StakeVault target = new StakeVault(address(token), address(this), lockSeconds);
        token.approve(address(target), type(uint256).max);
        target.stake(1 ether);
        target.fundRewards(7 ether);
        uint256 unlock = vm.getBlockTimestamp() + lockSeconds;
        assertEq(target.unlockAt(address(this)), unlock);
        vm.warp(target.periodFinish());
        assertEq(target.claimRewards(), 7 ether, "reward duration is independent of the lock");
        vm.warp(unlock - 1);
        vm.expectRevert(abi.encodeWithSelector(StakeVault.StakeLocked.selector, unlock));
        target.withdraw(1 ether);
        vm.warp(unlock);
        target.withdraw(1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(target.unlockAt(address(this)), 0);
    }

    function test_ownerStakesAndEarnsOnSameTermsAsEveryoneElse() public {
        _giveAndStake(ALICE, 3 ether);
        vault.stake(1 ether);
        vault.fundRewards(28 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(vault.claimRewards(), 1 ether);
        assertEq(vault.earned(ALICE), 3 ether);
        vm.expectRevert(abi.encodeWithSelector(StakeVault.StakeLocked.selector, vault.unlockAt(address(this))));
        vault.withdraw(1 ether);
        vm.warp(vault.periodFinish());
        vm.expectRevert(StakeVault.InsufficientStake.selector);
        vault.withdraw(2 ether);
        vault.setDepositsPaused(true);
        vault.withdraw(1 ether);
        assertEq(vault.claimRewards(), 6 ether);
        assertEq(vault.balanceOf(ALICE), 3 ether);
        assertEq(vault.earned(ALICE), 21 ether);
        assertEq(token.balanceOf(address(vault)), 24 ether);
    }

    function test_zeroAndMaximumInputsCannotAlterAnActivePosition() public {
        _giveAndStake(ALICE, 100 ether);
        vault.fundRewards(700 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        bytes32 beforeState = _state(ALICE);
        vm.expectRevert(StakeVault.ZeroAmount.selector);
        vm.prank(ALICE);
        vault.stake(0);
        vm.expectRevert(StakeVault.ZeroAmount.selector);
        vm.prank(ALICE);
        vault.withdraw(0);
        vm.expectRevert(StakeVault.ZeroAmount.selector);
        vault.fundRewards(0);
        vm.expectRevert(StakeVault.InsufficientStake.selector);
        vm.prank(ALICE);
        vault.withdraw(type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, type(uint256).max)
        );
        vm.prank(ALICE);
        vault.stake(type(uint256).max);
        assertEq(_state(ALICE), beforeState, "rejected calls preserve checkpoints, locks and custody");
    }

    function test_failedFundingAndDepositPreserveActiveRewardsAndFiniteAllowances() public {
        _giveAndStake(ALICE, 1 ether);
        vault.fundRewards(7 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(ALICE);
        token.approve(address(vault), 10 ether);
        bytes32 beforeState = _state(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        vault.stake(1);
        assertEq(token.allowance(ALICE, address(vault)), 10 ether, "failed pull cannot spend approval");
        assertEq(_state(ALICE), beforeState);

        uint256 ownerBalance = token.balanceOf(address(this));
        token.approve(address(vault), ownerBalance + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), ownerBalance, ownerBalance + 1
            )
        );
        vault.fundRewards(ownerBalance + 1);
        assertEq(token.allowance(address(this), address(vault)), ownerBalance + 1);
        assertEq(_state(ALICE), beforeState, "failed top-up cannot postpone rewards");
        vm.prank(ALICE);
        assertEq(vault.claimRewards(), 1 ether);
    }

    function test_unstakeAndRestakeCannotAcquireRewardsFromTheGap() public {
        _giveAndStake(ALICE, 1 ether);
        _giveAndStake(BOB, 1 ether);
        vm.warp(vm.getBlockTimestamp() + DURATION);
        vault.fundRewards(700 ether);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(ALICE);
        vault.withdraw(1 ether);
        assertEq(vault.earned(ALICE), 100 ether);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(ALICE);
        vault.stake(1 ether);
        assertEq(vault.earned(ALICE), 100 ether);
        vm.warp(vault.periodFinish());
        vm.prank(ALICE);
        assertEq(vault.claimRewards(), 250 ether);
        vm.prank(BOB);
        assertEq(vault.claimRewards(), 450 ether);
        vm.expectRevert(abi.encodeWithSelector(StakeVault.StakeLocked.selector, vault.unlockAt(ALICE)));
        vm.prank(ALICE);
        vault.withdraw(1 ether);
    }

    function testFuzz_partialWithdrawalChangesOnlyFutureRewardShare(
        uint256 aliceSeed,
        uint256 bobSeed,
        uint256 withdrawalSeed,
        uint256 rewardSeed,
        uint256 elapsedSeed
    ) public {
        uint256 a = bound(aliceSeed, 2, SUPPLY / 4);
        uint256 b = bound(bobSeed, 1, SUPPLY / 4);
        uint256 removed = bound(withdrawalSeed, 1, a - 1);
        uint256 funding = bound(rewardSeed, 1, SUPPLY / 4);
        uint256 elapsed = bound(elapsedSeed, 1, DURATION - 1);
        _giveAndStake(ALICE, a);
        _giveAndStake(BOB, b);
        vm.warp(vm.getBlockTimestamp() + DURATION);
        vault.fundRewards(funding);
        vm.warp(vm.getBlockTimestamp() + elapsed);
        vm.prank(ALICE);
        vault.withdraw(removed);
        vm.warp(vault.periodFinish());

        // Integrate stake shares over the two time intervals in token units, without using vault indices.
        uint256 first = funding * elapsed / DURATION;
        uint256 expectedAlice = first * a / (a + b) + (funding - first) * (a - removed) / (a - removed + b);
        uint256 expectedBob = first * b / (a + b) + (funding - first) * b / (a - removed + b);
        // Each index checkpoint loses < 1 wei because total stake < 1e27.
        // Bob's uncheckpointed account can retain a fraction across the two intervals.
        assertApproxEqAbs(vault.earned(ALICE), expectedAlice, 2);
        assertApproxEqAbs(vault.earned(BOB), expectedBob, 2);
        vm.prank(ALICE);
        uint256 alicePaid = vault.claimRewards();
        vm.prank(BOB);
        uint256 bobPaid = vault.claimRewards();
        assertLe(alicePaid + bobPaid, funding);
        vm.prank(ALICE);
        vault.withdraw(a - removed);
        vm.prank(BOB);
        vault.withdraw(b);
        assertEq(token.balanceOf(ALICE), a + alicePaid);
        assertEq(token.balanceOf(BOB), b + bobPaid);
        assertEq(token.balanceOf(address(vault)), funding - alicePaid - bobPaid);
    }

    function testFuzz_claimSplittingPreservesExactlyDivisibleRewards(uint256 rateSeed, uint256 stepSeed) public {
        uint256 rate = bound(rateSeed, 1, 1 ether);
        uint256 steps = bound(stepSeed, 1, 32);
        _giveAndStake(ALICE, 1 ether);
        vault.fundRewards(rate * DURATION);
        uint256 start = vm.getBlockTimestamp();
        uint256 paid;
        for (uint256 i = 1; i <= steps; ++i) {
            uint256 elapsed = DURATION * i / steps;
            vm.warp(start + elapsed);
            vm.prank(ALICE);
            paid += vault.claimRewards();
            assertEq(paid, rate * elapsed, "claim timing cannot change exact time-weighted entitlement");
        }
        assertEq(paid, rate * DURATION);
        assertEq(vault.rewardReserve(), 0);
        assertEq(token.balanceOf(address(vault)), 1 ether);
    }

    function testFuzz_sameTimestampFundingPartitionsHaveSamePayout(uint256 firstSeed, uint256 secondSeed) public {
        uint256 first = bound(firstSeed, 1, SUPPLY / 4);
        uint256 second = bound(secondSeed, 1, SUPPLY / 4);
        _giveAndStake(ALICE, 1);
        vault.fundRewards(first);
        uint256 finish = vault.periodFinish();
        vault.fundRewards(second);
        assertEq(vault.periodFinish(), finish);
        assertEq(vault.earned(ALICE), 0);
        assertEq(vault.rewardReserve(), first + second);
        vm.warp(finish);
        vm.prank(ALICE);
        assertEq(vault.claimRewards(), first + second);
        assertEq(vault.rewardReserve(), 0);
    }

    function _giveAndStake(address account, uint256 amount) private {
        token.transfer(account, amount);
        vm.prank(account);
        vault.stake(amount);
    }

    function _state(address account) private view returns (bytes32) {
        bytes32 custody = keccak256(
            abi.encode(
                token.balanceOf(address(vault)),
                token.balanceOf(account),
                token.balanceOf(address(this)),
                vault.totalStaked(),
                vault.balanceOf(account),
                vault.unlockAt(account),
                vault.depositsPaused()
            )
        );
        bytes32 schedule = keccak256(
            abi.encode(
                vault.periodStart(),
                vault.periodFinish(),
                vault.periodReward(),
                vault.lastUpdateTime(),
                vault.rewardReserve(),
                vault.unallocatedRewards()
            )
        );
        return keccak256(
            abi.encode(
                custody,
                schedule,
                vault.rewardPerTokenStored(),
                vault.rewards(account),
                vault.userRewardPerTokenPaid(account),
                vault.earned(account)
            )
        );
    }
}

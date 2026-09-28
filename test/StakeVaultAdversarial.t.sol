// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StakeVault} from "../src/StakeVault.sol";

/// @dev Deliberately hostile test asset. It is not part of the application deployment.
contract AdversarialToken is ERC20 {
    bool public failIncoming;
    bool public failOutgoing;
    bool public chargeIncomingFee;
    bool public callbackIncoming;
    bool public callbackOutgoing;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;

    constructor() ERC20("Hostile test token", "HOSTILE") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function configureFailures(bool incoming, bool outgoing, bool fee) external {
        failIncoming = incoming;
        failOutgoing = outgoing;
        chargeIncomingFee = fee;
    }

    function configureCallback(address target, bytes calldata data, bool incoming, bool outgoing) external {
        callbackTarget = target;
        callbackData = data;
        callbackIncoming = incoming;
        callbackOutgoing = outgoing;
        callbackSucceeded = false;
        delete callbackResult;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failIncoming) return false;
        if (chargeIncomingFee) {
            _spendAllowance(from, msg.sender, amount);
            _transfer(from, to, amount - 1);
            _burn(from, 1);
        } else {
            super.transferFrom(from, to, amount);
        }
        if (callbackIncoming) _callback();
        return true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failOutgoing) return false;
        super.transfer(to, amount);
        if (callbackOutgoing) _callback();
        return true;
    }

    function _callback() private {
        (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
    }
}

contract ReviewFactory {
    function deploy(address owner) external returns (LaunchToken token, StakeVault vault) {
        token = new LaunchToken{salt: bytes32(uint256(1))}();
        vault = new StakeVault{salt: bytes32(uint256(2))}(address(token), owner, 7 days);
    }

    function attemptPause(StakeVault vault) external {
        vault.setDepositsPaused(true);
    }
}

/// @notice Independent adversarial tests, separate from the implementation's functional suite.
contract StakeVaultAdversarialTest is Test {
    LaunchToken internal token;
    StakeVault internal vault;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant OUTSIDER = address(0xBAD);
    uint256 internal constant DURATION = 7 days;

    function setUp() public {
        vm.warp(1_000_000);
        token = new LaunchToken();
        vault = new StakeVault(address(token), address(this), DURATION);
        token.approve(address(vault), type(uint256).max);
        token.transfer(ALICE, 10_000 ether);
        token.transfer(BOB, 10_000 ether);
        vm.prank(ALICE);
        token.approve(address(vault), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(vault), type(uint256).max);
    }

    function test_Create2FactoryKeepsSupplyAndHasNoImplicitOwnerAuthority() public {
        ReviewFactory factory = new ReviewFactory();
        (LaunchToken launched, StakeVault launchedVault) = factory.deploy(address(this));
        assertEq(launched.balanceOf(address(factory)), 1_000_000_000 ether);
        assertEq(launched.totalSupply(), 1_000_000_000 ether);
        assertEq(launched.balanceOf(address(launchedVault)), 0);
        assertEq(address(launchedVault.token()), address(launched));
        assertEq(launchedVault.owner(), address(this));
        assertEq(launchedVault.lockDuration(), DURATION);
        _assertLaunchRuntime(address(launched));
        _assertLaunchRuntime(address(launchedVault));
        vm.expectRevert(StakeVault.Unauthorized.selector);
        factory.attemptPause(launchedVault);
        launchedVault.setDepositsPaused(true);
        assertTrue(launchedVault.depositsPaused());
    }

    function test_ExpiredIdleRewardsCannotBeSnipedByFirstStaker() public {
        vault.fundRewards(700 ether);
        vm.warp(vm.getBlockTimestamp() + DURATION);
        _stake(ALICE, 100 ether);
        assertEq(vault.earned(ALICE), 0);
        assertEq(vault.unallocatedRewards(), 700 ether);
        vm.prank(ALICE);
        assertEq(vault.claimRewards(), 0);

        vault.fundRewards(70 ether);
        assertEq(vault.periodReward(), 770 ether);
        vm.warp(vm.getBlockTimestamp() + DURATION);
        vm.prank(ALICE);
        assertEq(vault.claimRewards(), 770 ether);
        assertEq(vault.rewardReserve(), 0);
        assertEq(token.balanceOf(address(vault)), vault.totalStaked());
    }

    function test_ZeroStakeGapRecyclesOnlyRewardsReleasedDuringGap() public {
        _stake(ALICE, 100 ether);
        vm.warp(vm.getBlockTimestamp() + DURATION);
        vault.fundRewards(700 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(ALICE);
        vault.withdraw(100 ether);
        assertEq(vault.earned(ALICE), 100 ether);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        _stake(BOB, 100 ether);
        assertEq(vault.unallocatedRewards(), 200 ether);
        assertEq(vault.earned(BOB), 0);

        vault.fundRewards(100 ether);
        assertEq(vault.periodReward(), 700 ether);
        assertEq(vault.unallocatedRewards(), 0);
        vm.warp(vm.getBlockTimestamp() + DURATION);
        vm.prank(ALICE);
        assertEq(vault.claimRewards(), 100 ether);
        vm.prank(BOB);
        assertEq(vault.claimRewards(), 700 ether);
        assertEq(vault.rewardReserve(), 0);
        assertEq(token.balanceOf(address(vault)), 100 ether);
    }

    function test_LastSecondDepositReceivesOnlyLastSecondShare() public {
        _stake(ALICE, 1 ether);
        vault.fundRewards(DURATION * 2 ether);
        uint256 finish = vault.periodFinish();
        vm.warp(finish - 1);
        _stake(BOB, 1 ether);
        assertEq(vault.earned(BOB), 0);
        vm.warp(finish);
        assertEq(vault.earned(BOB), 1 ether);
        assertEq(vault.earned(ALICE), (DURATION * 2 - 1) * 1 ether);
    }

    function testFuzz_StaggeredStakesMatchIndependentTimeShareCalculation(
        uint96 aliceSeed,
        uint96 bobSeed,
        uint96 rewardSeed,
        uint32 elapsedSeed
    ) public {
        uint256 aliceStake = bound(uint256(aliceSeed), 1 ether, 10_000 ether);
        uint256 bobStake = bound(uint256(bobSeed), 1 ether, 10_000 ether);
        uint256 funding = bound(uint256(rewardSeed), 100 ether, 100_000 ether);
        uint256 elapsed = bound(uint256(elapsedSeed), 1, DURATION - 1);
        _stake(ALICE, aliceStake);
        vault.fundRewards(funding);
        uint256 finish = vault.periodFinish();
        vm.warp(vm.getBlockTimestamp() + elapsed);
        _stake(BOB, bobStake);
        vm.warp(finish);

        // This oracle works directly in token units and elapsed seconds, without using vault indices.
        uint256 firstInterval = funding * elapsed / DURATION;
        uint256 secondInterval = funding - firstInterval;
        uint256 expectedAlice = firstInterval + secondInterval * aliceStake / (aliceStake + bobStake);
        uint256 expectedBob = secondInterval * bobStake / (aliceStake + bobStake);
        assertApproxEqAbs(vault.earned(ALICE), expectedAlice, 2);
        assertApproxEqAbs(vault.earned(BOB), expectedBob, 1);

        vm.prank(ALICE);
        uint256 paidAlice = vault.claimRewards();
        vm.prank(BOB);
        uint256 paidBob = vault.claimRewards();
        assertLe(paidAlice + paidBob, funding);
        assertEq(vault.rewardReserve(), funding - paidAlice - paidBob);

        vm.warp(vault.unlockAt(BOB));
        vm.prank(ALICE);
        vault.withdraw(aliceStake);
        vm.prank(BOB);
        vault.withdraw(bobStake);
        assertEq(vault.totalStaked(), 0);
        assertEq(token.balanceOf(ALICE), 10_000 ether + paidAlice);
        assertEq(token.balanceOf(BOB), 10_000 ether + paidBob);
        assertEq(token.balanceOf(address(vault)), vault.rewardReserve());
    }

    function test_OneWeiFundingIsVestedRatherThanDiscardedByRateDivision() public {
        _stake(ALICE, 1 ether);
        vault.fundRewards(1);
        vm.warp(vault.periodFinish() - 1);
        assertEq(vault.earned(ALICE), 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(ALICE);
        assertEq(vault.claimRewards(), 1);
        assertEq(vault.rewardReserve(), 0);
    }

    function test_RoundingDustCannotConsumePrincipalOrBecomeOwnerWithdrawable() public {
        _stake(ALICE, 3);
        vault.fundRewards(1);
        vm.warp(vm.getBlockTimestamp() + DURATION);
        vm.prank(ALICE);
        assertEq(vault.claimRewards(), 0);
        vm.prank(ALICE);
        vault.withdraw(3);
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.rewardReserve(), 1);
        assertEq(token.balanceOf(address(vault)), 1);
        vm.expectRevert(StakeVault.InsufficientStake.selector);
        vault.withdraw(1);
    }

    function test_DonationIsNotClaimableByOwnerOrLateStaker() public {
        token.transfer(address(vault), 500 ether);
        _stake(ALICE, 100 ether);
        vm.warp(vm.getBlockTimestamp() + DURATION);
        assertEq(vault.rewardReserve(), 0);
        assertEq(vault.earned(ALICE), 0);
        assertEq(vault.claimRewards(), 0);
        vm.expectRevert(StakeVault.InsufficientStake.selector);
        vault.withdraw(500 ether);
        vm.prank(ALICE);
        vault.withdraw(100 ether);
        assertEq(token.balanceOf(address(vault)), 500 ether);
    }

    function test_SameBlockDepositAndWithdrawCannotEarnRewardsOrBypassLock() public {
        vault.fundRewards(700 ether);
        _stake(ALICE, 100 ether);
        vm.prank(ALICE);
        assertEq(vault.claimRewards(), 0);
        vm.expectRevert(abi.encodeWithSelector(StakeVault.StakeLocked.selector, vm.getBlockTimestamp() + DURATION));
        vm.prank(ALICE);
        vault.withdraw(100 ether);
        assertEq(vault.balanceOf(ALICE), 100 ether);
    }

    function testFuzz_UnknownSelectorsCannotGiveOwnerPrincipal(uint96 amountSeed) public {
        uint256 amount = bound(uint256(amountSeed), 1, 10_000 ether);
        _stake(ALICE, amount);
        bytes[5] memory attempts = [
            abi.encodeWithSignature("rescueTokens(address,uint256)", address(token), amount),
            abi.encodeWithSignature("withdrawFor(address,uint256)", ALICE, amount),
            abi.encodeWithSignature("emergencyWithdraw()"),
            abi.encodeWithSignature("sweep(address)", address(token)),
            abi.encodeWithSignature("upgradeTo(address)", OUTSIDER)
        ];
        for (uint256 i; i < attempts.length; ++i) {
            (bool succeeded,) = address(vault).call(attempts[i]);
            assertFalse(succeeded);
        }
        assertEq(token.balanceOf(address(vault)), amount);
        assertEq(vault.totalStaked(), amount);
        assertEq(vault.balanceOf(ALICE), amount);
    }

    function test_TopUpPreservesEarnedRewardsButRestartsUnvestedSchedule() public {
        _stake(ALICE, 100 ether);
        vault.fundRewards(700 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 oldFinish = vault.periodFinish();
        assertEq(vault.earned(ALICE), 100 ether);
        vault.fundRewards(100 ether);
        assertEq(vault.earned(ALICE), 100 ether);
        assertEq(vault.periodReward(), 700 ether);
        assertEq(vault.periodFinish(), oldFinish + 1 days);
        vm.prank(ALICE);
        assertEq(vault.claimRewards(), 100 ether);
        vm.warp(vault.periodFinish());
        vm.prank(ALICE);
        assertEq(vault.claimRewards(), 700 ether);
        assertEq(vault.rewardReserve(), 0);
        assertEq(token.balanceOf(address(vault)), vault.totalStaked());
    }

    function test_FailedDepositRollsBackRewardCheckpointAndBalances() public {
        (AdversarialToken hostile, StakeVault target) = _hostileVault();
        target.fundRewards(700 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        hostile.configureFailures(true, false, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(hostile)));
        vm.prank(ALICE);
        target.stake(100 ether);
        assertEq(target.totalStaked(), 0);
        assertEq(target.balanceOf(ALICE), 0);
        assertEq(target.unlockAt(ALICE), 0);
        assertEq(target.lastUpdateTime(), target.periodStart());
        assertEq(target.unallocatedRewards(), 0);
        assertEq(hostile.balanceOf(address(target)), 700 ether);
    }

    function test_FailedFundingDoesNotRescheduleOrIncreaseReserve() public {
        (AdversarialToken hostile, StakeVault target) = _hostileVault();
        target.fundRewards(700 ether);
        uint256 finish = target.periodFinish();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        hostile.configureFailures(true, false, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(hostile)));
        target.fundRewards(100 ether);
        assertEq(target.periodFinish(), finish);
        assertEq(target.periodReward(), 700 ether);
        assertEq(target.rewardReserve(), 700 ether);
        assertEq(target.unallocatedRewards(), 0);
        assertEq(hostile.balanceOf(address(target)), 700 ether);
    }

    function test_IncomingFeeRevertsBothDepositAndFundingWithoutBurningTokens() public {
        (AdversarialToken hostile, StakeVault target) = _hostileVault();
        uint256 initialSupply = hostile.totalSupply();
        uint256 ownerBalance = hostile.balanceOf(address(this));
        hostile.configureFailures(false, false, true);
        vm.expectRevert(StakeVault.UnsupportedToken.selector);
        vm.prank(ALICE);
        target.stake(100 ether);
        vm.expectRevert(StakeVault.UnsupportedToken.selector);
        target.fundRewards(100 ether);
        assertEq(target.totalStaked(), 0);
        assertEq(target.rewardReserve(), 0);
        assertEq(hostile.totalSupply(), initialSupply);
        assertEq(hostile.balanceOf(ALICE), 1_000 ether);
        assertEq(hostile.balanceOf(address(this)), ownerBalance);
        assertEq(hostile.balanceOf(address(target)), 0);
    }

    function test_FailedWithdrawKeepsPrincipalAndUnlockForRetry() public {
        (AdversarialToken hostile, StakeVault target) = _hostileVault();
        vm.prank(ALICE);
        target.stake(100 ether);
        uint256 unlock = target.unlockAt(ALICE);
        vm.warp(unlock);
        hostile.configureFailures(false, true, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(hostile)));
        vm.prank(ALICE);
        target.withdraw(100 ether);
        assertEq(target.totalStaked(), 100 ether);
        assertEq(target.balanceOf(ALICE), 100 ether);
        assertEq(target.unlockAt(ALICE), unlock);
        assertEq(hostile.balanceOf(address(target)), 100 ether);

        hostile.configureFailures(false, false, false);
        vm.prank(ALICE);
        target.withdraw(100 ether);
        assertEq(target.totalStaked(), 0);
        assertEq(hostile.balanceOf(ALICE), 1_000 ether);
    }

    function test_FailedClaimKeepsAccruedRewardAndReserveForRetry() public {
        (AdversarialToken hostile, StakeVault target) = _hostileVault();
        vm.prank(ALICE);
        target.stake(100 ether);
        target.fundRewards(700 ether);
        vm.warp(target.periodFinish());
        hostile.configureFailures(false, true, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(hostile)));
        vm.prank(ALICE);
        target.claimRewards();
        assertEq(target.earned(ALICE), 700 ether);
        assertEq(target.rewardReserve(), 700 ether);
        assertEq(hostile.balanceOf(address(target)), 800 ether);

        hostile.configureFailures(false, false, false);
        vm.prank(ALICE);
        assertEq(target.claimRewards(), 700 ether);
        assertEq(target.rewardReserve(), 0);
        assertEq(hostile.balanceOf(address(target)), 100 ether);
    }

    function test_TransferFromCallbackCannotReenterDeposit() public {
        (AdversarialToken hostile, StakeVault target) = _hostileVault();
        hostile.configureCallback(address(target), abi.encodeCall(StakeVault.stake, (1)), true, false);
        vm.prank(ALICE);
        target.stake(100 ether);
        _assertGuardRejected(hostile);
        assertEq(target.totalStaked(), 100 ether);
        assertEq(target.balanceOf(ALICE), 100 ether);
        assertEq(hostile.balanceOf(address(target)), 100 ether);
    }

    function test_TransferFromCallbackCannotReenterRewardClaimDuringFunding() public {
        (AdversarialToken hostile, StakeVault target) = _hostileVault();
        hostile.configureCallback(address(target), abi.encodeCall(StakeVault.claimRewards, ()), true, false);
        target.fundRewards(700 ether);
        _assertGuardRejected(hostile);
        assertEq(target.rewardReserve(), 700 ether);
        assertEq(hostile.balanceOf(address(target)), 700 ether);
    }

    function test_TransferCallbackCannotReenterWithdrawal() public {
        (AdversarialToken hostile, StakeVault target) = _hostileVault();
        vm.prank(ALICE);
        target.stake(100 ether);
        vm.warp(target.unlockAt(ALICE));
        hostile.configureCallback(address(target), abi.encodeCall(StakeVault.withdraw, (1)), false, true);
        vm.prank(ALICE);
        target.withdraw(100 ether);
        _assertGuardRejected(hostile);
        assertEq(target.totalStaked(), 0);
        assertEq(hostile.balanceOf(address(target)), 0);
        assertEq(hostile.balanceOf(ALICE), 1_000 ether);
    }

    function test_TransferCallbackCannotReenterRewardClaim() public {
        (AdversarialToken hostile, StakeVault target) = _hostileVault();
        vm.prank(ALICE);
        target.stake(100 ether);
        target.fundRewards(700 ether);
        vm.warp(target.periodFinish());
        hostile.configureCallback(address(target), abi.encodeCall(StakeVault.claimRewards, ()), false, true);
        vm.prank(ALICE);
        assertEq(target.claimRewards(), 700 ether);
        _assertGuardRejected(hostile);
        assertEq(target.rewardReserve(), 0);
        assertEq(target.earned(ALICE), 0);
        assertEq(hostile.balanceOf(address(target)), 100 ether);
    }

    function _stake(address account, uint256 amount) private {
        vm.prank(account);
        vault.stake(amount);
    }

    function _hostileVault() private returns (AdversarialToken hostile, StakeVault target) {
        hostile = new AdversarialToken();
        target = new StakeVault(address(hostile), address(this), DURATION);
        hostile.approve(address(target), type(uint256).max);
        hostile.transfer(ALICE, 1_000 ether);
        vm.prank(ALICE);
        hostile.approve(address(target), type(uint256).max);
    }

    function _assertGuardRejected(AdversarialToken hostile) private view {
        assertFalse(hostile.callbackSucceeded());
        assertEq(
            hostile.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
    }

    function _assertLaunchRuntime(address deployed) private view {
        bytes memory runtime = deployed.code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StakeVault} from "../src/StakeVault.sol";

/// @dev Bounded actions succeed or assert a specific expected failure. Unexpected reverts fail the campaign.
contract VaultHandler is Test {
    LaunchToken public immutable token;
    StakeVault public immutable vault;
    address public immutable owner;
    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCAFE)];
    uint256 public totalFunded;
    uint256 public totalPaid;
    uint256 public donations;
    mapping(address => uint256) public deposited;
    mapping(address => uint256) public withdrawn;
    mapping(address => uint256) public claimed;
    mapping(address => uint256) public donated;
    mapping(address => uint256) public expectedUnlockAt;
    bool public expectedPaused;

    constructor(LaunchToken token_, StakeVault vault_, address owner_) {
        token = token_;
        vault = vault_;
        owner = owner_;
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 available = token.balanceOf(actor);
        if (expectedPaused) {
            vm.expectRevert(StakeVault.DepositsPaused.selector);
            vm.prank(actor);
            vault.stake(1);
            return;
        }
        if (available == 0) return;
        amount = _edgeAmount(amount, available);
        vm.prank(actor);
        vault.stake(amount);
        deposited[actor] += amount;
        expectedUnlockAt[actor] = vm.getBlockTimestamp() + 7 days;
        assertEq(token.balanceOf(actor), available - amount, "deposit token debit");
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 available = deposited[actor] - withdrawn[actor];
        if (available == 0) {
            vm.expectRevert(StakeVault.InsufficientStake.selector);
            vm.prank(actor);
            vault.withdraw(1);
            return;
        }
        amount = _edgeAmount(amount, available);
        if (vm.getBlockTimestamp() < expectedUnlockAt[actor]) {
            vm.expectRevert(abi.encodeWithSelector(StakeVault.StakeLocked.selector, expectedUnlockAt[actor]));
            vm.prank(actor);
            vault.withdraw(amount);
            return;
        }
        uint256 beforeBalance = token.balanceOf(actor);
        vm.prank(actor);
        vault.withdraw(amount);
        withdrawn[actor] += amount;
        if (amount == available) expectedUnlockAt[actor] = 0;
        assertEq(token.balanceOf(actor), beforeBalance + amount, "withdrawal token credit");
    }

    function claim(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 beforeBalance = token.balanceOf(actor);
        uint256 quoted = vault.earned(actor);
        vm.prank(actor);
        uint256 amount = vault.claimRewards();
        assertEq(amount, quoted, "claim matches available earnings");
        assertEq(token.balanceOf(actor), beforeBalance + amount, "claim token credit");
        totalPaid += amount;
        claimed[actor] += amount;
        vm.prank(actor);
        assertEq(vault.claimRewards(), 0, "cannot claim twice at the same timestamp");
    }

    function fund(uint256 amount) external {
        uint256 available = token.balanceOf(owner);
        if (available == 0) return;
        amount = _edgeAmount(amount, available);
        vm.prank(owner);
        vault.fundRewards(amount);
        totalFunded += amount;
        assertEq(token.balanceOf(owner), available - amount, "funding token debit");
    }

    function advanceTime(uint256 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1, 14 days));
    }

    function pause(bool paused) external {
        vm.prank(owner);
        vault.setDepositsPaused(paused);
        expectedPaused = paused;
    }

    function donate(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 available = token.balanceOf(actor);
        if (available == 0) return;
        amount = bound(amount, 1, available);
        donations += amount;
        donated[actor] += amount;
        vm.prank(actor);
        token.transfer(address(vault), amount);
    }

    function rejectUnauthorized(uint256 actorSeed, uint256 amount, bool paused) external {
        address actor = actors[actorSeed % actors.length];
        vm.expectRevert(StakeVault.Unauthorized.selector);
        vm.prank(actor);
        vault.fundRewards(amount);
        vm.expectRevert(StakeVault.Unauthorized.selector);
        vm.prank(actor);
        vault.setDepositsPaused(paused);
    }

    function rejectInvalidAmounts(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        vm.expectRevert(expectedPaused ? StakeVault.DepositsPaused.selector : StakeVault.ZeroAmount.selector);
        vm.prank(actor);
        vault.stake(0);
        vm.expectRevert(StakeVault.ZeroAmount.selector);
        vm.prank(actor);
        vault.withdraw(0);
        vm.expectRevert(StakeVault.InsufficientStake.selector);
        vm.prank(actor);
        vault.withdraw(deposited[actor] - withdrawn[actor] + 1);
        vm.expectRevert(StakeVault.ZeroAmount.selector);
        vm.prank(owner);
        vault.fundRewards(0);
    }

    /// @dev Force dust and full-balance actions regularly, alongside arbitrary bounded amounts.
    function _edgeAmount(uint256 seed, uint256 available) private pure returns (uint256) {
        if (seed % 4 == 0) return 1;
        if (seed % 4 == 1) return available;
        return bound(seed, 1, available);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract StakeVaultInvariantTest is StdInvariant, Test {
    uint256 private constant INITIAL_ACTOR_BALANCE = 100_000_000 ether;
    address private constant OWNER = address(0x1234);
    LaunchToken private token;
    StakeVault private vault;
    VaultHandler private handler;

    function setUp() public {
        vm.warp(1_000_000);
        token = new LaunchToken();
        vault = new StakeVault(address(token), OWNER, 7 days);
        handler = new VaultHandler(token, vault, OWNER);
        token.transfer(OWNER, 700_000_000 ether);
        vm.prank(OWNER);
        token.approve(address(vault), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            token.transfer(actor, INITIAL_ACTOR_BALANCE);
            vm.prank(actor);
            token.approve(address(vault), type(uint256).max);
        }
        // Every history begins with custody and a live reward period; random calls can also empty it.
        handler.stake(0, 100 ether + 2);
        handler.stake(1, 200 ether + 2);
        handler.fund(700 ether + 2);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = VaultHandler.stake.selector;
        selectors[1] = VaultHandler.withdraw.selector;
        selectors[2] = VaultHandler.claim.selector;
        selectors[3] = VaultHandler.fund.selector;
        selectors[4] = VaultHandler.advanceTime.selector;
        selectors[5] = VaultHandler.pause.selector;
        selectors[6] = VaultHandler.donate.selector;
        selectors[7] = VaultHandler.rejectUnauthorized.selector;
        selectors[8] = VaultHandler.rejectInvalidAmounts.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_locksAndPauseMatchAuthorizedOperations() public view {
        assertEq(vault.depositsPaused(), handler.expectedPaused());
        assertEq(vault.owner(), OWNER);
        assertEq(address(vault.token()), address(token));
        assertEq(vault.lockDuration(), 7 days);
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            assertEq(vault.unlockAt(actor), handler.expectedUnlockAt(actor), "only a deposit resets the lock");
        }
    }

    function invariant_allTokensRemainInKnownCustody() public view {
        uint256 balances = token.balanceOf(OWNER) + token.balanceOf(address(vault));
        for (uint256 i; i < 3; ++i) {
            balances += token.balanceOf(handler.actors(i));
        }
        assertEq(balances, 1e27);
        assertEq(token.balanceOf(OWNER) + handler.totalFunded(), 700_000_000 ether);
    }

    function invariant_tokenCustodyMatchesPrincipalRewardsAndDonations() public view {
        assertEq(token.balanceOf(address(vault)), vault.totalStaked() + vault.rewardReserve() + handler.donations());
        assertEq(handler.totalFunded(), handler.totalPaid() + vault.rewardReserve());
        assertEq(token.totalSupply(), 1e27);
    }

    function invariant_actorBalancesAndClaimsAreFullyBacked() public view {
        uint256 principal;
        uint256 owed;
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            principal += vault.balanceOf(actor);
            owed += vault.earned(actor);
            assertEq(vault.balanceOf(actor), handler.deposited(actor) - handler.withdrawn(actor));
            assertEq(
                token.balanceOf(actor) + vault.balanceOf(actor) + handler.donated(actor),
                INITIAL_ACTOR_BALANCE + handler.claimed(actor)
            );
        }
        assertEq(principal, vault.totalStaked());
        assertLe(owed + vault.unallocatedRewards(), vault.rewardReserve());
    }

    /// @dev Every generated history must still allow every user to exit with all principal.
    function afterInvariant() public {
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(OWNER);
        vault.setDepositsPaused(true);
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            uint256 principal = handler.deposited(actor) - handler.withdrawn(actor);
            uint256 availableBefore = token.balanceOf(actor);
            vm.prank(actor);
            uint256 reward = vault.claimRewards();
            if (principal != 0) {
                vm.prank(actor);
                vault.withdraw(principal);
            }
            assertEq(token.balanceOf(actor), availableBefore + principal + reward);
            assertEq(vault.balanceOf(actor), 0);
            assertEq(vault.unlockAt(actor), 0);
            assertEq(vault.earned(actor), 0);
        }
        assertEq(vault.totalStaked(), 0);
        assertEq(token.balanceOf(address(vault)), vault.rewardReserve() + handler.donations());
    }
}

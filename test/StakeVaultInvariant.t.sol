// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StakeVault} from "../src/StakeVault.sol";

/// @dev Bounded actions all succeed; unexpected protocol reverts fail the invariant campaign.
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

    constructor(LaunchToken token_, StakeVault vault_, address owner_) {
        token = token_;
        vault = vault_;
        owner = owner_;
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 available = token.balanceOf(actor);
        if (vault.depositsPaused() || available == 0) return;
        amount = bound(amount, 1, available);
        deposited[actor] += amount;
        vm.prank(actor);
        vault.stake(amount);
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 available = vault.balanceOf(actor);
        if (available == 0 || vm.getBlockTimestamp() < vault.unlockAt(actor)) return;
        amount = bound(amount, 1, available);
        withdrawn[actor] += amount;
        vm.prank(actor);
        vault.withdraw(amount);
    }

    function claim(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        uint256 amount = vault.claimRewards();
        totalPaid += amount;
        claimed[actor] += amount;
    }

    function fund(uint256 amount) external {
        uint256 available = token.balanceOf(owner);
        if (available == 0) return;
        amount = bound(amount, 1, available);
        totalFunded += amount;
        vm.prank(owner);
        vault.fundRewards(amount);
    }

    function advanceTime(uint256 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1, 14 days));
    }

    function pause(bool paused) external {
        vm.prank(owner);
        vault.setDepositsPaused(paused);
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
}

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
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = VaultHandler.stake.selector;
        selectors[1] = VaultHandler.withdraw.selector;
        selectors[2] = VaultHandler.claim.selector;
        selectors[3] = VaultHandler.fund.selector;
        selectors[4] = VaultHandler.advanceTime.selector;
        selectors[5] = VaultHandler.pause.selector;
        selectors[6] = VaultHandler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
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
            uint256 principal = vault.balanceOf(actor);
            uint256 availableBefore = token.balanceOf(actor);
            vm.prank(actor);
            uint256 reward = vault.claimRewards();
            if (principal != 0) {
                vm.prank(actor);
                vault.withdraw(principal);
            }
            assertEq(token.balanceOf(actor), availableBefore + principal + reward);
            assertEq(vault.balanceOf(actor), 0);
        }
        assertEq(vault.totalStaked(), 0);
        assertEq(token.balanceOf(address(vault)), vault.rewardReserve() + handler.donations());
    }
}

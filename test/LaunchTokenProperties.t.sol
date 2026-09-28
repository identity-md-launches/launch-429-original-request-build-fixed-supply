// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";

/// @dev An external ledger models balances and approvals from call inputs, including rejected calls.
contract LaunchTokenModelHandler is Test {
    LaunchToken public immutable token;
    address[4] public actors = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(LaunchToken token_) {
        token = token_;
        for (uint256 i; i < actors.length; ++i) {
            expectedBalance[actors[i]] = 1e27 / 4;
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = expectedBalance[from];
        uint256 amount = _amount(amountSeed, balance);
        if (amount > balance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount)
            );
            vm.prank(from);
            token.transfer(to, amount);
            return;
        }
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 amount = amountSeed % 4 == 0 ? type(uint256).max : amountSeed % 4 == 1 ? 0 : amountSeed;
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 toSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address to = actors[toSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 balance = expectedBalance[owner];
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 amount = _amount(amountSeed, balance);
        if (amount > allowance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, amount)
            );
            vm.prank(spender);
            token.transferFrom(owner, to, amount);
            return;
        }
        if (amount > balance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
            );
            vm.prank(spender);
            token.transferFrom(owner, to, amount);
            return;
        }
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        if (allowance != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
    }

    function _amount(uint256 seed, uint256 balance) private pure returns (uint256) {
        uint256 choice = seed % 6;
        if (choice == 0) return 0;
        if (choice == 1) return 1;
        if (choice == 2) return balance;
        if (choice == 3) return balance + 1;
        if (choice == 4) return type(uint256).max;
        return bound(seed, 0, balance);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenPropertiesTest is StdInvariant, Test {
    uint256 private constant SUPPLY = 1e27;
    LaunchToken private token;
    LaunchTokenModelHandler private handler;
    address private alice;
    address private bob;

    function setUp() public {
        token = new LaunchToken();
        handler = new LaunchTokenModelHandler(token);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actors(i), SUPPLY / 4);
        }
        alice = handler.actors(0);
        bob = handler.actors(1);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = LaunchTokenModelHandler.transfer.selector;
        selectors[1] = LaunchTokenModelHandler.approve.selector;
        selectors[2] = LaunchTokenModelHandler.transferFrom.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_balancesMatchLedgerAndSupplyNeverChanges() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor));
            sum += token.balanceOf(actor);
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariant_allowancesMatchApprovalsAndSuccessfulSpending() public view {
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
        }
    }

    function test_failedTransferFromDoesNotConsumeFiniteAllowance() public {
        uint256 tooMuch = SUPPLY / 4 + 1;
        vm.prank(alice);
        token.approve(bob, tooMuch);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, SUPPLY / 4, tooMuch)
        );
        vm.prank(bob);
        token.transferFrom(alice, bob, tooMuch);
        assertEq(token.allowance(alice, bob), tooMuch);
        assertEq(token.balanceOf(alice), SUPPLY / 4);
        assertEq(token.balanceOf(bob), SUPPLY / 4);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approvalReplacementAndRevocationTakeEffectImmediately() public {
        vm.startPrank(alice);
        token.approve(bob, type(uint256).max);
        token.approve(bob, 2);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 2);
        vm.prank(bob);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, bob), 1);
        vm.prank(alice);
        token.approve(bob, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), SUPPLY / 4 - 1);
        assertEq(token.balanceOf(bob), SUPPLY / 4 + 1);
    }

    function test_delegatedSelfTransferConsumesAllowanceButPreservesBalance() public {
        vm.prank(alice);
        token.approve(bob, 7);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, alice, 7));
        assertEq(token.balanceOf(alice), SUPPLY / 4);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransferFromNeedsNoAllowanceAndMovesNothing() public {
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(alice), SUPPLY / 4);
        assertEq(token.balanceOf(bob), SUPPLY / 4);
    }

    function test_zeroReceiverRevertsEvenForZeroTransferFrom() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(bob);
        token.transferFrom(alice, address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transfer(address(0), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_cannotApproveZeroSpenderOrTransferFromZeroSender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(alice);
        token.approve(address(0), 1);
        // transferFrom validates the allowance owner before reaching the transfer's sender check.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(bob);
        token.transferFrom(address(0), bob, 0);
        assertEq(token.allowance(alice, address(0)), 0);
        assertEq(token.balanceOf(bob), SUPPLY / 4);
    }
}

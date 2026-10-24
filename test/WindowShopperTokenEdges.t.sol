// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {WindowShopperToken} from "src/WindowShopperToken.sol";

/// @dev Complements the existing constructor, metadata and launch-flow tests.
/// forge-config: default.fuzz.runs = 1000
contract WindowShopperTokenEdgesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    WindowShopperToken private token;
    address private alice;
    address private bob;
    address private carol;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new WindowShopperToken();
        alice = makeAddr("edge alice");
        bob = makeAddr("edge bob");
        carol = makeAddr("edge carol");
    }

    function test_zeroOneAndFullSupplyTransfersRoundTrip() public {
        uint256[3] memory amounts = [uint256(0), 1, SUPPLY];
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amount = amounts[i];
            vm.expectEmit(true, true, false, true, address(token));
            emit Transfer(address(this), alice, amount);
            assertTrue(token.transfer(alice, amount));
            assertEq(token.balanceOf(alice), amount);
            assertEq(token.balanceOf(address(this)), SUPPLY - amount);
            vm.prank(alice);
            assertTrue(token.transfer(address(this), amount));
            assertEq(token.balanceOf(alice), 0);
            assertEq(token.balanceOf(address(this)), SUPPLY);
            assertEq(token.totalSupply(), SUPPLY);
        }
    }

    function test_zeroOperationsFromEmptyAccountEmitAndKeepState() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, carol, 0);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, 0));

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, address(0), 0);
        vm.prank(alice);
        token.burn(0);

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, address(0), 0);
        vm.prank(bob);
        token.burnFrom(alice, 0);

        _assertState(0, 0, 0, SUPPLY, 0);
    }

    function test_zeroValueDoesNotMakeZeroRecipientOrSpenderValid() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        _assertState(0, 0, 0, SUPPLY, 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(alice, address(0)), 0);
    }

    function test_approveReplacesAllowanceAndCanRevokeInfinity() public {
        vm.startPrank(alice);
        assertTrue(token.approve(bob, type(uint256).max));
        assertTrue(token.approve(carol, 19));
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(alice, bob, 7);
        assertTrue(token.approve(bob, 7));
        assertEq(token.allowance(alice, bob), 7);
        assertTrue(token.approve(bob, 7));
        assertEq(token.allowance(alice, bob), 7, "repeating approval must not add to it");
        assertTrue(token.approve(bob, type(uint256).max));
        assertTrue(token.approve(bob, 0));
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
        _assertState(0, 0, 0, SUPPLY, 0);
        assertEq(token.allowance(alice, carol), 19, "other spender's approval changed");
        assertEq(token.nonces(alice), 0, "approve must not consume a permit nonce");
    }

    function test_selfTransferFromSpendsAllowanceWithoutChangingBalance() public {
        token.transfer(alice, 9);
        vm.prank(alice);
        token.approve(bob, 9);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, alice, 9);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, alice, 9));
        _assertState(9, 0, 0, SUPPLY, 0);
    }

    function test_ownerStillNeedsSelfAllowanceForDelegatedCalls() public {
        token.transfer(alice, 9);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(alice, bob, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.burnFrom(alice, 1);
        token.approve(alice, 9);
        assertTrue(token.transferFrom(alice, bob, 4));
        token.burnFrom(alice, 5);
        vm.stopPrank();
        _assertState(0, 4, 0, SUPPLY - 5, 0);
        assertEq(token.allowance(alice, alice), 0);
    }

    function test_transferFromAndBurnFromShareOneFiniteAllowance() public {
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(bob, 7);
        vm.startPrank(bob);
        assertTrue(token.transferFrom(alice, carol, 3));
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, address(0), 4);
        token.burnFrom(alice, 4);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, carol, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.burnFrom(alice, 1);
        vm.stopPrank();
        _assertState(3, 0, 3, SUPPLY - 4, 0);
    }

    function test_infiniteBurnAllowanceSurvivesRepeatedBurnsAndTransfers() public {
        token.transfer(alice, SUPPLY);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.startPrank(bob);
        token.burnFrom(alice, 1);
        assertTrue(token.transferFrom(alice, carol, 1));
        token.burnFrom(alice, SUPPLY - 2);
        vm.stopPrank();
        _assertState(0, 0, 1, 1, type(uint256).max);
    }

    function test_burningEntireSupplyLeavesAUsableZeroSupplyToken() public {
        token.burn(SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(0)), 0, "burns must not credit the zero address");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        token.transfer(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        token.burn(1);
        assertTrue(token.transfer(alice, 0));
        token.burn(0);
        assertTrue(token.approve(bob, type(uint256).max));
        vm.prank(bob);
        token.burnFrom(address(this), 0);
        assertEq(token.totalSupply(), 0);
        assertEq(token.allowance(address(this), bob), type(uint256).max);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }

    function test_fullSupplyDelegatedBurnAndRepeatedBurnFailure() public {
        token.transfer(alice, SUPPLY);
        vm.prank(alice);
        token.approve(bob, SUPPLY);
        vm.prank(bob);
        token.burnFrom(alice, SUPPLY);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.burnFrom(alice, 1);
        _assertState(0, 0, 0, 0, 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_maximumAmountsCannotWrapBalancesOrSupply() public {
        token.transfer(alice, SUPPLY);
        vm.startPrank(alice);
        token.approve(bob, type(uint256).max);
        bytes memory errorData =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, SUPPLY, type(uint256).max);
        vm.expectRevert(errorData);
        token.transfer(carol, type(uint256).max);
        vm.expectRevert(errorData);
        token.burn(type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        vm.expectRevert(errorData);
        token.transferFrom(alice, carol, type(uint256).max);
        vm.expectRevert(errorData);
        token.burnFrom(alice, type(uint256).max);
        vm.stopPrank();
        _assertState(SUPPLY, 0, 0, SUPPLY, type(uint256).max);
    }

    function testFuzz_failedDelegatedOverdrawRollsBackAllowance(uint256 held, uint256 amount, bool burn) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, held + 1, type(uint256).max);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(bob, amount);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount));
        if (burn) token.burnFrom(alice, amount);
        else token.transferFrom(alice, carol, amount);
        _assertState(held, 0, 0, SUPPLY, amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
    }

    function testFuzz_failedZeroRecipientRestoresSpentAllowance(uint256 amount, bool infinite) public {
        amount = bound(amount, 0, SUPPLY);
        token.transfer(alice, SUPPLY);
        uint256 approved = infinite ? type(uint256).max : amount;
        vm.prank(alice);
        token.approve(bob, approved);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), amount);
        _assertState(SUPPLY, 0, 0, SUPPLY, approved);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function testFuzz_insufficientAllowanceCannotBurnOrTransfer(uint256 approved, uint256 amount, bool burn) public {
        approved = bound(approved, 0, SUPPLY - 1);
        amount = bound(amount, approved + 1, SUPPLY);
        token.transfer(alice, SUPPLY);
        vm.prank(alice);
        token.approve(bob, approved);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, approved, amount));
        if (burn) token.burnFrom(alice, amount);
        else token.transferFrom(alice, carol, amount);
        _assertState(SUPPLY, 0, 0, SUPPLY, approved);
    }

    function testFuzz_allowanceBelongsToSpecificOwnerAndSpender(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY / 2);
        token.transfer(alice, amount);
        token.transfer(carol, amount);
        vm.prank(alice);
        token.approve(bob, amount);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 0, amount));
        token.transferFrom(alice, carol, amount);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, amount));
        token.burnFrom(carol, amount);
        _assertState(amount, 0, amount, SUPPLY, amount);
    }

    function testFuzz_transfersRoundTripWithoutFees(uint256 aliceBalance, uint256 amount) public {
        aliceBalance = bound(aliceBalance, 0, SUPPLY);
        amount = bound(amount, 0, aliceBalance);
        token.transfer(alice, aliceBalance);
        token.transfer(bob, SUPPLY - aliceBalance);
        vm.prank(alice);
        assertTrue(token.transfer(bob, amount));
        assertEq(token.balanceOf(alice), aliceBalance - amount);
        assertEq(token.balanceOf(bob), SUPPLY - aliceBalance + amount);
        vm.prank(bob);
        assertTrue(token.transfer(alice, amount));
        _assertState(aliceBalance, SUPPLY - aliceBalance, 0, SUPPLY, 0);
    }

    function testFuzz_splitAndSingleTransfersAreEquivalent(uint256 total, uint256 first) public {
        total = bound(total, 0, SUPPLY);
        first = bound(first, 0, total);
        WindowShopperToken single = new WindowShopperToken();
        token.transfer(alice, first);
        token.transfer(alice, total - first);
        single.transfer(alice, total);
        assertEq(token.balanceOf(alice), single.balanceOf(alice));
        assertEq(token.balanceOf(address(this)), single.balanceOf(address(this)));
        assertEq(token.totalSupply(), single.totalSupply());
    }

    function _assertState(
        uint256 aliceBalance,
        uint256 bobBalance,
        uint256 carolBalance,
        uint256 supply,
        uint256 approved
    ) private view {
        assertEq(token.balanceOf(alice), aliceBalance);
        assertEq(token.balanceOf(bob), bobBalance);
        assertEq(token.balanceOf(carol), carolBalance);
        assertEq(token.totalSupply(), supply);
        assertEq(token.allowance(alice, bob), approved);
    }
}

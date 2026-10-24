// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {WindowShopperToken} from "src/WindowShopperToken.sol";
import {WindowShopperTokenHandler} from "./handlers/WindowShopperTokenHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract WindowShopperTokenInvariantTest is StdInvariant, Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    uint256 private constant ACTORS = 4;
    WindowShopperTokenHandler private handler;
    WindowShopperToken private token;

    function setUp() public {
        vm.warp(1 days);
        handler = new WindowShopperTokenHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.burn.selector;
        selectors[4] = handler.burnFrom.selector;
        selectors[5] = handler.permit.selector;
        selectors[6] = handler.rejectOverdraw.selector;
        selectors[7] = handler.revokeAndRejectSpending.selector;
        selectors[8] = handler.rejectZeroAddress.selector;
        selectors[9] = handler.rejectPermit.selector;
        selectors[10] = handler.rejectMint.selector;
        selectors[11] = handler.advanceTime.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_supplyEqualsBalancesAndInitialSupplyMinusBurns() public view {
        uint256 sum;
        for (uint256 i; i < ACTORS; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(token.totalSupply(), sum, "supply does not equal all tracked balances");
        assertEq(token.totalSupply() + handler.totalBurned(), SUPPLY, "supply changed outside authorized burns");
        assertEq(token.balanceOf(address(0)), 0, "burned tokens must not become a zero-address balance");
        assertEq(token.balanceOf(address(handler)), 0, "deployer received an unexpected fee or mint");
        assertEq(token.balanceOf(address(token)), 0, "token received an unexpected fee");
    }

    function invariant_balancesMatchAuthorizedMovements() public view {
        for (uint256 i; i < ACTORS; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "unauthorized or inexact balance change");
        }
    }

    function invariant_allowancesAndNoncesMatchAuthorizations() public view {
        for (uint256 i; i < ACTORS; ++i) {
            address owner = handler.actors(i);
            assertEq(token.nonces(owner), handler.expectedNonce(owner), "nonce changed outside a valid permit");
            assertEq(token.allowance(owner, address(0)), 0);
            for (uint256 j; j < ACTORS; ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.expectedAllowance(owner, spender),
                    "approval replacement, spending, or failed-call rollback differs from authorization"
                );
            }
        }
    }

    /// @dev A deterministic reachability check supplements randomized call statistics. No handler
    /// uses assume, catch-and-ignore, early returns for empty balances, or token balance injection.
    function test_handlerExercisesSuccessfulAndRejectedActions() public {
        handler.transfer(0, 1, 11);
        handler.approve(0, 2, 30);
        handler.transferFrom(0, 2, 3, 7);
        handler.burn(1, 3);
        handler.burnFrom(0, 2, 5);
        handler.permit(2, 3, 1); // Infinite approval, then a full-balance self-transfer.
        handler.transferFrom(2, 3, 2, type(uint256).max);
        handler.rejectPermit(2, false);
        handler.rejectPermit(2, true);
        handler.advanceTime(1 days);
        for (uint8 operation; operation < 4; ++operation) {
            handler.rejectOverdraw(2, 3, 2, type(uint256).max, operation);
        }
        for (uint8 operation; operation < 3; ++operation) {
            handler.rejectZeroAddress(2, 3, 1, operation);
        }
        handler.revokeAndRejectSpending(2, 3, 0, false);
        handler.revokeAndRejectSpending(2, 3, 0, true);
        handler.rejectMint(0, SUPPLY, true);
        handler.rejectMint(0, SUPPLY, false);
        invariant_supplyEqualsBalancesAndInitialSupplyMinusBurns();
        invariant_balancesMatchAuthorizedMovements();
        invariant_allowancesAndNoncesMatchAuthorizations();
        assertGt(handler.totalTransferred(), 0);
        assertEq(handler.totalBurned(), 8);
        assertEq(handler.acceptedPermits(), 5);
        assertEq(handler.rejectedCalls(), 13);
    }

    function test_handlerCanReachAndVerifyAnEmptySupply() public {
        for (uint256 i; i < ACTORS; ++i) {
            handler.burn(i, type(uint256).max);
        }
        handler.transfer(0, 1, 1); // Bounded to zero, still a real ERC-20 call.
        handler.burnFrom(0, 1, 1);
        handler.rejectOverdraw(0, 1, 2, 1, 0);
        handler.permit(0, 1, 1);
        handler.rejectMint(0, 1, true);
        invariant_supplyEqualsBalancesAndInitialSupplyMinusBurns();
        invariant_balancesMatchAuthorizedMovements();
        invariant_allowancesAndNoncesMatchAuthorizations();
        assertEq(token.totalSupply(), 0);
        assertEq(handler.totalBurned(), SUPPLY);
    }
}

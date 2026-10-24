// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {WindowShopperToken} from "src/WindowShopperToken.sol";
import {WWWPermitData} from "../helpers/WWWPermitData.sol";

/// @dev Every token holder/recipient is in actors. Only this handler is targeted by the runner.
/// Ghost state comes from the initial allocation and authorized commands, never token getters.
contract WindowShopperTokenHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant ACTOR_COUNT = 4;

    struct Signature {
        address spender;
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    WindowShopperToken public immutable token;
    address[4] public actors;
    uint256[4] private keys;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    mapping(address => uint256) public expectedNonce;
    mapping(address => Signature) private lastUsedPermit;
    uint256 public totalBurned;
    uint256 public totalTransferred;
    uint256 public acceptedPermits;
    uint256 public rejectedCalls;

    constructor() {
        token = new WindowShopperToken();
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY, "constructor must mint to the deploying contract");
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            (actors[i], keys[i]) = makeAddrAndKey(string.concat("WWW invariant actor ", vm.toString(i)));
            assertTrue(token.transfer(actors[i], SUPPLY / ACTOR_COUNT));
            expectedBalance[actors[i]] = SUPPLY / ACTOR_COUNT;
        }
        // Seed useful delegated paths and a consumed signature for each actor. Replay actions
        // therefore always exercise a rejection, including after intervening approvals/spends.
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            _permit(i, actors[(i + 1) % ACTOR_COUNT], SUPPLY / ACTOR_COUNT);
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        totalTransferred += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), _approvalAmount(amountSeed));
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 amount = _amount(amountSeed, _min(expectedBalance[owner], expectedAllowance[owner][spender]));
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        _spend(owner, spender, amount);
        totalTransferred += amount;
    }

    function burn(uint256 ownerSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[owner]);
        vm.prank(owner);
        token.burn(amount);
        expectedBalance[owner] -= amount;
        totalBurned += amount;
    }

    function burnFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = _amount(amountSeed, _min(expectedBalance[owner], expectedAllowance[owner][spender]));
        vm.prank(spender);
        token.burnFrom(owner, amount);
        expectedBalance[owner] -= amount;
        totalBurned += amount;
        _spend(owner, spender, amount);
    }

    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        _permit(ownerSeed % ACTOR_COUNT, _actor(spenderSeed), _approvalAmount(amountSeed));
    }

    /// @dev An overdraw is rejected even for a self-transfer, infinite approval, or empty supply.
    function rejectOverdraw(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed, uint8 operation)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 balance = expectedBalance[owner];
        uint256 amount = bound(amountSeed, balance + 1, type(uint256).max);
        operation %= 4;
        bytes memory errorData =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount);
        if (operation >= 2 && expectedAllowance[owner][spender] < amount) {
            errorData = abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, spender, expectedAllowance[owner][spender], amount
            );
        }
        vm.prank(operation < 2 ? owner : spender);
        vm.expectRevert(errorData);
        if (operation == 0) token.transfer(to, amount);
        else if (operation == 1) token.burn(amount);
        else if (operation == 2) token.transferFrom(owner, to, amount);
        else token.burnFrom(owner, amount);
        ++rejectedCalls;
    }

    function revokeAndRejectSpending(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, bool delegatedBurn)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        _approve(owner, spender, 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        if (delegatedBurn) token.burnFrom(owner, 1);
        else token.transferFrom(owner, to, 1);
        ++rejectedCalls;
    }

    function rejectZeroAddress(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, uint8 operation) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        operation %= 3;
        if (operation == 0) {
            uint256 amount = _amount(amountSeed, expectedBalance[owner]);
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            token.transfer(address(0), amount);
        } else if (operation == 1) {
            uint256 amount = _amount(amountSeed, _min(expectedBalance[owner], expectedAllowance[owner][spender]));
            vm.prank(spender);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            token.transferFrom(owner, address(0), amount);
        } else {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
            token.approve(address(0), amountSeed);
        }
        ++rejectedCalls;
    }

    function rejectPermit(uint256 ownerSeed, bool expired) external {
        uint256 i = ownerSeed % ACTOR_COUNT;
        address owner = actors[i];
        Signature memory signature;
        if (expired) {
            signature = _sign(i, actors[(i + 1) % ACTOR_COUNT], SUPPLY, vm.getBlockTimestamp() - 1);
            vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, signature.deadline));
        } else {
            signature = lastUsedPermit[owner];
            vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        }
        _submit(owner, signature);
        ++rejectedCalls;
    }

    function rejectMint(uint256 recipientSeed, uint256 amountSeed, bool asDeployer) external {
        address recipient = _actor(recipientSeed);
        vm.prank(asDeployer ? address(this) : recipient);
        (bool success,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", recipient, amountSeed));
        assertFalse(success, "no caller may mint after construction");
        ++rejectedCalls;
    }

    function advanceTime(uint256 elapsed) external {
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, 7 days));
    }

    function _approve(address owner, address spender, uint256 value) private {
        vm.prank(owner);
        assertTrue(token.approve(spender, value));
        expectedAllowance[owner][spender] = value;
    }

    function _permit(uint256 i, address spender, uint256 value) private {
        address owner = actors[i];
        Signature memory signature = _sign(i, spender, value, type(uint256).max);
        _submit(owner, signature);
        expectedAllowance[owner][spender] = value;
        ++expectedNonce[owner];
        lastUsedPermit[owner] = signature;
        ++acceptedPermits;
    }

    function _sign(uint256 i, address spender, uint256 value, uint256 deadline)
        private
        view
        returns (Signature memory signature)
    {
        signature.spender = spender;
        signature.value = value;
        signature.deadline = deadline;
        bytes32 digest = WWWPermitData.digest(
            address(token), vm.getChainId(), actors[i], spender, value, expectedNonce[actors[i]], deadline
        );
        (signature.v, signature.r, signature.s) = vm.sign(keys[i], digest);
    }

    function _submit(address owner, Signature memory signature) private {
        token.permit(
            owner, signature.spender, signature.value, signature.deadline, signature.v, signature.r, signature.s
        );
    }

    function _spend(address owner, address spender, uint256 amount) private {
        uint256 approved = expectedAllowance[owner][spender];
        if (approved != type(uint256).max) expectedAllowance[owner][spender] = approved - amount;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }

    function _amount(uint256 seed, uint256 available) private pure returns (uint256) {
        // Pin a full-balance action to MAX, while bound also favors zero, one and near-boundary inputs.
        if (seed == type(uint256).max) return available;
        return bound(seed, 0, available);
    }

    function _approvalAmount(uint256 seed) private pure returns (uint256) {
        // Preserve arbitrary uint256 approvals; also deliberately produce revocations and infinity.
        if (seed % 4 == 0) return 0;
        if (seed % 4 == 1) return type(uint256).max;
        return seed;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

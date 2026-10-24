// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {WindowShopperToken} from "../src/WindowShopperToken.sol";

/// @notice Stands in for the launch factory: deploys the token so that `msg.sender` in the
///         constructor is a contract, exactly as `ProjectFactory.launchCustom` does.
contract FactoryStub {
    WindowShopperToken public token;

    function launch() external returns (WindowShopperToken deployed) {
        deployed = new WindowShopperToken();
        token = deployed;
    }

    function move(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract WindowShopperTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant SWARM_BPS = 1_000;

    FactoryStub internal factory;
    WindowShopperToken internal token;

    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant CLAIMANT = address(0xC1A1);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    uint256 internal constant SIGNER_KEY = 0xA11CE5EC;
    address internal signer;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event SupplyMinted(address indexed deployer, uint256 amount);

    function setUp() public {
        factory = new FactoryStub();
        token = factory.launch();
        signer = vm.addr(SIGNER_KEY);
    }

    // ----------------------------------------------------------------- metadata and supply

    function test_metadata() public view {
        assertEq(token.name(), "IMDwindowshopper");
        assertEq(token.symbol(), "WWW");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "IMDwindowshopper");
        assertEq(token.TOKEN_SYMBOL(), "WWW");
        assertEq(token.DECIMALS(), 18);
    }

    function test_supplyIsOneBillionWith18Decimals() public view {
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.balanceOf(address(factory)), SUPPLY, "deployer does not hold the whole supply");
        assertEq(token.balanceOf(address(this)), 0, "the test harness received tokens");
    }

    function test_constructorEmitsMintEvents() public {
        address deployer = address(0xFAC7);
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), deployer, SUPPLY);
        vm.expectEmit(true, true, true, true);
        emit SupplyMinted(deployer, SUPPLY);
        vm.prank(deployer);
        WindowShopperToken fresh = new WindowShopperToken();
        assertEq(fresh.balanceOf(deployer), SUPPLY);
    }

    function test_eachDeploymentMintsToItsOwnDeployer() public {
        vm.prank(ALICE);
        WindowShopperToken a = new WindowShopperToken();
        vm.prank(BOB);
        WindowShopperToken b = new WindowShopperToken();
        assertEq(a.balanceOf(ALICE), SUPPLY);
        assertEq(a.balanceOf(BOB), 0);
        assertEq(b.balanceOf(BOB), SUPPLY);
        assertEq(b.balanceOf(ALICE), 0);
    }

    // ----------------------------------------------------------------- transfer

    function test_transferMovesExactAmount() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(factory), ALICE, 1 ether);
        assertTrue(factory.move(ALICE, 1 ether));
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.balanceOf(address(factory)), SUPPLY - 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferOfZeroSucceeds() public {
        assertTrue(factory.move(ALICE, 0));
        assertEq(token.balanceOf(ALICE), 0);
    }

    function test_transferRevertsWhenBalanceInsufficient() public {
        factory.move(ALICE, 5 ether);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 5 ether, 5 ether + 1)
        );
        token.transfer(BOB, 5 ether + 1);
    }

    function test_transferRevertsFromEmptyAccount() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.transfer(BOB, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        factory.move(address(0), 1);
    }

    function test_selfTransferKeepsBalance() public {
        factory.move(ALICE, 3 ether);
        vm.prank(ALICE);
        assertTrue(token.transfer(ALICE, 3 ether));
        assertEq(token.balanceOf(ALICE), 3 ether);
    }

    // ----------------------------------------------------------------- approve / transferFrom

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(ALICE, BOB, 7);
        vm.prank(ALICE);
        assertTrue(token.approve(BOB, 7));
        assertEq(token.allowance(ALICE, BOB), 7);
    }

    function test_approveZeroAddressSpenderReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowance() public {
        factory.move(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 4 ether);
        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, CLAIMANT, 3 ether));
        assertEq(token.balanceOf(CLAIMANT), 3 ether);
        assertEq(token.balanceOf(ALICE), 7 ether);
        assertEq(token.allowance(ALICE, BOB), 1 ether);
    }

    function test_transferFromWithInfiniteAllowanceDoesNotDecrease() public {
        factory.move(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(ALICE, CLAIMANT, 3 ether);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        factory.move(ALICE, 10 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(ALICE, BOB, 1);
    }

    function test_transferFromRevertsAboveAllowance() public {
        factory.move(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 2 ether);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 2 ether, 2 ether + 1)
        );
        token.transferFrom(ALICE, BOB, 2 ether + 1);
    }

    function test_transferFromRevertsAboveBalanceEvenWithAllowance() public {
        factory.move(ALICE, 1 ether);
        vm.prank(ALICE);
        token.approve(BOB, 5 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1 ether, 2 ether));
        token.transferFrom(ALICE, BOB, 2 ether);
    }

    // ----------------------------------------------------------------- burn

    function test_burnReducesBalanceAndSupply() public {
        factory.move(ALICE, 10 ether);
        vm.expectEmit(true, true, true, true);
        emit Transfer(ALICE, address(0), 4 ether);
        vm.prank(ALICE);
        token.burn(4 ether);
        assertEq(token.balanceOf(ALICE), 6 ether);
        assertEq(token.totalSupply(), SUPPLY - 4 ether);
    }

    function test_burnRevertsAboveBalance() public {
        factory.move(ALICE, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1 ether, 1 ether + 1)
        );
        token.burn(1 ether + 1);
    }

    function test_burnFromSpendsAllowance() public {
        factory.move(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 3 ether);
        vm.prank(BOB);
        token.burnFrom(ALICE, 2 ether);
        assertEq(token.balanceOf(ALICE), 8 ether);
        assertEq(token.allowance(ALICE, BOB), 1 ether);
        assertEq(token.totalSupply(), SUPPLY - 2 ether);
    }

    function test_burnFromRevertsWithoutAllowance() public {
        factory.move(ALICE, 10 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.burnFrom(ALICE, 1);
        assertEq(token.balanceOf(ALICE), 10 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_deployerCannotBurnAHolderWithoutAllowance() public {
        factory.move(ALICE, 10 ether);
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1)
        );
        token.burnFrom(ALICE, 1);
    }

    // ----------------------------------------------------------------- permit (EIP-2612)

    function _permitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function test_permitSetsAllowanceAndBumpsNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(signer, BOB, 5 ether, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);

        vm.expectEmit(true, true, true, true);
        emit Approval(signer, BOB, 5 ether);
        vm.prank(address(0xCA11E7));
        token.permit(signer, BOB, 5 ether, deadline, v, r, s);

        assertEq(token.allowance(signer, BOB), 5 ether);
        assertEq(token.nonces(signer), 1);
    }

    function test_permitThenTransferFrom() public {
        factory.move(signer, 10 ether);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, _permitDigest(signer, BOB, 5 ether, 0, deadline));
        token.permit(signer, BOB, 5 ether, deadline, v, r, s);
        vm.prank(BOB);
        token.transferFrom(signer, CLAIMANT, 5 ether);
        assertEq(token.balanceOf(CLAIMANT), 5 ether);
        assertEq(token.balanceOf(signer), 5 ether);
    }

    function test_permitRevertsWhenExpired() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, _permitDigest(signer, BOB, 5 ether, 0, deadline));
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(signer, BOB, 5 ether, deadline, v, r, s);
    }

    function test_permitRevertsForWrongSigner() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 otherKey = 0xBADBAD;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherKey, _permitDigest(signer, BOB, 5 ether, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(otherKey), signer));
        token.permit(signer, BOB, 5 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, BOB), 0);
    }

    function test_permitCannotBeReplayed() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, _permitDigest(signer, BOB, 5 ether, 0, deadline));
        token.permit(signer, BOB, 5 ether, deadline, v, r, s);
        vm.expectRevert();
        token.permit(signer, BOB, 5 ether, deadline, v, r, s);
        assertEq(token.nonces(signer), 1);
    }

    function test_permitRevertsForTamperedValue() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, _permitDigest(signer, BOB, 5 ether, 0, deadline));
        vm.expectRevert();
        token.permit(signer, BOB, 6 ether, deadline, v, r, s);
    }

    // ----------------------------------------------------------------- launch floor

    /// @dev The swarm's ten percent leaves the deployer whole and is claimable whole.
    function test_launchFlowsMoveExactAmounts() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        assertTrue(factory.move(DISTRIBUTOR, swarm));
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm));
        assertEq(token.balanceOf(CLAIMANT), swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Neither a stranger nor the deployer can reach any way of growing the supply.
    function test_noCallIncreasesSupply() public {
        address attacker = address(0xBEEF);
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(address(factory));
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    /// @dev No privileged call moves or freezes a holder: there is none to call.
    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        factory.move(ALICE, SUPPLY / 1_000);
        uint256 held = token.balanceOf(ALICE);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, true);
            vm.prank(address(factory));
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        vm.prank(address(factory));
        (bool moved,) = address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, ALICE, factory, 1));
        assertFalse(moved);
        assertEq(token.balanceOf(ALICE), held);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, held / 2));
        assertEq(token.balanceOf(BOB), held / 2);
    }

    function test_tokenHasNoReceiveOrFallback() public {
        (bool ok,) = address(token).call{value: 0}("");
        assertFalse(ok, "empty calldata should revert");
        (ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok, "unknown selector should revert");
        vm.deal(address(this), 1 ether);
        (ok,) = address(token).call{value: 1}("");
        assertFalse(ok, "token should not accept ETH");
    }

    function test_runtimeFitsEIP170() public view {
        assertGt(address(token).code.length, 0);
        assertLe(address(token).code.length, 24_576);
    }

    /// @dev Mirrors the launch floor's opcode walk: no DELEGATECALL, CALLCODE or SELFDESTRUCT is
    ///      reachable in the runtime (push data is skipped; unreachable bytes after a terminator
    ///      are data until the next JUMPDEST).
    function test_runtimeCodeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        bool reachable = true;
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "runtime code contains DELEGATECALL");
                assertTrue(op != 0xF2, "runtime code contains CALLCODE");
                assertTrue(op != 0xFF, "runtime code contains SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    // ----------------------------------------------------------------- fuzz

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(factory));
        amount = bound(amount, 0, SUPPLY);
        assertTrue(factory.move(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(address(factory)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, SUPPLY);
        factory.move(ALICE, held);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, held, amount));
        token.transfer(BOB, amount);
    }

    function testFuzz_allowanceBoundsTransferFrom(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        factory.move(ALICE, SUPPLY);
        vm.prank(ALICE);
        token.approve(BOB, allowance);
        vm.prank(BOB);
        if (amount > allowance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, allowance, amount)
            );
            token.transferFrom(ALICE, CLAIMANT, amount);
        } else {
            assertTrue(token.transferFrom(ALICE, CLAIMANT, amount));
            assertEq(token.balanceOf(CLAIMANT), amount);
            assertEq(token.allowance(ALICE, BOB), allowance - amount);
        }
    }

    function testFuzz_burnOnlyShrinksSupply(uint256 held, uint256 burned) public {
        held = bound(held, 0, SUPPLY);
        burned = bound(burned, 0, held);
        factory.move(ALICE, held);
        vm.prank(ALICE);
        token.burn(burned);
        assertEq(token.balanceOf(ALICE), held - burned);
        assertEq(token.totalSupply(), SUPPLY - burned);
        assertLe(token.totalSupply(), SUPPLY);
    }
}

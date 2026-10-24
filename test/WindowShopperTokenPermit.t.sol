// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {WindowShopperToken} from "src/WindowShopperToken.sol";
import {WWWPermitData} from "./helpers/WWWPermitData.sol";

/// forge-config: default.fuzz.runs = 1000
contract WindowShopperTokenPermitTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    uint256 private constant HELD = SUPPLY / 4;
    uint256 private constant CURVE_ORDER = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;

    struct SignedPermit {
        address owner;
        address spender;
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    WindowShopperToken private token;
    address private owner;
    uint256 private ownerKey;
    address private spender;
    address private recipient;
    address private relayer;

    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new WindowShopperToken();
        (owner, ownerKey) = makeAddrAndKey("permit test owner");
        spender = makeAddr("permit test spender");
        recipient = makeAddr("permit test recipient");
        relayer = makeAddr("permit test relayer");
        token.transfer(owner, HELD);
        // Invalid signatures must preserve an existing approval, not merely leave a zero slot untouched.
        vm.prank(owner);
        token.approve(spender, 17);
    }

    function test_domainMatchesTheClientEncodingAndDiscoveryFields() public view {
        assertEq(token.DOMAIN_SEPARATOR(), WWWPermitData.domain(address(token), block.chainid));
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = token.eip712Domain();
        assertEq(uint8(fields), 0x0f);
        assertEq(name, "IMDwindowshopper");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(token));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    function test_permitIsValidAtTheExactDeadlineAndAnyRelayerMaySubmit() public {
        SignedPermit memory permit = _sign(23, 0, vm.getBlockTimestamp());
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(owner, spender, 23);
        vm.prank(relayer);
        _submit(permit);
        assertEq(token.allowance(owner, spender), 23);
        assertEq(token.nonces(owner), 1);
        assertEq(token.nonces(relayer), 0);
        assertEq(token.balanceOf(owner), HELD);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_permitExpiresOneSecondAfterDeadlineWithoutConsumingNonce() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        SignedPermit memory permit = _sign(23, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        _submit(permit);
        _assertOriginalState();
        _submit(_sign(23, 0, deadline + 1));
        assertEq(token.nonces(owner), 1, "a rejected signature consumed its nonce");
        assertEq(token.allowance(owner, spender), 23);
    }

    function test_maximumDeadlineAndAllowanceThenSignedRevocation() public {
        _submit(_sign(type(uint256).max, 0, type(uint256).max));
        vm.startPrank(spender);
        assertTrue(token.transferFrom(owner, recipient, 1));
        token.burnFrom(owner, 1);
        vm.stopPrank();
        assertEq(token.allowance(owner, spender), type(uint256).max);
        _submit(_sign(0, 1, type(uint256).max));
        assertEq(token.nonces(owner), 2);
        assertEq(token.allowance(owner, spender), 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.burnFrom(owner, 1);
        assertEq(token.balanceOf(owner), HELD - 2);
        assertEq(token.balanceOf(recipient), 1);
        assertEq(token.totalSupply(), SUPPLY - 1);
    }

    function test_replayCannotRestoreASpentOrRevokedApproval() public {
        SignedPermit memory permit = _sign(23, 0, type(uint256).max);
        _submit(permit);
        vm.prank(spender);
        token.transferFrom(owner, recipient, 23);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submit(permit);
        assertEq(token.allowance(owner, spender), 0);
        assertEq(token.nonces(owner), 1);
        assertEq(token.balanceOf(recipient), 23);

        permit = _sign(29, 1, type(uint256).max);
        _submit(permit);
        vm.prank(owner);
        token.approve(spender, 0);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submit(permit);
        assertEq(token.allowance(owner, spender), 0);
        assertEq(token.nonces(owner), 2);
        assertEq(token.balanceOf(owner), HELD - 23);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_futureNonceRejectsUntilThePreviousPermitIsUsed() public {
        SignedPermit memory first = _sign(23, 0, type(uint256).max);
        SignedPermit memory second = _sign(29, 1, type(uint256).max);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submit(second);
        _assertOriginalState();
        _submit(first);
        _submit(second);
        assertEq(token.nonces(owner), 2);
        assertEq(token.allowance(owner, spender), 29);
    }

    function test_signatureIsBoundToItsTokenDeployment() public {
        SignedPermit memory permit = _sign(23, 0, type(uint256).max);
        WindowShopperToken other = new WindowShopperToken();
        assertNotEq(other.DOMAIN_SEPARATOR(), token.DOMAIN_SEPARATOR());
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        other.permit(permit.owner, permit.spender, permit.value, permit.deadline, permit.v, permit.r, permit.s);
        assertEq(other.nonces(owner), 0);
        assertEq(other.allowance(owner, spender), 0);
        assertEq(other.totalSupply(), SUPPLY);
        _assertOriginalState();
        _submit(permit);
        assertEq(token.allowance(owner, spender), 23);
        assertEq(token.nonces(owner), 1);
    }

    function test_chainChangeInvalidatesOldDomainAndAcceptsNewDomain() public {
        uint256 oldChain = vm.getChainId();
        uint256 newChain = oldChain ^ 1;
        SignedPermit memory permit = _sign(23, 0, type(uint256).max);
        bytes32 oldDomain = token.DOMAIN_SEPARATOR();
        vm.chainId(newChain);
        assertNotEq(token.DOMAIN_SEPARATOR(), oldDomain);
        assertEq(token.DOMAIN_SEPARATOR(), WWWPermitData.domain(address(token), newChain));
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submit(permit);
        _assertOriginalState();
        _submit(_sign(29, 0, type(uint256).max));
        assertEq(token.allowance(owner, spender), 29);
        assertEq(token.nonces(owner), 1);
        vm.chainId(oldChain);
        assertEq(token.DOMAIN_SEPARATOR(), oldDomain);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submit(permit);
        assertEq(token.nonces(owner), 1, "chain changes must not reset nonces");
        assertEq(token.allowance(owner, spender), 29);
    }

    function test_permitToZeroSpenderRollsBackItsNonce() public {
        SignedPermit memory permit = _signFor(owner, address(0), 23, 0, type(uint256).max, ownerKey);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        _submit(permit);
        _assertOriginalState();
        assertEq(token.allowance(owner, address(0)), 0);
        _submit(_sign(23, 0, type(uint256).max));
        assertEq(token.nonces(owner), 1);
    }

    function test_zeroOwnerCannotBeAuthorizedByAnEmptySignature() public {
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(address(0), spender, 23, type(uint256).max, 27, bytes32(0), bytes32(0));
        assertEq(token.nonces(address(0)), 0);
        assertEq(token.allowance(address(0), spender), 0);
        _assertOriginalState();
    }

    function test_zeroSignatureRejectsAndPreservesExistingApproval() public {
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(owner, spender, 23, type(uint256).max, 27, bytes32(0), bytes32(0));
        _assertOriginalState();
    }

    function test_malleableHighSRejectsButCanonicalSignatureStillWorks() public {
        SignedPermit memory permit = _sign(23, 0, type(uint256).max);
        bytes32 highS = bytes32(CURVE_ORDER - uint256(permit.s));
        uint8 flippedV = permit.v == 27 ? 28 : 27;
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        token.permit(owner, spender, 23, permit.deadline, flippedV, permit.r, highS);
        _assertOriginalState();
        _submit(permit);
        assertEq(token.allowance(owner, spender), 23);
        assertEq(token.nonces(owner), 1);
    }

    function test_noncesAndApprovalsAreIndependentAcrossOwnersAndSpenders() public {
        (address secondOwner, uint256 secondKey) = makeAddrAndKey("permit second owner");
        _submit(_sign(23, 0, type(uint256).max));
        _submit(_signFor(owner, recipient, 29, 1, type(uint256).max, ownerKey));
        assertEq(token.nonces(secondOwner), 0);
        _submit(_signFor(secondOwner, spender, 31, 0, type(uint256).max, secondKey));
        assertEq(token.nonces(owner), 2);
        assertEq(token.nonces(secondOwner), 1);
        assertEq(token.allowance(owner, spender), 23);
        assertEq(token.allowance(owner, recipient), 29);
        assertEq(token.allowance(secondOwner, spender), 31);
        assertEq(token.allowance(secondOwner, recipient), 0);
        assertEq(token.balanceOf(owner), HELD);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_permitCannotBeUsedWithTamperedFields(uint256 value, uint8 changedField) public {
        SignedPermit memory permit = _sign(value, 0, vm.getBlockTimestamp() + 1 days);
        changedField %= 4;
        if (changedField == 0) permit.owner = recipient;
        else if (changedField == 1) permit.spender = recipient;
        else if (changedField == 2) permit.value ^= 1;
        else permit.deadline ^= 1;
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submit(permit);
        _assertOriginalState();
        assertEq(token.nonces(recipient), 0);
        assertEq(token.allowance(owner, recipient), 0);
        assertEq(token.allowance(recipient, spender), 0);
    }

    function testFuzz_invalidVRejectsWithoutStateChanges(uint8 v) public {
        if (v == 27 || v == 28) v = 29;
        SignedPermit memory permit = _sign(23, 0, type(uint256).max);
        permit.v = v;
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        _submit(permit);
        _assertOriginalState();
    }

    function testFuzz_permitFundsTransferAndBurnWithinOneAllowance(uint256 approved, uint256 moved, uint256 burned)
        public
    {
        uint256 available = approved < HELD ? approved : HELD;
        moved = bound(moved, 0, available);
        burned = bound(burned, 0, available - moved);
        SignedPermit memory permit = _sign(approved, 0, type(uint256).max);
        vm.prank(relayer);
        _submit(permit);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(owner, recipient, moved));
        token.burnFrom(owner, burned);
        vm.stopPrank();
        assertEq(token.balanceOf(owner), HELD - moved - burned);
        assertEq(token.balanceOf(recipient), moved);
        assertEq(token.balanceOf(address(this)), SUPPLY - HELD);
        assertEq(token.totalSupply(), SUPPLY - burned);
        assertEq(token.nonces(owner), 1);
        assertEq(token.nonces(spender), 0);
        assertEq(token.allowance(owner, spender), approved == type(uint256).max ? approved : approved - moved - burned);
    }

    function _sign(uint256 value, uint256 nonce, uint256 deadline) private view returns (SignedPermit memory) {
        return _signFor(owner, spender, value, nonce, deadline, ownerKey);
    }

    function _signFor(
        address signingOwner,
        address approvedSpender,
        uint256 value,
        uint256 nonce,
        uint256 deadline,
        uint256 key
    ) private view returns (SignedPermit memory permit) {
        permit.owner = signingOwner;
        permit.spender = approvedSpender;
        permit.value = value;
        permit.deadline = deadline;
        (permit.v, permit.r, permit.s) = vm.sign(
            key,
            WWWPermitData.digest(address(token), vm.getChainId(), signingOwner, approvedSpender, value, nonce, deadline)
        );
    }

    function _submit(SignedPermit memory permit) private {
        token.permit(permit.owner, permit.spender, permit.value, permit.deadline, permit.v, permit.r, permit.s);
    }

    function _assertOriginalState() private view {
        assertEq(token.allowance(owner, spender), 17);
        assertEq(token.nonces(owner), 0);
        assertEq(token.balanceOf(owner), HELD);
        assertEq(token.balanceOf(address(this)), SUPPLY - HELD);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title IMDwindowshopper (WWW)
/// @notice A fixed-supply ERC-20. The whole supply is minted once, in the constructor, to the
///         deployer (`msg.sender`). Nothing can mint afterwards: there is no owner, no minter role,
///         no pause, no blocklist, no fee and no upgrade path. Holders may burn their own tokens
///         (or tokens they were given an allowance for) through {ERC20Burnable}, and may approve
///         spenders by signature through {ERC20Permit} (EIP-2612).
/// @dev The contract identifier is deliberately short (the launch manifest records it as 32 bytes);
///      the token's long name and symbol are returned by `name()` and `symbol()`.
///      Community link: X (x.com/windowshoppermd).
contract WindowShopperToken is ERC20, ERC20Burnable, ERC20Permit {
    /// @notice The token name returned by `name()` and used as the EIP-712 domain name.
    string public constant TOKEN_NAME = "IMDwindowshopper";

    /// @notice The token symbol returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "WWW";

    /// @notice The token's decimals (the ERC-20 default, restated for the manifest).
    uint8 public constant DECIMALS = 18;

    /// @notice The whole supply in minor units: 1,000,000,000 tokens with 18 decimals.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** DECIMALS;

    /// @notice Emitted once, when the constructor mints the supply to the deployer.
    event SupplyMinted(address indexed deployer, uint256 amount);

    /// @notice Mints {INITIAL_SUPPLY} to `msg.sender` (the launch factory) exactly once.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) ERC20Permit(TOKEN_NAME) {
        _mint(msg.sender, INITIAL_SUPPLY);
        emit SupplyMinted(msg.sender, INITIAL_SUPPLY);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}

# IMDwindowshopper (WWW)

A fixed-supply ERC-20 for the IMD custom-token launch on Ethereum mainnet (chain id 1).

| Setting | Value |
| --- | --- |
| Solidity contract | `WindowShopperToken` (`src/WindowShopperToken.sol`) |
| Name | `IMDwindowshopper` |
| Symbol | `WWW` |
| Decimals | 18 |
| Total supply | 1,000,000,000 WWW = `1000000000000000000000000000` minor units |
| Constructor arguments | none |
| Owner / admin | none (the contract has no privileged role) |
| Community | X: x.com/windowshoppermd |

## What the token does

The whole supply is minted once, in the constructor, to `msg.sender`. On the launch that is the
IMD `ProjectFactory`, which pays the supply out (10% to the swarm's MerkleDistributor, 60% to the
Uniswap v4 pool, 30% to the requester's remainder address). After that the token is a plain,
unowned ERC-20:

- **Transfers** are untaxed and unrestricted. Every launch flow (factory to distributor, distributor
  to claimant, factory to pool manager, trader to and from the pool) moves exactly the amount asked.
- **No further minting.** There is no `mint`, no minter role, no owner and no upgrade path. The
  supply can only shrink.
- **Burning** (`burn`, `burnFrom` from OpenZeppelin's `ERC20Burnable`) lets a holder destroy their
  own tokens, or tokens they hold an allowance for. Nobody can burn a holder's balance without
  that holder's approval.
- **Permit** (`permit`, EIP-2612, from OpenZeppelin's `ERC20Permit`) lets a holder approve a spender
  by signature. The EIP-712 domain name is `IMDwindowshopper`, version `1`.
- **No pause, blocklist, freeze, seize, fee, reflection or `selfdestruct`.** There is no `receive`
  or `fallback`, so the contract does not accept ETH.

## Assumptions

- The deployer of the constructor is the launch factory, and the factory alone distributes the
  supply. The contract never names the factory, the pool manager or the distributor because it
  exempts nothing: it has no transfer rules to exempt from.
- Decimals are fixed at 18 and the supply at exactly one billion tokens; both are compile-time
  constants (`DECIMALS`, `INITIAL_SUPPLY`) and the manifest must state the same values.
- OpenZeppelin Contracts v5.4.0 is vendored as ordinary files under `lib/openzeppelin-contracts`
  (ERC-20, utils and interfaces only). forge-std v1.11.0 is vendored under `lib/forge-std`. Neither
  is a git submodule. Every library function used is `internal`, so the bytecode has no link
  placeholders.
- The brief leaves no number open: name, symbol, supply and decimals are all given. The only
  chosen value is the EIP-712 domain version string, `"1"` (OpenZeppelin's convention).

## Deployment parameters

The launch is performed by IMD's deployer through the factory; this repository does not deploy,
broadcast or hold keys. The values the manifest step will record:

- Chain: Ethereum, chain id 1.
- Token contract: `WindowShopperToken`, no constructor arguments, `totalSupply`
  `1000000000000000000000000000`, decimals 18.
- Application contracts: none.
- Pool: paired with IMD (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), fee 12500 (1.25%),
  tick spacing 60, initial price `79228162514264337593543950336` (provenance only; the deployer
  derives the opening price from the market cap).
- Economics (the requester's, copied verbatim): `poolBps` 6000, `initialMarketCapWei`
  `1000000000000000000000` (1,000 IMD for the whole supply), `remainderTo`
  `0x3ed212257958724579f13b3dba74a07ac6007903`.

`launch.json` is written by the manifest step after acceptance, not by this repository.

For a local or review deployment, `script/DeployWindowShopperToken.s.sol` exposes `deploy()`,
which takes no configuration and is what the tests call. `run()` wraps it in a broadcast:

```sh
forge script script/DeployWindowShopperToken.s.sol --rpc-url <RPC> --broadcast
```

Whoever broadcasts receives the whole supply.

## After launch

Nothing to configure. The token has no owner and no settable values.

## Operational responsibilities

- **Holders** are responsible for their own keys and approvals. `permit` signatures should carry a
  short deadline; an infinite allowance (`type(uint256).max`) is never decremented.
- **The requester** receives 30% of the supply at `remainderTo` and is responsible for that
  wallet. Burning from it is irreversible.
- **IMD's deployer** performs the launch, verifies source on the explorer and seeds the pool. Those
  steps are outside this repository.
- **Security review.** The tests here are not an audit. The contract is three OpenZeppelin v5.4.0
  mixins and a constructor, with no custom transfer logic, which keeps the attack surface to the
  library's. A separate adversarial review by an independent contributor is still expected before
  release, as the launch policy requires.

## Building and testing

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `bytecode_hash = "none"` and `cbor_metadata = false` so the
built bytes are reproducible, and pins the fuzz seed the verifier uses. `ffi` is off and no
filesystem permissions are granted. Tests read no environment variables and pass in any order and
in parallel.

The test suite (`test/WindowShopperToken.t.sol`, `test/DeployWindowShopperToken.t.sol`) covers:

- metadata, supply and the one-time mint to the deployer (a contract, as the factory is);
- transfer, approve, transferFrom, burn, burnFrom and permit, each with success and failure cases
  (insufficient balance or allowance, zero address, expired, wrong signer, replay, tampered value);
- the launch floor: exact launch flows, no call grows the supply, no privileged call moves or
  freezes a holder, no `receive`/`fallback`, runtime under EIP-170, and an opcode walk showing no
  reachable `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`;
- fuzzed conservation of supply, balance and allowance bounds, and burn monotonicity.

Tools run for this delivery: `forge build`, `forge test` (with the verifier's fuzz seed and an
empty environment) and `forge fmt --check`. Slither and Mythril were not available on the build
machine; the source avoids the patterns the verifier's Slither detectors reject.

## Layout

```
foundry.toml                      compiler and profile pins
remappings.txt                    forge-std and @openzeppelin/contracts
src/WindowShopperToken.sol        the token
script/DeployWindowShopperToken.s.sol  local deploy helper (no env, no config)
test/                             Foundry tests
lib/forge-std                     vendored forge-std v1.11.0
lib/openzeppelin-contracts        vendored OpenZeppelin Contracts v5.4.0 (ERC20, utils, interfaces)
```

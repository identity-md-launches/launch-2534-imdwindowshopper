# WWW token test coverage

The original constructor, metadata, deployment and launch-flow tests remain in place.
The additional suites exercise the accepted `WindowShopperToken` directly using the
repository's vendored Foundry and OpenZeppelin libraries. No RPC, environment reads,
FFI, storage overrides or downloaded dependencies are needed.

| Suite | Properties exercised |
| --- | --- |
| `WindowShopperTokenEdges.t.sol` | Zero, one, full supply and maximum amounts; exact transfer round trips; split-transfer equivalence; approval replacement, revocation and isolation; self-transfers; shared transfer/burn allowances; infinite approvals; complete supply destruction; rollback on insufficient balance, insufficient allowance and invalid recipients. |
| `WindowShopperTokenPermit.t.sol` | Independently encoded EIP-712 domain; deadline equality and expiry; signed revocation; nonce ordering and isolation; replay after spending/revocation; deployment and chain separation; tampered fields; malformed and malleable signatures; zero owner/spender; transfer and burn after a permit. |
| `WindowShopperTokenInvariant.t.sol` | Supply conservation, exact balances, approvals and nonces after randomized successful and rejected calls, with deterministic checks that exercise every handler action and the empty-supply state. |

The two additional property-test suites use 1,000 runs per fuzz test. Invariants use
256 runs at depth 128, configured inline so project configuration need not change.
Unexpected handler reverts fail the invariant campaign.

## Invariant model

`handlers/WindowShopperTokenHandler.sol` deploys the real token as a contract and
distributes its entire supply among four actors. Initial permits give every actor
a usable delegated-spending path and a consumed signature to attempt replaying.
All successful transfers remain within this actor set; the token and deployer
must retain zero balances after distribution.

The handler interleaves transfers, approvals, delegated transfers, burns, delegated
burns, permits, revocations, overdraws, invalid addresses, expired/replayed permits,
mint attempts and time advancement. Actor selection and amounts are bounded without
discarding fuzz cases. Callers, spenders and recipients may coincide. Full-balance,
zero-value, finite-allowance and infinite-allowance paths are reachable.

An independent ledger starts from the specified supply and changes only according
to successful authorized commands. It never copies balances, allowances or nonces
from the token. After each handler action the runner checks:

- the sum of actor balances equals `totalSupply()`;
- `totalSupply() + cumulative successful burns == 1_000_000_000 ether`;
- every actor's balance matches its authorized movements;
- every owner/spender allowance matches approvals and authorized consumption;
- nonces count only accepted permits, and zero-address approvals/balances remain zero.

Burns are part of the accepted implementation, so remaining supply decreases only
by recorded burns. Failed operations leave the ledger unchanged. Expected reverts
are checked explicitly; unexpected errors are never caught and ignored. Time is
advanced with a cheatcode, with no real-time waits.

The supplied Pashov fizz and Trail of Bits references informed conservation,
state-transition, round-trip and failure-path selection. The handler and tests are
written for this token; they do not depend on the supplied reference files.

## Local verification

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
FOUNDRY_FUZZ_SEED=0x17da02b275eeda7d18fe81471f6f72f18446ff59d2368eafbf83721503b23d25 \
  forge test --out test/scratch/out --cache-path test/scratch/cache
```

The output/cache flags keep local build artifacts in disposable scratch space.
Ordinary `forge build` and `forge test` use the same submitted tests. Scratch files
are not imported by any delivered test.

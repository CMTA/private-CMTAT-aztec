# CHANGELOG

Please follow [https://changelog.md/](https://changelog.md/) conventions.

> **This code has not been audited.** It is a prototype of a private CMTAT on Aztec, published for review and experimentation, and it is not fit for production use with real assets.

## Semantic Version 2.0.0

Given a version number MAJOR.MINOR.PATCH, increment the:

1. MAJOR version when the new version makes:
   - An incompatible change to contract **storage** — the `#[storage] struct Storage` layout, a state-variable type (`PublicMutable` / `SharedMutable` / `PrivateSet`), or the shape of a note (`UintNote`) or a packed struct (`UserFlags`, `FreezableFlag`, `CreditEventsStruct`, `DebtBaseStruct`)
   - A significant change in external APIs (`#[public]` / `#[private]` / `#[utility]` functions, their arguments, or the numeric role constants) or in the internal architecture
   - A change to the Aztec/`aztec-nr` version that alters the contract class ID or breaks previously generated artifacts
2. MINOR version when the new version adds functionality in a backward compatible manner
3. PATCH version when the new version makes backward compatible bug fixes

See [https://semver.org](https://semver.org)

> **No upgradeability.** Unlike the Solidity CMTAT, this contract cannot be upgraded behind a proxy: any MAJOR change means deploying a new contract and migrating holders. Private balances live as notes in each user's PXE, so a migration is not a storage copy — plan it as part of the release.

## Type of changes

- `Summary`: main new features/change with a description (keep it short) (not a changelog tag)
- `Added` for new features.
- `Changed` for changes in existing functionality.
- `Deprecated` for soon-to-be removed features.
- `Removed` for now removed features.
- `Fixed` for any bug fixes.
- `Security` in case of vulnerabilities.

Reference: [keepachangelog.com/en/1.1.0/](https://keepachangelog.com/en/1.1.0/)

Custom changelog tag: `Dependencies`, `Documentation`, `Testing`

## Entry style

- One line per bullet or paragraph — never hard-wrap prose. Markdown renders a wrapped bullet identically, but a one-word edit reflows every following line and buries the real change in diff noise. Keep line structure only where it is semantic: fenced code blocks, tables, blockquotes.
- Past roughly three sentences, split a bullet into a lead sentence naming what changed plus one sub-bullet per distinct claim — impact, fix, behaviour-change warning, migration note. Sub-bullets are one line each too.

## Checklist

> Before a new release, perform the following tasks

- Pin one Aztec version, and check that it is the same in all three places: the `tag = "vX.Y.Z"` entries in [Nargo.toml](./Nargo.toml), the `@aztec/*` versions in [package.json](./package.json), and the `aztec-up X.Y.Z` instruction in [README.md](./README.md)
- Rebuild artifacts from a clean tree, so the release is not validated against a stale `src/artifacts/`

```bash
yarn clean
yarn compile
yarn codegen
```

- Run the formatter over the Noir sources and type-check the TypeScript

```bash
aztec-nargo fmt          # or: nargo fmt
npx tsc --noEmit
```

- Run both test profiles — neither one covers the other

```bash
yarn test:nr             # Noir/TXE unit tests in src/test/
yarn test:js             # Jest e2e tests in src/test/e2e/, requires: aztec start --sandbox
```

- Documentation
  - Update [README.md](./README.md) whenever the specification changes: the assumptions, the per-operation privacy requirements, the module descriptions, and the limitations list
  - Update the agent guide, and keep [CLAUDE.md](./CLAUDE.md) and [AGENTS.md](./AGENTS.md) byte-for-byte identical (`diff CLAUDE.md AGENTS.md` must be empty)
  - Check that no Markdown file mixes hard-wrapped and one-line-per-block prose
  - Update this changelog

## Unreleased

Target: **0.3**. Not released yet; everything below is on the development branch.

### Summary

- Upgraded from Aztec 0.63.1 to **5.2.0**, which is a rewrite of every file rather than a version bump: the framework renamed its function and state-variable macros, moved contract state behind `self`, replaced note delivery, and replaced the PXE-centric TypeScript API with a Wallet-centric one.
- Restructured the contract into module structs, added testnet deployment scripts, and moved private balances onto the framework's own `BalanceSet`.

### Changed

- Contract functions use the `#[external("private" | "public" | "utility")]` macros instead of `#[private]` / `#[public]` / `#[utility]`, and contract state is reached through `self.storage` instead of a free `storage` binding.
- Private-to-public calls go through `self.enqueue_self`, private-to-private helpers through `self.internal`, and the enqueued public halves (`_mint`, `_transfer`, `_burn`) are now `#[external("public")] #[only_self]`.
- Authwit validation on `transfer`, `transfer_batch`, `burn` and `burn_batch` is now the `#[authorize_once("from", "authwit_nonce")]` macro instead of a hand-written `assert_current_call_valid_authwit` call.
  - The `_nonce` parameter is renamed `authwit_nonce`, and the caller must pass `0` when acting for themselves - a non-zero nonce from the `from` account is now rejected.
  - The macro also adds replay protection, which the previous hand-written check left to the caller.
- `SharedMutable` became `DelayedPublicMutable`, and its delay is a **duration in seconds** rather than a number of blocks.
  - `CHANGE_ROLES_DELAY_BLOCKS = 2` is now `CHANGE_ROLES_DELAY_SECONDS = 360` in the contract and in the enforcement and validation modules.
  - This affects operators: freezing an account, blacklisting an address and changing the issuer now take six minutes rather than two blocks.
- Private balances moved from a hand-written `BalanceSet` over `Map<AztecAddress, ...>` to `Owned<BalanceSet>` from the `balance_set` aztec-nr library, accessed as `private_balances.at(address)`.
- Module structs implement `StateVariable<N, Context>` (which now owns both `new` and `get_storage_slot`) instead of the old `Storage<N>` trait, and take `PublicContext` by value rather than `&mut PublicContext`.
- `burn_batch` now debits a single `from` account rather than one holder per array entry.
  - The old signature validated one authwit per entry, which `#[authorize_once]` cannot express: it authorizes exactly one `from`.
  - At the current `MAX_ADDR_PER_CALL` of 1 this is the same operation; it only narrows what a larger batch could do.
- The TypeScript layer is built on `EmbeddedWallet` from `@aztec/wallets`, which owns its own PXE, rather than constructing a PXE service and deriving a wallet per account.
  - Every `send()` and `simulate()` now names its sender with `from`, so one contract handle serves all accounts instead of one handle per wallet.
  - `TxStatus.SUCCESS` is gone; `TxStatus` now tracks finalization, and execution success is `receipt.hasExecutionSucceeded()`.
  - `deriveSigningKey` is gone; accounts rebuilt from `.env` now derive their signing key with `deriveMasterMessageSigningSecretKey`. Both this and address computation changed, so the addresses recorded in `.env.example` no longer correspond to its SECRET/SALT pairs.

### Added

- Testnet deployment and interaction scripts under [scripts/](./scripts): `deploy_contract.ts`, `deploy_account.ts`, `interaction.ts`, `multiple_pxe.ts`, `get_block.ts`, `fees.ts`, `profile_deploy.ts`.
- TypeScript helpers under [src/utils/](./src/utils) for wallet setup (sandbox and testnet), Schnorr account deployment, account recreation from `.env`, and the sponsored FPC fee-payment method.
- CMTAT extension modules: credit events (`flagDefault`, `flagRedeemed`, `rating`) and debt base (interest rate, par value, maturity date, day-count and business-day conventions), each guarded by its own role.
- `cancel_authwit`, which pushes the authwit nullifier so a granted authentication witness can be revoked before use.
- Agent guide files [CLAUDE.md](./CLAUDE.md) and [AGENTS.md](./AGENTS.md), and this changelog.

### Removed

- `src/types/balance_set.nr`, superseded by the `balance_set` library. The file is left in the tree but is no longer part of the module graph and should be deleted.
- The `value_note` and `authwit` entries in `Nargo.toml`: `value_note` was never used, and `authwit` is now part of the `aztec` library (`aztec::authwit`).
- The reference FPC's private and public fee-payment demonstrations in `scripts/fees.ts`. `FeeJuicePaymentMethod` no longer exists (an account holding Fee Juice pays with it automatically), and `PrivateFeePaymentMethod` / `PublicFeePaymentMethod` are deprecated and do not work beyond a local network.

### Security

- The issuer's copy of every note is now delivered **offchain** rather than onchain, which weakens the auditability guarantee.
  - The framework documents an onchain constrained copy to an auditor as the supported pattern, and the contract compiles that way, but PXE cannot process an onchain note message addressed to someone who is not the note's owner: note discovery computes the note's nullifier, which requires the owner's nullifier key.
  - The consequence is that the issuer's copy has no onchain data availability: the issuer must capture these messages as they are produced, and a sender who drops one is not detectable onchain.
  - The delivery mode is a one-line change in each of `_mint_internal`, `_transfer_internal` and `_burn_internal`, should a later Aztec version process non-owner note messages.

### Dependencies

- Aztec and `aztec-nr` upgraded from `aztec-packages-v0.63.1` to **v5.2.0**, and the libraries now come from the standalone `AztecProtocol/aztec-nr` repository rather than a directory inside `aztec-packages`.
- Added the `balance_set` library; dropped `value_note` and the separate `authwit` library.
- `@aztec/aztec.js`, `@aztec/accounts`, `@aztec/builder`, `@aztec/noir-contracts.js`, `@aztec/kv-store` and `@aztec/pxe` pinned to 5.2.0, and `@aztec/wallets` added.
- Noir compiler is now 1.0.0-beta.25, shipped with the 5.2.0 toolchain.

### Testing

- The Noir test suite is rewritten against the current `TestEnvironment` API: `create_light_account` / `create_contract_account`, `deploy(...).with_public_initializer(...)`, and `call_private` / `call_public` / `view_public` / `view_private` / `execute_utility` taking an explicit sender, in place of `impersonate` and `.call(&mut env.private())`.
- Tests that act on someone else's behalf grant the caller access to the owner's notes with `call_private_opts(..., CallPrivateOptions::new().with_additional_scopes([owner]))`, since spending a note needs the owner's secrets even when an authwit authorizes the call.
- Tests that depend on a scheduled value change advance the chain past the delay with `advance_next_block_timestamp_by` plus `mine_block`, rather than mining a fixed number of blocks.
- The end-to-end suite waits out the real `CHANGE_ROLES_DELAY_SECONDS` once after deployment, because a sandbox's timestamps cannot be fast-forwarded and every mint, transfer and burn reads the issuer address.

### Documentation

- README updated for the renamed state variables, the per-call protocol limits (now 8 private calls and 16 private logs, up from 4 and 4), the `aztec-up install 5.2.0` instruction, and the delivery mode of the issuer's note copy.

## 0.2 — 2025-02-20

### Summary

- Documentation and licensing release. No contract changes: the token code is the same as 0.1, still built on Aztec 0.63.1.

### Documentation

- Rewrote the README: functionality overview, assumptions and requirements, storage description, per-operation (mint/transfer/burn) specifications, module design notes, and the limitations list.
- Added the security policy in [SECURITY.md](./SECURITY.md).

### Changed

- Dual-licensed the project under MIT and MPL-2.0, © 2025 Taurus SA — see [LICENSE-MIT.md](./LICENSE-MIT.md) and [LICENSE-MPL.md](./LICENSE-MPL.md).

## 0.1 — 2025-01-13

### Summary

- First public release: a fully featured private CMTAT prototype on Aztec, built on Aztec 0.63.1.
- Aztec had no public testnet at the time, so this release runs on the local sandbox only.
- Not audited, and not guaranteed to be compliant with Swiss law.

### Added

- Private mint, transfer and burn of a CMTAT security token, with balances held as encrypted notes in each user's PXE.
- Public `totalSupply`, updated by the public half of each mint and burn.
- Issuer auditability: every note written for a user is also emitted to the issuer, so the issuer can reconstruct balances and transfers.
- Role-based access control in public state, with an admin role that grants and revokes the operational roles.
- Public pause of the contract and public freeze of individual accounts.
- Transfer restriction through a validation module holding blacklist and whitelist flags.
- Authentication witness support on transfer, the equivalent of `transferFrom`; mint and burn are restricted to the issuer and take no authwit.

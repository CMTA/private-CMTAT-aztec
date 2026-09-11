# CHANGELOG

Please follow [https://changelog.md/](https://changelog.md/) conventions.

> **This code has not been audited.** It is a prototype of a private CMTAT on Aztec, published for review and experimentation, and it is not fit for production use with real assets.

## Semantic Version 2.0.0

Given a version number MAJOR.MINOR.PATCH, increment the:

1. MAJOR version when the new version makes:
   - An incompatible change to contract **storage** — the `#[storage] struct Storage` layout, a state-variable type (`PublicMutable` / `DelayedPublicMutable` / `Owned<BalanceSet>`), or the shape of a note (`UintNote`) or a packed struct (`UserFlags`, `FreezableFlag`, `Terms`, `CreditEventsStruct`, `DebtInformation`)
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

- Code: update `VERSION` in [src/main.nr](./src/main.nr), and check the mirrors — the `Implementation version` row of `doc/cmtat-assessment/README.md`, and the version named in any release tag.
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
yarn typecheck           # never `npx tsc`: it can resolve to the Aztec toolchain's own compiler
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

- Mint and burn now follow CMTAT Solidity's lifecycle and screening rules: they continue through a pause, stop at deactivation, and their target is screened against the enabled list.
  - CMTAT's `_canMintBurnByModule` checks deactivation and the freeze flag, never `paused()`, and its allowlist variant screens the recipient of a mint and the account of a burn. Previously this token blocked mint and burn during a pause and did not apply the lists to either — the first a documented deviation, the second a gap the `mint` NatSpec had claimed was closed.
  - `_mint` and `_burn` now assert `!is_deactivated()` in their enqueued public half; `_transfer` still asserts `!is_paused()`. The validation module gained `operateOnMint(to)` and `operateOnBurn(account)`, called from `_mint_internal` and `_burn_internal`.
  - Measured cost: +6,200 gates on `mint` (30,776 → 36,976) and +6,199 on `burn` (81,736 → 87,935) for the two list reads. `transfer` and the Light variant, which has no validation module, are unchanged.
  - BREAKING CHANGE (behaviour): an issuer can now mint into and redeem from a paused token, and a blacklisted or non-whitelisted address can no longer be minted to or burned from. Seven tests changed or were added to pin both directions; each was confirmed to fail against the previous behaviour.
- `terms`, `get_credit_events`, `get_debt` and `only_role` are now `#[view]`, and those three getters plus `total_supply` return `-> pub`, matching every other read-only entry point.
  - `#[view]` is an enforced guarantee rather than a hint, and its absence mattered most on the getters other contracts call: without it a caller composing against them could not rely on their being side-effect-free.
  - The evidence that this was drift rather than intent is that `get_operations` — the same shape of function, in the same file — already had it.
  - The tests for those getters now call `view_public` instead of `call_public`, which is both the correct call for a read and a compile-time guard: `view_public` does not type-check against a non-view function, so the attribute cannot be dropped silently.
  - `only_role` had no test caller at all, so two were added to pin its attribute and confirm it still reverts for a non-holder through a static call.
- Dropped `downlevelIteration` from [tsconfig.json](./tsconfig.json). The option only affects ES5/ES3 emit and the project targets `es2020`, so it was already inert; TypeScript 6 reports it as deprecated.
- Contract functions use the `#[external("private" | "public" | "utility")]` macros instead of `#[private]` / `#[public]` / `#[utility]`, and contract state is reached through `self.storage` instead of a free `storage` binding.
- Private-to-public calls go through `self.enqueue_self`, private-to-private helpers through `self.internal`, and the enqueued public halves (`_mint`, `_transfer`, `_burn`) are now `#[external("public")] #[only_self]`.
- Authwit validation on `transfer`, `transfer_batch`, `burn` and `burn_batch` is now the `#[authorize_once("from", "authwit_nonce")]` macro instead of a hand-written `assert_current_call_valid_authwit` call.
  - The `_nonce` parameter is renamed `authwit_nonce`, and the caller must pass `0` when acting for themselves - a non-zero nonce from the `from` account is now rejected.
  - The macro also adds replay protection, which the previous hand-written check left to the caller.
- `SharedMutable` became `DelayedPublicMutable`, and its delay is a **duration in seconds** rather than a number of blocks.
  - `CHANGE_ROLES_DELAY_BLOCKS = 2` is now `CHANGE_ROLES_DELAY_SECONDS = 360` in the contract and in the enforcement and validation modules.
  - This affects operators: freezing an account and blacklisting an address now take six minutes rather than two blocks, and a freshly deployed contract cannot mint, transfer or burn until the delay has elapsed, because all three read the issuer address the constructor scheduled.
- Private balances moved from a hand-written `BalanceSet` over `Map<AztecAddress, ...>` to `Owned<BalanceSet>` from the `balance_set` aztec-nr library, accessed as `private_balances.at(address)`.
- Module structs implement `StateVariable<N, Context>` (which now owns both `new` and `get_storage_slot`) instead of the old `Storage<N>` trait, and take `PublicContext` by value rather than `&mut PublicContext`.
- `burn_batch` now debits a single `from` account rather than one holder per array entry.
  - The old signature validated one authwit per entry, which `#[authorize_once]` cannot express: it authorizes exactly one `from`.
  - At the current `MAX_ADDR_PER_CALL` of 1 this is the same operation; it only narrows what a larger batch could do.
- The TypeScript layer is built on `EmbeddedWallet` from `@aztec/wallets`, which owns its own PXE, rather than constructing a PXE service and deriving a wallet per account.
  - Every `send()` and `simulate()` now names its sender with `from`, so one contract handle serves all accounts instead of one handle per wallet.
  - `TxStatus.SUCCESS` is gone; `TxStatus` now tracks finalization, and execution success is `receipt.hasExecutionSucceeded()`.
  - `deriveSigningKey` is gone; accounts rebuilt from `.env` now derive their signing key with `deriveMasterMessageSigningSecretKey`. Both this and address computation changed, so the addresses recorded in `.env.example` no longer correspond to its SECRET/SALT pairs.
- `transfer_batch` now emits one `Transfer` event per recipient, as `transfer` already did.
  - The two paths move tokens identically — at a batch of one they are the same operation — but only one of them left a trail, so anything built on the event silently missed every batched transfer.
  - Delivered in the same mode as the single path (`onchain_unconstrained()` to the recipient), so the two remain consistent; whether that is the right mode at all is a separate open question recorded in the analysis report.
  - Costs 1,687 gates and one private log per recipient. That matters because the batch cap is set by the per-call log budget: the full suite was re-run at the cap of 4 to confirm the extra logs still fit.
- `MAX_ADDR_PER_CALL` raised from 1 to **4**, so `mint_batch`, `transfer_batch` and `burn_batch` act on up to four addresses.
  - The ceiling was measured rather than derived: at 5 the batched mint and burn finish with a wrong total supply, and at 6 and above `transfer_batch` aborts with `push out of bounds`. Everything passes at 4.
  - `transfer` is what sets the cap for all three, because it creates two notes and two constrained deliveries per recipient where mint and burn create one.
  - The previous comment blamed the 8-nested-private-call limit. That was never the constraint: the `_*_internal` helpers are inlined, so a batch makes no nested private calls at any cap.
  - The issuer address is now read once per call and passed into the helpers, instead of once per address. That saves 5,748 gates in each batch function at the new cap and leaves the single-entry paths unchanged.
  - Batching does not make the circuit cheaper: a four-recipient transfer is 447,303 gates against 119,145 for a single transfer, and the user's own device produces that proof. What it saves is the fixed per-transaction overhead that four separate transfers would pay four times.
  - BREAKING CHANGE: the array lengths in `mint_batch`, `transfer_batch` and `burn_batch` are part of the ABI, so callers passing one-element arrays must now pass four.
- `burn` and `burn_batch` name their target `account`, not `from`, following the CMTAT Solidity burn module.
  - CMTAT Solidity uses `account` for `burn` and `mint` and reserves `from`/`to` for transfers, where there really are two parties. A burn has one.
  - This is what produced the frozen-holder message bug fixed below: `from` implied a counterparty, and the assertion copied from the mint module named the one a burn does not have.
  - The authwit macro takes the parameter by name, so it is now `#[authorize_once("account", "authwit_nonce")]`.
  - BREAKING CHANGE: the generated TypeScript signature becomes `burn(account, amount, authwit_nonce)`. Arguments are positional, so existing calls behave identically, but any caller using the generated named types must be updated. `mint` still names its target `to`; aligning it with CMTAT would be a second ABI change and has not been made.

### Added

- Public events on every remaining state-changing entry point: `Paused`, `Unpaused`, `RoleRevoked` (from both `revoke_role` and `renounce_role`), `AddressFrozen` (from both `freeze` and `unfreeze`, with an `is_frozen` flag), `AddressListed` (from both `add_to_list` and `remove_from_list`) and `OperationsSet`.
  - Names follow the reference where one exists: the pause and role events are the OpenZeppelin ones CMTAT Solidity inherits, `AddressFrozen` is CMTAT's own. With these, every operation that changes contract state leaves a trail; previously `grant_role` emitted and `revoke_role` did not, `deactivate_contract` emitted and `pause_contract` did not.
  - The three events for delayed flags carry `effective_at`, the timestamp from which the scheduled value is current — exactly what the state variable records, so an indexer need not know the contract's delay to know when a freeze or a listing takes effect.
  - The README no longer describes events as future work, and the assessment's Conclusion no longer says batching is capped at one address.
- `NewRole` is now emitted for the roles the constructor grants, which were previously the only silent grants in the contract's life.
  - An indexer built on `NewRole` saw every later grant and missed the founding ones, so the role table it reconstructed was wrong rather than obviously incomplete.
  - Every grant now goes through one inlined `_grant_role_internal` helper that writes and emits together, so the two cannot be separated again. It is `#[internal("public")]`, so it costs no call and no gas, and it replaces what would otherwise be nine copies of the emit across the three variants.
  - `AccessControlModule` gained `only_role_admin`, the check half of its `grant_role`, so the contract can authorise and then write-and-emit while the authorisation logic stays in the library.
  - Added `test_access_control.nr`: the deny path of `grant_role` had no test at all, so the change above had nothing guarding it.
- Realigned the debt module with the current CMTAT Solidity `ICMTATDebt` interface, adding the five attributes it had gained.
  - `DebtBaseStruct`, a flat struct of twelve attributes, is replaced by `DebtInformation { debtIdentifier, debtInstrument }`, mirroring the Solidity structs field for field and in their order.
  - New attributes: `issuerName` and `issuerDescription` on the identifier, and `minimumDenomination`, `currency` and `currencyContract` on the instrument. The last three close equivalency criteria 52 and 54, which the assessment recorded as absent.
  - `currencyContract` is an `AztecAddress`, so it can only name a contract on this chain; a payment currency on another ledger has to be identified through the `currency` string.
  - Removed `publicHolidaysCalendar`, which the CMTAT interface no longer carries.
  - Renamed to match Solidity: `bondHolder` is now `debtHolder`, and `couponFrequency` is now `couponPaymentFrequency`.
  - BREAKING CHANGE: the record grows from twelve fields to sixteen, so the module's storage span changes and every state variable declared after it moves. `set_debt_base(DebtBaseStruct)` and `get_debt_base()` are renamed `set_debt(DebtInformation)` and `get_debt()`, the getter now returns `[Field; 16]`, and the module file moves from `debtBaseModule.nr` to `debtModule.nr`. A deployed token cannot be migrated in place.
- `set_debt_instrument`, which updates the instrument's terms and leaves the debt identifier untouched.
  - Mirrors the Solidity `setDebtInstrument`, added alongside `setDebt` for the common case where a coupon schedule changes but the guarantor and debtholder representative do not.
  - Without it, changing one term meant re-supplying the identifier as well, and a caller that forgot silently blanked it.
- Public events on the debt entry points: `DebtLogEvent`, `DebtInstrumentLogEvent` and `CreditEventsLogEvent`.
  - CMTAT Solidity emits these with no payload to keep the contract small. These carry the caller instead, matching the existing `NewRole` and `Deactivated` events; the values themselves stay readable through `get_debt()` and `get_credit_events()`.
- `deactivate_contract` and `public_get_deactivated`, implementing the CMTAT permanent-deactivation feature (equivalency criteria 17 and 18).
  - Modelled on CMTAT Solidity's `PauseModule`: the caller needs the admin role, the contract must already be paused, and a second call is refused.
  - `unpause_contract` now refuses to run once the flag is set, which is what makes the deactivation permanent — the flag itself is never cleared.
  - `_transfer` stops on a deactivated contract through its not-paused assertion, since deactivation requires a pause and blocks unpause forever. `_mint` and `_burn` carry an explicit not-deactivated assertion instead, because — as in CMTAT Solidity — they are permitted while merely paused. (Earlier in this release all three asserted not-paused; see the *Changed* entry on mint and burn semantics.)
  - Emits a new `Deactivated` public event carrying the caller.
  - BREAKING CHANGE: `PauseModule` now occupies two storage slots instead of one, so every state variable declared after it moves. A deployed token cannot be migrated in place.
- Split into three deployment variants over a shared module library, as a Nargo workspace.
  - `CMTATAztecLight`, `CMTATAztec` and `CMTATAztecDebt` are separate contract packages in `contracts/`; every module moved to `lib/` (`cmtat_aztec_lib`, `type = "lib"`).
  - Noir has no inheritance and allows one contract per package, so a variant is a separate package composing a different subset of modules, not a subclass. An entry point added to a shared module must be declared in each variant's `main.nr` that should expose it.
  - Credit events and debt base are now carried only by `CMTATAztecDebt`; the validation module only by `CMTATAztec` and `CMTATAztecDebt`.
  - Measured artifact sizes are 6.25 MB (Light), 6.46 MB (base) and 6.50 MB (Debt), so dropping modules saves about 4% — the bulk is the private circuits for mint, transfer and burn, which every variant carries. The split is about deploying only what an issuance needs, not about size.
  - BREAKING CHANGE: the contract is renamed from `CMTAToken` to `CMTATAztec`, so its class ID, its generated TypeScript (`src/artifacts/CMTATAztec.ts`) and every deployment reference change. `yarn compile` and `yarn test:nr` now run across the workspace.
- `set_token_id` and `token_id`, the CMTAT token identifier (equivalency criterion 5), in all three variants.
  - Lives on the same extra-information module as the terms, guarded by `EXTRA_INFORMATION_ROLE`, and follows CMTAT Solidity in writing the value even when it equals the current one.
  - A `PublicMutable<FieldCompressedString>`, so it is settable after deployment as in Solidity, and capped at 31 characters — enough for an ISIN.
  - Completes criterion 50 (unique identifier / hash), which needs `tokenId` alongside the terms document hash.
  - BREAKING CHANGE: the extra-information module now occupies six storage slots instead of five, so every state variable declared after it moves.
- `version()`, returning the implementation version as a compile-time constant (equivalency criterion 6).
  - Follows the CMTAT Solidity `VersionModule`: a constant of the code, not stored state, so it cannot be desynchronised from the deployed contract and changes only through a new deployment.
  - Aztec's contract class ID already identifies the deployed artifact, but it is a hash: it does not order releases and does not correspond to a release tag, so it does not answer the same question.
  - The value lives in `VERSION` in `src/main.nr` and MUST be bumped with every release; the pre-release checklist below carries that step.
- `set_terms` and `terms`, carrying the reference to the legally required documentation (equivalency criterion 2), in a new `extraInformationModule`.
  - Uses the CMTAT Solidity notation: the setter takes a `DocumentInfo` of `{name, uri, documentHash}` and `terms()` returns the equivalent of `CMTATTerms`, with `lastModified` stamped by the contract from the block timestamp so a caller cannot forge it.
  - `name` and `uri` are `FieldCompressedString` and are therefore capped at 31 characters each.
  - The `bytes32` document hash is stored as two `u128` halves, because a Noir `Field` holds ~254 bits and a 256-bit digest does not fit in one. Split the digest high-16-bytes / low-16-bytes and reassemble it the same way.
  - Adds `EXTRA_INFORMATION_ROLE = 11`, matching the role CMTAT Solidity uses for `setTerms`.
  - BREAKING CHANGE: adds a storage field, so every state variable declared after it moves.
- Testnet deployment and interaction scripts under [scripts/](./scripts): `deploy_contract.ts`, `deploy_account.ts`, `interaction.ts`, `multiple_pxe.ts`, `get_block.ts`, `fees.ts`, `profile_deploy.ts`.
- TypeScript helpers under [src/utils/](./src/utils) for wallet setup (sandbox and testnet), Schnorr account deployment, account recreation from `.env`, and the sponsored FPC fee-payment method.
- CMTAT extension modules: credit events (`flagDefault`, `flagRedeemed`, `rating`) and debt base (interest rate, par value, maturity date, day-count and business-day conventions), each guarded by its own role.
- `cancel_authwit`, which pushes the authwit nullifier so a granted authentication witness can be revoked before use.
- Agent guide files [CLAUDE.md](./CLAUDE.md) and [AGENTS.md](./AGENTS.md), and this changelog.

- `yarn typecheck`, a script that type-checks the TypeScript with the compiler pinned in `package.json`.
  - The pre-release checklist said `npx tsc --noEmit`, which is not reproducible: the Aztec toolchain ships its own `tsc` under `~/.aztec/current/node_modules/.bin/`, and on a machine where that directory precedes `./node_modules/.bin` on `PATH` the checklist type-checks the project with the toolchain's compiler instead of the pinned one.
  - Observed with toolchain 5.2.0, which bundles TypeScript 6.0.3 against the project's 5.5.x pin: the release check failed on a deprecation warning the project's own compiler does not emit.
  - A `yarn` or `npm` script prepends `./node_modules/.bin` to `PATH`, so the pinned compiler wins regardless of what else is installed. The checklist now calls the script.
- A `Terms` event on `set_terms`, which previously wrote the terms with no observable trail while its sibling `set_token_id` emitted one.
  - Follows the CMTAT Solidity `event Terms(CMTATTerms newTerm)`, which publishes the whole stored terms: the document name, its URI, the two halves of the content hash, and the `lastModified` the contract stamped.
  - That is deliberately unlike the debt events added in this release, which carry only the caller because their Solidity counterparts are payload-free.
  - `set_terms` now reads the block timestamp into a local and passes it to both the write and the event, so the two cannot disagree.

### Fixed

- `yarn compile` produced artifacts that `yarn codegen` could not consume.
  - The script called `aztec-nargo compile`, and at Aztec 5.2.0 `aztec-nargo` is a bare symlink to `nargo`: it compiles Noir but does not run the AVM transpiler, so codegen aborted with `Contract's public bytecode has not been transpiled`.
  - It went unnoticed because `aztec test` transpiles as a side effect, so anyone running the tests between compiling and generating never saw it. The pre-release checklist in this file is the one path that does not — it rebuilds from a clean tree without a test run.
  - The script is now `aztec compile --workspace`, and the environment override is renamed from `AZTEC_NARGO` to `AZTEC_COMPILE` because it names the `aztec` CLI rather than the nargo binary.
- `burn_batch` reported a frozen holder as `Frozen: Recipient`, naming a party a burn does not have.
  - `_burn_internal` asserted with the mint module's message; `burn` happened to mask it by checking the same flag itself first, so only the batch path showed it. On a circuit an assertion message is the only diagnostic there is, so the wrong one sends an operator after the wrong address.
  - The duplicate check in `burn` is removed as part of the fix, which also drops `burn` from 83,656 to 81,736 gates — the same circuit size as `burn_batch`. Behaviour is unchanged: the check still runs, once, inside `_burn_internal`.
  - Covered by `burn_batch_restricted_when_freezed`, added and confirmed to fail against the unfixed contract.

### Removed

- `FLAG_DEFAULT_FLAG` and `FLAG_REDEEMED_FLAG` from the credit-events module. They were public constants that nothing read: the module has always stored the two flags as `bool` fields of `CreditEventsStruct`, never as bits of a field.
- The sanction-list mode of the validation module, which was declared but never implemented.
  - `SANCTIONLIST_FLAG`, `SetFlag.operate_sanctionlist`, `UserFlags.is_in_sanction_list` and `get_is_in_sanction_list` are gone, and `operateOnTransfer` now dispatches to the blacklist and the whitelist only.
  - It was a trap rather than a gap: `operateOnTransfer` routed the mode to a handler that called `panic("not implemented.")`, so turning it on blocked every transfer instead of screening anything.
  - Nothing replaces it. `RuleSanctionsList` works on Ethereum because a Chainalysis oracle can be queried on-chain, and Aztec has no equivalent register to read; a sanctioned address must be blocked through the blacklist.
  - BREAKING CHANGE: `SetFlag` and `UserFlags` each lose a field, so the ABI of `set_operations`, `add_to_list` and `remove_from_list` changes and previously generated TypeScript artifacts no longer match. The `BLACKLIST_FLAG` and `WHITELIST_FLAG` bit values are unchanged, so `get_operations` still returns the same numbers.
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

- `doc/standards/building-on-aip20.md` gained a section on pause and deactivation through the ARC-403 hook, and its blocker table no longer lists "no pause anywhere" as a blocker.
  - Both are expressible through the hook. On pause the hook can be more faithful to CMTAT Solidity than this repository is: the reference lets mint and burn continue through a pause (`_canMintBurnByModule` checks deactivation and freeze, not `paused()`), which a hook reproduces exactly, while this token blocks all three.
  - On deactivation the hook falls short in one place: minting cannot be stopped, because the mint paths are not hooked. Criterion 17 would carry that caveat.
  - Records the immediate-versus-delayed choice for a pause flag read from private context, which is the same choice this repository already faces.
- Added `doc/standards/aip20-features-for-cmtat.md`, assessing which AIP-20 features could be adopted while staying CMTAT-equivalent. Each is scored against the 61 equivalency criteria, against the assessment's nine-row privacy table — the section that makes this a *private* CMTAT — and for two products: CMTAT-private, the three existing variants, and CMTAT-private-AIP20, a fourth variant integrating AIP-20.
  - Product map: CMTAT-private gains only the note budget with recursion and the rule-engine hook; the AIP20 variant adds commitment transfers, the five renames and named constructors. Public balances belong to neither, since both products are named for the property it removes.
  - Recommended order: the note budget with recursive subtraction (a measured 43,046-gate saving per transfer, prerequisite a note-count distribution and a re-measured batch cap); commitment transfers screened at initialization, bundled with the five AIP-20 entry-point renames; a settable rule-engine hook that passes the recipient and the caller, which is CMTAT's own `RuleEngine` in ARC-403's calling convention.
  - Commitment transfers carry three mandatory additions the standard lacks: an expiry, because the recipient cannot be re-screened at completion; a second delivery to the issuer, because the library delivers a partial note to one recipient only; and explicit disclosure that the completion amount is emitted in an unencrypted log.
  - Holder self-burn and a single immutable minter are rejected as regressions of criteria 11 and 29–31. Public balances are CMTAT-compatible but contradict this token's premise and are left to a possible fourth variant.
- Corrected the comparison document's second conflict. The AIP-20 documentation says a commitment's recipient is "not yet determined"; the source shows `initialize_transfer_commitment` takes the recipient and binds the partial note to it, and that `PRIVATE_ADDRESS_MAGIC_VALUE` marks a private party in public events rather than an unknown recipient. The conflict is a bounded-timing problem, not an impossibility, and the three other standards documents were aligned with the correction.
- Added `doc/standards/upgrading-aztec-standards.md`, instructions for bringing a fork of `aztec-standards` from `v5.0.0-rc.2` to this repository's `v5.2.0` so the two can be built, tested and composed on one toolchain.
  - Eleven `Nargo.toml` repoints and no source changes. Four aztec-nr crates move to the standalone `AztecProtocol/aztec-nr` repository; the `serde` protocol-circuits crate stays in `aztec-packages` with only its tag bumped, because that tree did not move — a blanket URL replace breaks it.
  - Includes the script that performs the repoint, verified to reproduce the measured result, and the workspace-wide compile and test commands with their expected outputs (eleven artifacts, 79 token tests).
  - Records the second trap: compiling one package and testing it crashes the TXE on the missing `GenericProxy` artifact and cascades `client error (Connect)` into every later test.
  - Explains how the fork is consumed from here — as contract interfaces by path dependency, never as an extensible base — and that both repositories must pin the same `aztec-nr` tag.
- Added `doc/standards/cmtat-as-aip20-auth-contract.md`, assessing whether the module library could be packaged as an ARC-403 authorization contract so that a stock AIP-20 token gains CMTAT compliance without modification.
  - It can: a probe composing the access-control, pause, freeze, validation and extra-information modules into a contract with the `authorize_private` / `authorize_public` interface compiles against the library unchanged, and its private hook measures 20,715 gates.
  - Because the hook is told which token function is running, a policy can refuse every commitment path and every public-balance path outright — closing two of the three conflicts with AIP-20 by refusal rather than by design.
  - What it cannot do follows from two arguments the hook does not pass: the recipient and the initiator. Recipient screening, issuer-only burn and role-gated mint are inexpressible, and the issuer receives no note copies. Five of the nineteen mandatory equivalency criteria come out `partial`.
  - Per transfer it costs roughly 185,000 gates against 120,824 for the integrated token, most of it the cross-contract kernel iteration. The verdict is a legitimate second product for issuers who need the standard artifact itself, not a replacement for the token.
- `doc/standards/building-on-aip20.md` now answers whether this token's entry points could be aligned with AIP-20's without adopting its architecture.
  - They can, by renaming: Aztec selectors are derived from the function name and parameter types, not parameter names — verified by computing selectors from both compiled artifacts — so renaming `transfer` to `transfer_private_to_private` with `authwit_nonce` unchanged yields AIP-20's exact selector. `balance_of_private` and `total_supply` already match.
  - `burn` must not be aliased to `burn_private`: AIP-20's is holder-authorised, CMTAT's requires `BURNER_ROLE`, and an identical selector with different authorisation is a trap for any caller.
  - Alignment is not conformance, and Aztec has no interface detection, so a partial profile is invisible until a missing function is called. The document recommends five renames plus an explicit README statement, or nothing.
- `doc/standards/building-on-aip20.md` gained a sixth option: forking `aztec-standards` and moving it to `v5.2.0`. It was tried rather than estimated.
  - Eleven `Nargo.toml` edits and no source changes: the four aztec-nr crates repointed to the standalone repository at `v5.2.0`, and one protocol-circuits crate (`serde`) left in `aztec-packages` with its tag bumped, because that tree did not move. The whole 11-crate workspace compiles and all 79 of the token's tests pass.
  - The version mismatch is therefore downgraded from a blocker to a chore in the document's blocker table, and the recommendation's reasoning changes from "hard to port" to "every design conflict survives the port".
  - Profiling both tokens on the same toolchain, AIP-20's private transfer costs 63,310 gates against this project's 120,824. The gap reconciles to within ~2,400 gates against components already measured here — validation module, `Transfer` event and the note budget — so the CMTAT features cost what they were measured to cost, and only the note budget is a free saving.
- Added `doc/standards/building-on-aip20.md`, assessing whether the project could be rebuilt on the `aztec-standards` AIP-20 token rather than implementing CMTAT directly. It cannot, for three reasons found by reading the library rather than its documentation.
  - Every crate in `aztec-standards` is `type = "contract"`, and Noir has no inheritance, so there is nothing to depend on and extend — its own vault "extension" is a separate contract that calls the token.
  - AIP-20 does provide a transfer-authorization hook, but it receives only the sender, the amount and the selector. It cannot screen the recipient, while a CMTAT freeze blocks receiving and a whitelist requires both parties listed. Minting is not hooked at all.
  - The library pins a different aztec-nr tag from a different repository than this project, and describes itself as a pre-release.
  - The document also corrects `cmtat-vs-aip20.md`, which stated AIP-20 had no compliance extension point at all, and replaces its first suggestion with a narrower one: pass the recipient to the hook.
- Added `doc/standards/cmtat-vs-aip20.md`, a detailed comparison of CMTAT with Aztec's AIP-20 fungible-token standard.
  - Explains why this contract is deliberately not AIP-20: public balances would add a transparent second ledger to a token built to avoid one, and partial-note transfers cannot coexist with recipient screening, because the recipient is unknown by design when the funds are locked.
  - Carries suggestions in both directions — extension points AIP-20 would need before a compliant token could conform to it, and patterns CMTAT should adopt for ledgers that are not account-model and transparent.
  - The strongest of those is measured rather than argued: sizing a transfer's note budget the way AIP-20 does is worth 43,046 gates, 36% of a transfer, on the proof the user's own device produces.
- Added `EXTRA_INFORMATION_ROLE` (11) to the role enumerations that still stopped at `DEBT_CREDIT_EVENT_ROLE` (10).
  - Three places were stale: the README glossary, the assessment's grant-role criterion, and the assessment's access-control note. The role itself has existed since the terms and token-id module was added.
  - The list is maintained by hand in four places — the code plus three documents — with nothing tying them together, so the next role added will drift the same way unless a check is added.
- Corrected the README's claim that the issuer address can be rotated. It cannot: the constructor schedules `issuer_address` once and no entry point rewrites it, in any of the three variants.
  - Three places said or implied otherwise — the storage description, the issuer-auditability comparison against CMTAT-Confidential, and the delay glossary entry.
  - The constraint now appears under *Limitations* as well, because it is the audit endpoint for every note the contract will ever create: a compromised issuer key means redeploying and migrating holders, and that migration needs every holder's cooperation since balances are notes in their own PXE.
  - Also fixed two broken in-page links in the same section that pointed at headings which no longer exist.
- Added six PlantUML diagrams to the README, with sources under `doc/img/`.
  - Two structural: the three contract packages over the shared module library, and what the contract keeps public against what lives as notes in each holder's PXE.
  - Three flows: private mint, private transfer, and burn with and without an authwit. Each shows where the private half ends and the enqueued public half begins, and calls out exactly which values become public.
  - One explaining why the compliance flags are `DelayedPublicMutable` at all, and the window that opens between scheduling a freeze and its taking effect.
  - The `.puml` files are the source of truth; regenerate a PNG with `plantuml -tpng doc/img/<name>.puml` after editing one.
- Added `doc/analysis/CLAUDE_ANALYSIS.md`, a code-quality review of the Noir sources against Aztec 5.2.0.
  - It is explicitly not a security audit: nothing it reports lets an unauthorized party move value, bypass a restriction or brick a contract.
  - Carries a measured per-function gate baseline from `aztec profile gates`, so a future change can be compared against a number rather than an impression.
  - Findings have stable IDs and each ends in a verdict — implement, decide, or leave with the reason recorded. Two are marked as corrections, where measurement disproved the finding as first written.
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

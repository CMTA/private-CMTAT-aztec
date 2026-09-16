# private-CMTAT-aztec — Aztec.nr Code Quality Review, 0.4.0

| | |
|---|---|
| Scope | The three token variants (`CMTATAztec`, `CMTATAztecDebt`, `CMTATAztecLight`), the two ARC-403 authorization contracts (`CMTATAztecAuth`, `CMTATAztecAuthMultiToken`), and `cmtat_aztec_lib` — in particular the three modules new in 0.4.0: `tokenModule.nr`, `hybridModule.nr`, `authorizationHookModule.nr` |
| Commit reviewed | `1a7470c` on the 0.4.0 development branch (`version()` returns `0.4.0`); the fixes recorded below land on top of it |
| Aztec | CLI `5.2.0`; `aztec-nr` tag `v5.2.0` in every `Nargo.toml`; Noir `1.0.0-beta.25` |
| Date | 2026-09-16 |
| Produced with | Claude Code, following the same checks as the [0.3.0 review](../v0.3.0/CLAUDE_ANALYSIS.md); finding IDs continue that report's numbering within each check |

**This is a code-quality review, not a security audit.** Nothing found here lets an unauthorised party move value, spend another holder's note, bypass a restriction or brick a contract. The one place the review changed a *deployed* property is the removal of two asserts that could never fire (D-3), verified gate-for-gate.

**Privacy findings are in section H.** They are the reason the review exists; for 0.4.0 they concern what the four new private/public bridges publish, and they confirm the design intent rather than contradict it.

**What this review adds over 0.3.0.** Check **K — tests** is new and carries the largest findings of the release: a mutation check showed the project's hard audit invariant (every note copied to the issuer) had no test that could fail; the test harness compiled only the base variant, so four of five contracts were being tested against stale artifacts; and the two smaller variants had smoke suites only. All three are fixed below, with the measurements. The suite grew from 169 to 187 tests in the process.

## Disposition summary

Carried forward from 0.3.0 where still open; new IDs continue each check's sequence. ✅ fixed in this review · ⬜ open (decide / leave) · ⚠️ corrected.

| ID | Finding | Outcome |
|---|---|---|
| A-4 | The token-module refactor is gate-neutral | ✅ verified — all 48 private circuits byte-identical before and after |
| A-5 | The bridges pay the 16-note `sub` the same way `transfer` does | ⬜ decide — same root as F-1 (note budget); `transfer_private_to_public` is 95,941 gates against AIP-20's 38,277 for the same operation |
| A-6 | `initialize_transfer_commitment` costs 39,820 gates, half of it the constrained issuer event | ⬜ keep — the cheaper delivery modes give up the guarantee the event exists for |
| B-3 | `CreditEventsStruct` packs two `bool`s into two Fields | ⬜ decide — unchanged since 0.3.0; fold into the next storage break |
| B-4 | `PauseModule` uses two one-`bool` slots | ⬜ leave — unchanged since 0.3.0 |
| B-5 | The hybrid fields were appended after the existing storage | ✅ verified — no slot moved; the constructor gained a trailing argument only |
| C-7 | The public `Transfer` event is emitted from two sites | ⬜ keep — `_credit_public` and `_debit_public` are two effects, each with the `PRIVATE_ADDRESS` marker on its private side |
| C-8 | A completed commitment's note has no issuer copy | ⬜ keep — the issuer's record is the constrained `CommitmentInitialized` event plus the commitment-tagged completion log; stated in `doc/README.md` |
| C-9 | Four `unused` / `mut` warnings in the base test crate | ✅ fixed — build is warning-clean apart from the framework's own macro warnings |
| D-1 | The three `main.nr` were 99–100 % identical | ✅ closed by `tokenModule.nr` — residue measured below |
| D-3 | `require_batch_shape` asserted two facts that cannot be false | ✅ fixed — removed; gate profile unchanged, confirming the asserts were constant-folded |
| E-3 | Every enqueued public half is `#[only_self]`; every getter `#[view]`; `screening` is a `#[contract_library_method]` | ✅ verified — see the table in E |
| F-1 | Should this token implement AIP-20? | ⬜ decide — two of its three parts landed in 0.4.0 (private-profile names, bridges behind a flag); the note budget remains |
| F-2 | The bridge selectors and the `PRIVATE_ADDRESS_MAGIC_VALUE` semantics match the fork | ✅ verified — pinned by tests against `Token::interface()` at fork commit `5433e9c` |
| G-7 | `doc/img/architecture.puml` still showed three variants and no `tokenModule` | ✅ fixed — re-drawn and re-rendered |
| G-8 | The glossary and the agent guide named the removed `_*_internal` helpers | ✅ fixed |
| G-9 | A stale `cmtat_aztec_aip20` artifact from the reverted crate sat in `target/` | ✅ fixed — removed; `yarn clean` before profiling |
| H-6 | The 360-second delay is an order of magnitude under the library's recommended minimum | ⬜ decide — unchanged; the bridges add four more entry points that carry the same expiration window |
| H-7 | Public-call-count fingerprint, extended to the bridges | ⬜ keep — every value-moving entry point enqueues exactly one public call; the two that enqueue none move no value |
| H-8 | What the bridges publish | ✅ verified — exactly the mover's own side, as the design states; `PRIVACY:` comments at every public half |
| H-9 | The commitment completion log carries the amount unencrypted | ⬜ keep — inherent to partial notes; disclosed in `doc/README.md` and the assessment |
| H-10 | Nothing demonstrates that the issuer's PXE can *process* the offchain copies it receives | ⬜ decide — the Noir suite now proves delivery (K-2); processing needs an e2e test with `offchain_receive` |
| J-2 | Tests live in the contract crates | ⚠️ **corrected, reopened** — `aztec compile` *does* warn at 5.2.0 (`WARNING: Found tests in contract crate(s)`); the 0.3.0 correction had run `aztec-nargo compile`, which does not |
| J-4 | `default-member` made `aztec test` compile one contract of five | ✅ fixed — see K-1 |
| K-1 | `aztec test` ran four of five contracts against stale artifacts after any library edit | ✅ fixed — `default-member` removed from the workspace `Nargo.toml`; proven by a mutant that survived, then died |
| K-2 | The issuer-copy invariant had no test that could fail | ✅ fixed — 4 tests over `env.offchain_messages()`; the mutant that survived now dies |
| K-3 | Six guards had no negative test; no before-delay twin for the freeze; no zero-amount, listed-commitment-party or private-getter test | ✅ fixed — 12 tests in `test_guards.nr` |
| K-4 | `CMTATAztecDebt` and `CMTATAztecLight` had smoke suites only, and nothing guarded their declarations against drift | ✅ fixed — a selector-set pin per variant; the chains themselves are tested once, in the base suite, by construction |
| K-5 | Edge cases still without a test | ⬜ decide — listed in K.3 with the test each needs; six are mechanical, three are design questions |

**Counts:** 29 rows — 16 ✅ (5 verified, 11 fixed), 1 ⚠️ corrected, 12 ⬜ open (6 *decide*: A-5, B-3, F-1, H-6, H-10, K-5 — A-5 and F-1 are one decision; 6 *keep / leave*: A-6, B-4, C-7, C-8, H-7, H-9). *Counted from the table.*

## Outstanding

| ID | Item | Why it is still open |
|---|---|---|
| A-5 / F-1 | Note budget with `#[only_self]` recursion | The 0.3.0 measurement stands (−43,046 gates on `transfer`); the bridges inherit the same cost. It is the last AIP-20 feature `aip20-features-for-cmtat.md` recommends for CMTAT-private and the largest single gate saving available. Not done in 0.4.0 because it changes the note-consumption shape of every value-moving path at once. |
| B-3 | Credit-events packing | A storage break on the Debt variant only; fold into the next one. |
| H-6 | The 360 s delay | Unchanged: needs the network's typical delay, real proving times and a compliance call. 0.4.0 raised the stakes slightly — nine private entry points now read a delayed value instead of five. |
| H-10 | Issuer processing of offchain copies | K-2 proves the messages are emitted with the issuer as recipient. Whether the issuer's PXE can ingest a note it does not own through `offchain_receive` and later read the holder's balance is not shown by any test; the e2e suite checks the issuer's *own* balance. This is the auditability requirement end to end and belongs in `src/test/e2e/`. |
| J-2 | Tests in contract crates | Reopened by the correction. Moving each variant's tests to a `type = "lib"` test crate (`env.deploy("@cmtat_aztec/CMTATAztec")`, `use cmtat_aztec::CMTATAztec`) is mechanical across five crates and removes the warning and the contract recompile on every test edit. Not done here because it touches 30 test files at once. |
| K-5 | Remaining edge cases | See K.3. |

## Gate-count baseline

`aztec profile gates ./target` at `1a7470c`, after a clean `aztec compile --workspace`. Per-function circuit gates only, no kernel overhead. The 0.3.0 column is that report's baseline; the three token variants' value-moving functions were re-measured before and after the token-module refactor (A-4) and after D-3, and did not move.

| Function | `CMTATAztec` 0.3.0 | `CMTATAztec` 0.4.0 | `CMTATAztecDebt` | `CMTATAztecLight` | Note |
|---|---:|---:|---:|---:|---|
| `transfer_private_to_private` (was `transfer`) | 120,824 | 161,493 | 161,493 | 151,085 | +40,669: the `Transfer` event now constrained to both parties (H-4, 0.3.0) |
| `transfer_batch` | 119,145 | 312,909 | 312,909 | 292,178 | cap lowered 4 → 2; per-recipient cost is what grew |
| `mint_to_private` (was `mint`) | 30,776 | 36,976 | 36,976 | 30,776 | +6,200: recipient list screening (G-1, 0.3.0); Light has no lists |
| `mint_batch` | 30,776 | 132,584 | 132,584 | 107,871 | cap raised 1 → 4 |
| `burn` | 83,656 | 87,935 | 87,935 | 81,736 | +4,279: account list screening (G-1) |
| `burn_batch` | 81,736 | 331,362 | 331,362 | 306,820 | cap raised 1 → 4 |
| `transfer_private_to_public` | — | 95,941 | 95,941 | 85,534 | new; see A-5 |
| `transfer_public_to_private` | — | 46,833 | 46,833 | 36,425 | new |
| `transfer_private_to_commitment` | — | 93,011 | 93,011 | 86,812 | new |
| `transfer_private_to_public_with_commitment` | — | 129,874 | 129,874 | 113,352 | new |
| `initialize_transfer_commitment` | — | 39,820 | 39,820 | 33,621 | new; see A-6 |
| `cancel_authwit` | 6,436 | 6,436 | 6,436 | 6,436 | |
| `private_get_*` | 8,229–8,347 | 8,229–8,347 | same | same | |

| Function | `CMTATAztecAuth` | `CMTATAztecAuthMultiToken` |
|---|---:|---:|
| `authorize_private` | 14,650 | 14,651 |

Whole-transaction numbers (`aztec-wallet profile`) were not taken; nothing below depends on them.

---

## A. Circuit cost — private functions

### A-4. The token-module refactor is gate-neutral — verified

`doc/design/token-module.md` predicted that moving the chains into library functions would not change any circuit, because library calls and `#[internal]` helpers are both inlined. The prediction was tested rather than trusted: `aztec profile gates ./target` was captured at `f437cbe^` and again after the refactor, and the 48 private circuits of the five contracts are **byte-identical** in gate count. The same check was repeated after D-3 below. **Keep, and keep the method**: the profile diff is the acceptance test for any change that claims to be a pure refactor.

### A-5. The bridges inherit the 16-note `sub` — decide (same decision as F-1)

`transfer_private_to_public` in `CMTATAztec` is **95,941** gates. The AIP-20 `Token` at fork commit `5433e9c` does the same operation in **38,277**. The difference decomposes into: five `DelayedPublicMutable` reads for screening and the issuer (~20k, by the documented ~4k each — measured indirectly: the Light variant, which skips the two list reads and the operations flag, is 10,407 lower), the `public_side_enabled` read (~3.5k), and the remainder — roughly 34k — in `debit_private`, which calls `BalanceSet::sub` with the library's hard-coded 16-note budget where AIP-20 tries two notes and recurses. That is the F-1 measurement from 0.3.0 (−43,046 on `transfer`) showing up again on a new path. Every bridge and every burn pays it. **Decide**, with F-1: it is the single largest saving available and it does not change the storage layout or the note layout, only how many notes one call may consume.

### A-6. `initialize_transfer_commitment` — keep

39,820 gates, against 6,685 for the fork's own `initialize_transfer_commitment`. The extra is the recipient screening (freeze + list, ~12k, absent in AIP-20 which screens nobody there) and the `CommitmentInitialized` event delivered `onchain_constrained` to the issuer (~20k, the per-delivery figure measured in 0.3.0). The event is what gives the issuer a verifiable record of *which holder* a commitment belongs to before the unencrypted completion log arrives; `offchain()` would make that record forgeable by the opener, `onchain_unconstrained()` would pay DA for the same weakness. **Keep.**

## B. Storage, packing and note reads

### B-3, B-4 — carried forward unchanged

Nothing in 0.4.0 touched `CreditEventsStruct` or `PauseModule`. B-3 remains a storage break to fold into another; B-4 remains a deliberate two-slot layout (the hot `is_paused` read on every transfer's public half should not pay for `is_deactivated`).

### B-5. The hybrid fields were appended, not inserted — verified

`public_balances: PublicBalances<Context>` (one slot, a `Map`) and `public_side_enabled: PublicImmutable<bool, Context>` are the last two fields of `Storage` in all three variants, so every pre-existing slot — including `private_balances`, which feeds every note hash — is unchanged. The constructor gained a trailing `public_side_enabled: bool`. **Verified by reading the three storage structs**; no probe needed. The 0.3.0 warning stands for the future: a field inserted anywhere else re-slots what follows.

## C. Deliveries, events and messages

### C-7. `Transfer` (public) emitted from two sites — keep

`_credit_public` emits `Transfer { from: PRIVATE_ADDRESS_MAGIC_VALUE, to, amount }`; `_debit_public` emits `Transfer { from, to: PRIVATE_ADDRESS_MAGIC_VALUE, amount }`. These are two distinct effects with different marker positions, and each site is the only path to its effect, so the "every state change emits" invariant is structural, not conventional. **Keep.**

### C-8. A completed commitment's note has no issuer copy — keep, and it is documented

`pay_commitment` completes the partial note through `complete_from_private`, which pushes the note hash directly and emits the completion log itself; there is no `NoteMessage` to `deliver_to(issuer, …)`. The issuer's record is therefore the `CommitmentInitialized { to, completer, commitment }` event (constrained, K-2's method could be extended to assert it) plus the completion log, which is tagged by the commitment and carries the amount in clear. `doc/README.md` states this under *Private/public bridges*. **Keep**; the alternative — a second note for the issuer at completion — would double the completion's cost for information the issuer already has.

### C-9. Build warnings — fixed

`aztec compile 2>&1 | grep -i unused` found one `unused variable issuer` (`test_extra_information.nr:25`) and three `variable does not need to be mutable` (`test_hybrid.nr:120/148/158`), all in tests. Fixed. The remaining warnings (`Return variable contains a constant value` ×50, from the framework's own macro expansion) are not the project's. No undelivered message: every `emit`, `add` and `sub` in the library and the contracts is followed by a delivery.

## D. Duplication

### D-1. Cross-variant drift — closed

The 0.3.0 report left D-1 open as structural: "extraction is not available". It was available for everything except the declarations. After `tokenModule.nr` the three `main.nr` have 554 / 609 / 484 *code* lines (comments excluded), of which 514 of the base's are also in Light and 553 in Debt — but those shared lines are now entry-point declarations, attributes, enqueues and events, which Noir requires in the contract module, not logic. The variants differ on the value-moving paths in exactly one line each: `fn screening(storage) -> FreezeAndLists | FreezeOnly`. K-4 adds the guard the residue needs (a selector-set pin per variant).

### D-3. Two asserts that could not fail — fixed

`tokenModule::require_batch_shape(accounts_len, amounts_len)` asserted `accounts_len != 0` and `accounts_len == amounts_len`. Both arguments were `.len()` of fixed-size arrays `[T; MAX_ADDR_PER_CALL]` — compile-time constants equal by type — and `burn_batch` passed `amount.len(), amount.len()`, comparing a value to itself. Neither assert could fire; the message `"Mint module empty"` also appeared on the transfer and burn paths. Removed, with its two message globals. `aztec profile gates` before and after: **identical for every circuit**, which confirms the compiler had already folded them to nothing. The finding is legibility, not cost: a reader took them for a runtime check.

## E. Macro and attribute convention drift

### E-3. Attribute audit of the new surface — verified

| Function | `#[external]` | `#[only_self]` | `#[view]` | Note |
|---|---|---|---|---|
| `_mint`, `_transfer`, `_burn` | public | ✓ | — | as in 0.3.0 |
| `_credit_public`, `_debit_public` | public | ✓ | — | new; arguments published by design (H-8) |
| `_require_lifecycle_allows` (auth ×2) | public | ✓ | — | new |
| `balance_of_public`, `public_get_public_side_enabled`, `get_operations` (auth) | public | — | ✓ | new getters |
| `_grant_role_internal`, `_emit_listed`, `_open_commitment` | `#[internal("public"\|"private")]` | n/a | n/a | inlined helpers |
| `screening` | `#[contract_library_method]` | n/a | n/a | returns a struct holding state variables, which an `#[internal]` may not (entry-point type rule: "vectors, references … may not be used in contract functions"); a library method is the documented shape |

No `#[noinitcheck]`, no second `#[initializer]`, no `#[allow_phase_change]` anywhere. The `#[authorize_once]` attributes name `"from"` / `"account"` and the parameters still carry those names after the AIP-20 renames — checked, since a rename there is a silent break.

## F. Standard conformance

### F-1. AIP-20 — decide (the remaining third)

The 0.3.0 answer was "do not adopt it, but take three things". Two landed in 0.4.0: the **private-profile names** (`transfer_private_to_private`, `mint_to_private`, `name`, `symbol`, `decimals` answer the standard's selectors, pinned in `test_aip20_profile.nr`; `burn` deliberately does not) and the **four bridges plus `initialize_transfer_commitment` and `balance_of_public`** behind `public_side_enabled`. The third — the two-note budget with `#[only_self]` recursion — is A-5. `doc/README.md` states the profile is partial and lists what is absent (`transfer_public_to_public`, `mint_to_public`, `burn_public`, `get_auth_contract`, commitment expiry).

### F-2. Bridge semantics — verified against the fork

Checked against `submodules/aztec-standards` at `5433e9c`, not against the reference contracts in `aztec-packages`: the six bridge selectors are pinned to the values read from `Token::interface()` (`0xaf28c76f`, `0x32c5dcf8`, `0x638d3f00`, `0x398c27b4`, `0xa116fff5`, `0xff7949f2`); `PRIVATE_ADDRESS_MAGIC_VALUE` is the fork's constant and is used only as "the private side of this move", never as a zero-address stand-in; `initialize_commitment` and `complete_commitment` are the fork's `_initialize_transfer_commitment` / `complete_from_private` calls with the same `(owner = to, recipient = to, completer)` arguments and the same `private_balances.get_storage_slot()` — the point where a copy error would have made completed notes undiscoverable, and which the round-trip test `recipient_opens_a_commitment_and_the_sender_completes_it` exercises through `balance_of_private`.

## G. Code / documentation mismatch

### G-7. `architecture.puml` — fixed

The diagram showed three variants over seven modules and said the three `main.nr` are "near-identical by construction". Redrawn: five contracts, `tokenModule` / `hybridModule` / `authorizationHookModule` added with their dependency arrows, `test-helpers/` added, the note rewritten to state what a variant now carries. Alt text in `doc/README.md` updated.

### G-8. Removed helpers still named — fixed

The `#[internal]` glossary row in `doc/README.md` and the *Batching caps* sentence in `CLAUDE.md` / `AGENTS.md` still cited `_mint_internal` / `_transfer_internal` / `_burn_internal`. Both now name the library chains. (The assessment and the standards documents were repointed when the refactor landed; these two were missed.)

### G-9. Stale artifact — fixed

`target/cmtat_aztec_aip20-CMTATAztecAIP20.json` survived the revert of that crate and appeared in `aztec profile gates ./target` output. Removed. `yarn clean` before profiling; the workspace fix in K-1 does not delete orphaned artifacts.

## H. Weird behaviour and privacy leakage

### H-6. The delay — carried forward

Unchanged decision, slightly larger surface: the bridges and `initialize_transfer_commitment` read the same `DelayedPublicMutable` values, so nine private entry points (was five) now carry the 360-second expiration window and the fingerprint the 0.3.0 report describes.

### H-7. Public-call fingerprint, extended — keep

| Private entry point | Public calls enqueued | Public arguments |
|---|---:|---|
| `mint_to_private`, `mint_batch` | 1 | minter, amount |
| `transfer_private_to_private`, `transfer_batch`, `transfer_private_to_commitment` | 1 | *none* |
| `burn`, `burn_batch` | 1 | burner, amount |
| `transfer_private_to_public`, `…_with_commitment` | 1 | public recipient, amount |
| `transfer_public_to_private` | 1 | public sender, amount |
| `initialize_transfer_commitment`, `cancel_authwit` | 0 | — |

Every value-moving entry point enqueues exactly one public call, so the count does not distinguish them; the callee's selector does, as 0.3.0's H-3 records and `doc/README.md` states. The two zero-call entry points move no value. No L2→L1 messages anywhere. **Keep.**

### H-8. What the bridges publish — verified

Traced every argument of the two new public halves. `_credit_public(to, amount)`: the public recipient and the amount — the credited balance is public state, so both are observable regardless. `_debit_public(from, amount)`: the public sender and the amount — same reasoning. Neither receives the private party. `transfer_private_to_commitment` enqueues the argument-less `_transfer()`; `initialize_transfer_commitment` enqueues nothing and its private log goes constrained to the issuer only. This is exactly the disclosure `doc/README.md` promises ("the mover's own side"), and each public half carries a `PRIVACY:` comment saying which argument must never be added. **Verified.**

### H-9. The completion amount is public — keep

`complete_from_private` emits the completion as a log tagged by the commitment with `[storage_slot, value]` in clear — the library's design, not this project's. An observer learns the amount and cannot link it to a party without the commitment's preimage. Disclosed in `doc/README.md`, the standards documents and the assessment's privacy discussion. **Keep**; it is the price of the partial-note pattern.

### H-10. Issuer processing of offchain copies — decide

The design's hard requirement is that the issuer can reconstruct every balance. K-2 now proves each note movement emits an offchain message *addressed to the issuer* (one per mint or burn, two per transfer, following a rotation). What no test proves is that the issuer's PXE can *do anything with them*: `offchain_receive` stores them in an inbox and sync "validates the resulting notes against onchain data" — validation of a note the recipient does not own is the very thing the README says the onchain path cannot do, and the offchain path has not been shown to do it either. The e2e suite's only issuer assertion (`balance_of_private(issuer)`) is the issuer's own balance. **Decide**: write the e2e test — issuer collects `offchainMessages` from a holder's transfer, calls `offchain_receive`, syncs, and reads the holder's notes (or fails, in which case the audit story needs the app-siloed-key alternative the README lists). Until it exists, the auditability claim is delivery-proven and processing-unproven.

## I. Dependency and interface granularity

Nothing new. The two authorization contracts depend on `aztec` and `cmtat_aztec_lib` only; the tokens depend on the same plus `uint_note`, `balance_set`, `compressed_string`. No contract crate depends on another contract crate (the reverted `CMTATAztecAIP20` had needed an interface-only stub for exactly the event-collision reason 0.3.0's I section anticipated; the stub went with the revert).

## J. Modularity

### J-2. Tests in contract crates — ⚠️ corrected, reopened

The 0.3.0 report corrected an earlier claim with "it does not warn at 5.2.0 … a full `aztec-nargo compile --workspace` produced 33 warnings, none mentioning tests". That run used `aztec-nargo`, which at 5.2.0 is a bare `nargo`. **`aztec compile` — the command the project actually uses — does warn**: `checkNoTestsInContracts` in the CLI runs `nargo test --list-tests` after every compile and prints `WARNING: Found tests in contract crate(s):` followed by every test in a `type = "contract"` package (`compile.js`, `@aztec/aztec` 5.2.0). This review saw the list for all five contract crates. The consequence the 0.3.0 report named — every test-only edit recompiles the contract — also stands, and with 187 tests it is felt. **Reopened as decide**: the move is five `type = "lib"` test crates, `use cmtat_aztec::CMTATAztec` and `env.deploy("@cmtat_aztec/CMTATAztec")` replacing the `crate::` forms, `test-helpers/` already exists for the shared parts. Mechanical, but 30 files.

### J-4 / K-1. `default-member` — fixed (see K-1)

## K. Tests — correctness, coverage and edge cases

There is no line or branch coverage tool for Noir contracts under the TXE at 5.2.0; no percentage below comes from a tool. Coverage is an inventory — entry points, assert messages, `if`/`else` branches — checked against the tests by script and by hand. Correctness is a mutation check: a change that should break a test, and whether it did.

### K-1. `aztec test` compiled one contract of five — fixed

`aztec test` runs a bare `aztec compile` before `nargo test`, and a bare `aztec compile` in a workspace compiles the **`default-member`** only. `Nargo.toml` declared `default-member = "contracts/cmtat-aztec"`. So after any edit to `lib/`, `yarn test:nr` (`aztec test --workspace`) rebuilt `CMTATAztec` and ran the other four contracts' tests against whatever artifact `target/` held — up to date only if `yarn compile` had run since. Found the hard way: a mutant in `authorizationHookModule.nr` (K.1 below) survived `aztec test --package cmtat_aztec_auth` twice while `Compilation complete!` was printed and the auth artifact's mtime did not change; an explicit `aztec compile --package cmtat_aztec_auth` then killed it. **Fix:** the `default-member` line is removed; a bare `aztec compile` now rebuilds all five artifacts (verified by mtime after `touch`ing a library file), and the same mutant dies under `aztec test` with no explicit compile. `yarn compile` (`--workspace`) is unaffected. This also explains why the 0.3.0 mutation of `tokenModule`-era code was always caught: it lived in the default member.

### K.1 — Correctness: mutation spot-checks

Five mutants, each a one-line change to a library module, each followed by the tests that should catch it. `aztec compile` was forced before each run once K-1 was understood.

| # | Mutant | Test(s) expected to fail | Result |
|---|---|---|---|
| 1 | Drop `assert(!is_frozen(to))` from `FreezeAndLists::transfer` | `transfer_restricted_when_freezed`, `private_to_public_reverts_for_frozen_recipient` | **killed** — both "passed when they should have failed" |
| 2 | Drop `deliver_to(issuer, offchain())` from `credit_private` | `transfer_private_check_issuer_view`, `mint_private_success` | **survived** → K-2 |
| 3 | Invert `require_transfer` to `assert(pause.is_paused())` | `transfer_when_paused_fails` | **killed** |
| 4 | `is_burn_selector` returns `false` (every hook call treated as a transfer) | `burn_passes_when_paused` (auth) | **survived** against the stale artifact → K-1; **killed** once recompiled |
| 5 | Drop `screening.recipient(to)` from `open_commitment` | `frozen_recipient_cannot_open_a_commitment` | **killed** |

Two of five survived on first run, for two different reasons, both now fixed and both re-verified as killed.

**Message attribution.** Every `should_fail_with` string was checked against the assert it is meant to reach: the 15 `AccessControlUnauthorizedAccount` tests all intend the role check (`*_requires_role`, `*_by_non_admin_fails`, `test_pause_roles`, …); the 4 `Balance too low` tests grant the role before over-spending; the 4 `Unknown auth witness` tests are the on-behalf-of paths without or with the wrong authwit. No test was found to pass on an earlier, unintended assert. **Delayed state**: every freeze/list test advances past `CHANGE_ROLES_DELAY_SECONDS` before asserting the new value; the before-delay twin existed only in the auth crates and is added to the base suite in K-3. **Discovery**: balance assertions go through `balance_of_private`, so note discovery is exercised — including for completed partial notes. **Tautologies**: none found. **Isolation**: every test builds its own `TestEnvironment`.

### K-2. The issuer-copy invariant had no test that could fail — fixed

Mutant 2 removed the issuer's copy of every note created and the suite stayed green. `transfer_private_check_issuer_view`, despite its name, asserts the *holders'* balances; nothing read anything from the issuer's side. The TXE exposes `env.offchain_messages()` — the offchain effects of the last call, each with its `recipient` — so the invariant is assertable mechanically. `test_issuer_copies.nr` (4 tests): a mint emits exactly one offchain message and it is addressed to the issuer; a transfer emits two (change note, recipient note); a burn one; after `set_issuer` and the delay, the copies go to the new issuer. Re-applying mutant 2: three of the four fail. What the tests do **not** prove is processing on the issuer's side — H-10.

### K.2 — Coverage by inventory

Entry points are counted from `#[external]` declarations; "tested" means called by at least one test in that crate (the chains are shared, so a Debt or Light entry point exercised only in the base suite is *not* counted for the variant — the residue that K-4 guards is exactly those declarations).

| Contract | Entry points | Called by a test | Not called | Tests |
|---|---:|---:|---|---:|
| `CMTATAztec` | 53 | 49 | `cancel_authwit`, `renounce_role`*, `private_get_name`*, `private_get_symbol`* (*now covered by K-3) → **1** | 111 |
| `CMTATAztecDebt` | 58 | 19 | the 34 shared declarations + the 5 debt-specific views; K-4 pins the 14 shared selectors | 12 |
| `CMTATAztecLight` | 49 | 14 | 30 shared declarations; K-4 pins 14 selectors | 7 |
| `CMTATAztecAuth` | 22 | 15 | `only_role`, `revoke_role`, `renounce_role`, `get_operations`, `remove_from_list`, `get_frozen`, `unfreeze` | 29 |
| `CMTATAztecAuthMultiToken` | 22 | 15 | same seven | 28 |

**Asserts with a negative test** — 29 distinct assert messages in the library and the base contract, before this review 14 had a `should_fail_with`; after K-3, **21**. The eight without:

| Assert | Where | Verdict |
|---|---|---|
| `Storage slot 0 not allowed…` | every module's `StateVariable::new` | acceptable — the `#[storage]` macro allocates from 1; a downstream hand-written slot 0 is the only caller and the assert is its guard |
| `Accounts and values arrays mismatch`, `Mint module empty` | `tokenModule` | **removed** (D-3) — could not fire |
| `Revoke Role: Cannot revoke role from self`, `Renounce Role: Addresses do not match`, `invalid admin`, `error: address already freezed`, `error: address already unfreezed` | access control, constructor, enforcement | **covered** (K-3) |
| `The sender is in the blacklist` on the *commitment payer* path (`operateOnFrom` via `pay_commitment`), `The recipient is in the blacklist` on the *commitment opener* path (`operateOnTo`) | validation, reached only through the bridges | **covered** (K-3) — the messages had tests, but only on the transfer path |
| (auth crates) `unfreeze` refusal, `remove_from_list` | enforcement / validation through the auth surface | must cover — mechanical, same shape as the token tests; not written here |

**Branches, both sides** — the library has 16 `if`/`else` sites. `authorizationHookModule::require_lifecycle_allows` (`is_burn`): both sides tested (`burn_passes_when_paused`, `private_transfer_reverts_when_paused`). `validationModule`: the four `operateOn*` functions each branch on `operate_blacklist` / `operate_whitelist` / neither — transfer: all three (`transfer_when_blacklisted`, `transfer_when_not_whitelisted`, `transfer_when_no_operations`); mint and burn: blacklist and whitelist sides (`mint_to_blacklisted_fails`, `mint_to_non_whitelisted_fails`, `burn_from_blacklisted_fails`), neither-side implicit in every default-mode test; `operateOnFrom` / `operateOnTo`: blacklist side now tested on the commitment paths (K-3) and whitelist side by `unlisted_recipient_cannot_open_a_commitment_under_whitelist`; the `UserFlags` / `SetFlag` bit packing (six `if`s) is exercised by every list test through `add_to_list` → `get_current_value`. No branch with an untested side remains in the library.

### K-3. Guards, delay twin, edge cases — fixed (12 tests, `test_guards.nr`)

`constructor_rejects_the_zero_admin`; `admin_cannot_revoke_its_own_role` / `admin_can_revoke_another_accounts_role`; `renounce_requires_the_callers_own_address_as_confirmation` / `renounce_with_the_right_confirmation_drops_the_role`; `freezing_twice_reverts`; `unfreezing_an_unfrozen_address_reverts`; `a_freeze_is_not_effective_before_its_delay` (the before-delay twin of `transfer_restricted_when_freezed`); `zero_amount_transfer_is_accepted_and_changes_nothing` (records the current behaviour — CMTAT Solidity accepts a zero transfer too; if the project decides otherwise, this test is the one that changes); `a_blacklisted_recipient_cannot_open_a_commitment`; `a_blacklisted_payer_cannot_complete_a_commitment`; `private_getters_match_the_public_ones`. All twelve passed first run against unmodified code, which for the negative tests means the assert they name is the one that fires.

### K-4. The two smaller variants — fixed

`CMTATAztecDebt` (11 tests) and `CMTATAztecLight` (6) exercised their variant-specific modules and one smoke path each. The chains they share with the base are tested once, in the base suite, which the token-module refactor makes legitimate — but the *declarations* are per variant, and nothing would have noticed a renamed or re-typed entry point in one of them. `test_selectors.nr` in each pins the 14 shared entry points to the base's selectors (the 7 AIP-20 profile values, the 6 bridge values, and `burn` ≠ AIP-20's `burn_private`). A drift in one variant's declaration now fails that variant's suite.

### K.3 — Edge cases

Per family; ✓ has a test, ✚ added in this review, ✗ missing with the test proposed.

| Family | Case | Status |
|---|---|---|
| Zero and identity | amount `0` | ✚ `zero_amount_transfer_is_accepted_and_changes_nothing` |
| | `AztecAddress::zero()` as admin / issuer | ✚ constructor / ✓ `set_issuer_to_zero_fails` |
| | `from == to` | ✓ `transfer_private_to_self` |
| | zero address as mint recipient or commitment completer | ✗ — *design question*: a note owned by the zero address is unspendable (a de-facto burn that leaves `total_supply` unchanged); a zero completer makes a commitment uncompletable but locks nothing. Decide whether to refuse; record under K-5 |
| Note budget | one more than the balance | ✓ 4 `Balance too low` tests |
| | a balance spread over more than 16 notes (`BalanceSet::sub` hard-codes `max_notes = 16`) | ✗ — mechanical: 17 mints of 1 to one holder, then a transfer of 17; expected today: `Balance too low` from `sub`; the test documents the F-1 limit |
| | exactly the balance | ✗ — mechanical: transfer `mint_amount`; expect a zero change note and a zero balance |
| Batches | the cap | ✓ every batch test |
| | the cap plus one | ✓ measured, recorded in the cap comment (a compile-time size, not a runtime test) |
| | the same address twice in a batch | ✗ — mechanical: `mint_batch([user, user, …])`; expected: two notes, balance is the sum |
| | `u128` overflow across the loop | ✓ `mint_private_failure_overflow` |
| Delays | before / after | ✚ before-delay twin; ✓ after |
| | two changes scheduled before the first lands | ✗ — mechanical on `set_issuer`: schedule A, then B before the delay; after one delay the value is B and copies go to B |
| | expiration honoured | not testable in the TXE (no mempool); the e2e suite would need a deliberately slow inclusion |
| Lifecycle | paused / unpaused / deactivated, each operation; deactivate without pause; unpause after deactivate; pause twice | ✓ `test_pause_module.nr`, 17 tests |
| Authwits | self with nonce 0 | ✓ |
| | self with a non-zero nonce | ✗ — mechanical: `transfer_private_to_private(from = caller, …, 1)`; the macro must reject it |
| | third party valid / without approval / wrong caller | ✓ |
| | a consumed authwit replayed | ✗ — mechanical: reuse the same call and nonce; expected `Nullifier already exists` or the authwit error |
| | `cancel_authwit` then use | ✗ — mechanical; `cancel_authwit` is the last entry point of the base contract with no test |
| Roles | grant / use / revoke / renounce | ✓ and ✚ |
| | the last admin renouncing | ✗ — *design question*: OpenZeppelin and CMTAT allow it; the contract then has no admin forever. Decide whether to refuse; record under K-5 |
| Delivery | note copies to the issuer | ✚ K-2 (count and recipient) |
| | `Transfer` event read by the recipient and by the issuer | ✗ — **not testable in the TXE at 5.2.0**: `get_private_events` / `discover_event` are `pub(crate)`; belongs in the e2e suite with `getPrivateEvents`, alongside H-10 |
| | issuer *processing* of the copies | ✗ — H-10 |
| Partial notes | open by recipient, complete by the completer | ✓ |
| | completion by a party that is not the completer | ✗ — **must cover**: it is the validity-commitment check; expected a revert from `assert_nullifier_exists` |
| | complete twice | ✗ — must cover: second completion has no notes to spend or completes a second note; the expected behaviour needs stating |
| | complete before the opening is mined | ✗ — mechanical: skip `mine_block()`; expected revert (the validity commitment is not settled) |
| | recipient frozen or delisted between opening and completion | ✗ — records the documented gap ("no commitment expiry"): the completion succeeds today; a test that says so keeps the gap visible |
| Public halves | `_transfer` takes no arguments | ✗ — mechanical and compile-time: `Token::interface()._transfer()` in a test compiles only while the signature is empty |
| | a public revert discards private effects | not observable after `should_fail_with` in the TXE (the test ends at the revert); the e2e suite can assert balances after a failed send |
| Constructors and views | re-calling the initializer | ✗ — mechanical: a second `with_public_initializer` on the same address; expected `Initializer` revert |
| | `view_public` on every `#[view]` | ✓ (typed; a dropped attribute fails to compile) |
| | selectors pinned to the standard | ✓ and ✚ K-4 |
| Storage | private-balance slot unchanged against a baseline | ✗ — mechanical: the `#[aztec]` macro generates a `storage_layout()` getter; pin `storage_layout().private_balances.slot` in a test so a re-slot (which would orphan every note) fails a test rather than a deployment |

### K-5. Remaining edge cases — decide

Fourteen ✗ rows above. Nine are mechanical and can be written without a decision (over-16-notes, exact balance, duplicate batch address, two scheduled issuer changes, self with non-zero nonce, replayed authwit, `cancel_authwit`, non-completer completion, completion before settlement, re-initialization, `_transfer` signature pin, storage-slot pin — twelve, two of them requiring an expected-behaviour statement first: complete-twice and frozen-after-opening). Two are design questions the project should answer before a test encodes them: whether a zero-address mint recipient / commitment completer is refused, and whether the last admin may renounce. Two are e2e-only (event reads, issuer processing — H-10).

## Summary table for K

| Contract | Entry points tested | Asserts with a negative test (library + contract) | Branches both sides | Mutants survived → after fixes |
|---|---|---|---|---|
| `CMTATAztec` | 52 / 53 (`cancel_authwit`) | 21 / 29 (8 remaining: 1 acceptable, 2 removed, 5 auth-surface or e2e) | 16 / 16 | 2 / 5 → 0 / 5 |
| `CMTATAztecDebt` | 19 / 58 direct + 14 selectors pinned; chains tested in base | shared | shared | — |
| `CMTATAztecLight` | 14 / 49 direct + 14 selectors pinned; chains tested in base | shared | shared | — |
| `CMTATAztecAuth` / `…MultiToken` | 15 / 22 each | 7 / 9 (`unfreeze`, `remove_from_list` untested) | 1 / 1 | 1 / 1 (stale artifact) → 0 |

---

## What was run, and what was not

**Run.** `aztec compile --workspace` (clean); `aztec profile gates ./target` three times (baseline, after A-4's refactor, after D-3); `aztec test --workspace` — **187 tests passed** (111 base, 12 Debt, 7 Light, 29 + 28 auth) after the additions; five mutation runs with the targeted tests, plus their re-runs after the fixes; the `default-member` experiment (mtime of all five artifacts after a bare `aztec compile`); a scripted inventory of entry points, asserts, branches, `should_fail_with` strings and tested entry points.

**Not run.** `aztec-wallet profile` (needs a sandbox); `yarn test:js`; any test of the issuer's PXE processing offchain messages (H-10).

**Hazards for what this report recommends.** A-5 / F-1 changes how many notes a call consumes, not the note layout — but every value-moving path at once, so the gate profile *and* the note-count edge cases in K.3 should be the acceptance tests. J-2 moves tests, not code; the risk is the `@crate/Contract` deploy strings. Nothing here touches a storage slot; nothing here may be "fixed in an upgrade".

---

*Produced with Claude Code against `aztec` 5.2.0 / `aztec-nr` v5.2.0 / Noir 1.0.0-beta.25, commit `1a7470c`, on 2026-09-16. Findings were verified against the code at that commit; line numbers are not cited for that reason.*

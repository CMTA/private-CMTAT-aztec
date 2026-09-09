# private-CMTAT-aztec — Aztec.nr Code Quality Review

| | |
|---|---|
| Scope | `lib/` (`cmtat_aztec_lib`) and the three contract crates `contracts/cmtat-aztec`, `contracts/cmtat-aztec-debt`, `contracts/cmtat-aztec-light` |
| Commit | `6728a8a` (branch `dev`) |
| Aztec CLI | `5.2.0` |
| `aztec-nr` tag | `v5.2.0` (from `Nargo.toml`) |
| Noir compiler | `1.0.0-beta.25` |
| Date | 2026-09-09 |
| Produced with | Claude Code |

**This is a code-quality review, not a security audit.** Nothing in this report lets an unauthorized party move value, spend another holder's note, bypass a restriction or brick a contract. Every `#[external("public")]` function that services an enqueued private call carries `#[only_self]`; the role check and the pause check are present on every value-moving path; no unconstrained value reaches a constrained assertion. Two items sit on the boundary and are called out where they appear: **A-1** (a duplicated check — wasteful, not unsound) and **H-1** (an address published in a public call's arguments — see below for why its blast radius is small).

**Privacy findings are in section H.** On Aztec that is what a reader looks for first, and it is the section where a correct contract can still defeat its own purpose. The headline is that this contract's private/public split is mostly *right*: `mint` does not publish its recipient, and the enqueued half of `transfer` takes no arguments at all. The residue is in H-1 and H-3.

**A-1, G-2 and G-6 were fixed after the review** (commit follows this report); every other Outcome below is a verdict, not a record of work done. Two temporary probes were compiled and deleted (B-1, J-1/J-3); the working tree was verified clean afterwards and the baseline gate counts reproduced.

---

## Disposition summary

| ID | Finding | Outcome |
|---|---|---|
| A-1 | Duplicated `is_frozen(from)` read in `burn` — 1,920 gates | ✅ fixed |
| A-2 | Issuer and freeze reads sit inside the per-address loop | ⬜ decide before raising `MAX_ADDR_PER_CALL` |
| A-3 | `#[internal("private")]` on the three `_*_internal` helpers | ✅ keep — correct as written |
| A-4 | No runtime-bounded loops, no unconstrained-then-constrained patterns | ✅ nothing to do |
| B-1 | `SetFlag` derives `Packable` (N=2) where `UserFlags` hand-packs (N=1) | ⚠️ **corrected** — measured +7 gates, do not change |
| B-2 | `UserFlags` splits derived `Serialize` from hand-written `Packable` | ✅ keep — this is the documented split |
| B-3 | `CreditEventsStruct` packs two `bool`s into two Fields | ⬜ decide — fold into the next storage break |
| B-4 | `PauseModule` uses two one-`bool` slots | ⬜ leave |
| C-1 | `transfer_batch` emits no `Transfer` event; `transfer` does | ⬜ implement |
| C-2 | `Transfer` delivered `onchain_unconstrained()` to `to` only | ⬜ decide |
| C-3 | `set_terms` emits nothing; `set_token_id` emits `TokenId` | ⬜ implement |
| C-4 | Constructor configures the contract with no event at all | ⬜ implement |
| C-5 | No undelivered messages anywhere | ✅ checked — clean |
| C-6 | Nine state-changing admin entry points emit nothing | ⬜ decide (README already lists this as future work) |
| D-1 | The three `main.nr` files are 99–100% identical | ⬜ decide — guard mechanically, extraction is not available |
| D-2 | `test/utils.nr` duplicated 75/78 lines across three crates | ⬜ implement (partially) |
| E-1 | `#[view]` missing on four read-only entry points | ⬜ implement |
| E-2 | Three getters return without `pub`, unlike every sibling | ⬜ implement |
| E-3 | `#[only_self]`, `#[initializer]`, `#[noinitcheck]` discipline | ✅ checked — clean |
| F-1 | No AIP-20 conformance claim, and no AIP-20 surface | ⬜ implement (one README sentence) |
| G-1 | `mint` NatSpec claims a validation check that does not run | ⬜ implement |
| G-2 | `_burn_internal` asserts `"Frozen: Recipient"` on a burn's sender | ✅ fixed |
| G-3 | `issuer_address` has no setter, but three documents describe changing it | ⬜ decide |
| G-4 | `EXTRA_INFORMATION_ROLE = 11` missing from two role lists | ⬜ implement |
| G-5 | Doc-comment length; no `.md` pointers in contract source | ✅ checked — clean |
| G-6 | `yarn compile` produces artifacts `yarn codegen` cannot consume | ✅ fixed |
| H-1 | `burn` publishes the caller's address and the amount | ⬜ decide — document, do not redesign |
| H-2 | `mint` hides `to`; `_transfer()` takes no arguments | ✅ keep — and protect from "simplification" |
| H-3 | The enqueued public selector reveals which operation ran | ⬜ decide — document |
| H-4 | The `Transfer` event adds a DA record the note delivery already covers | ⬜ decide (see C-2) |
| I-1 | Workspace dependency graph | ✅ checked — clean |
| J-1 | `UserFlagsTrait` / `FreezableFlagTrait` are not `pub` | ⬜ implement — one word each |
| J-2 | `#[test]` functions live inside the contract crates | ⚠️ **corrected** — no compiler warning at 5.2.0 |
| J-3 | Module structs are genuinely reusable | ✅ verified by compiling a downstream probe |

**Counts:** 35 rows — 12 ✅ (9 checked/keep, 3 fixed), 2 ⚠️ corrected, 21 ⬜ open (9 *implement*, 10 *decide*, 2 *leave*).

G-6 was not found by reading; it surfaced while regenerating artifacts after the A-1 fix. It is included because it breaks the project's own documented build sequence.

## Outstanding

| ID | Item | Why it is still open |
|---|---|---|
| C-1, C-3, C-4, D-2, E-1, E-2, F-1, G-1, G-4, J-1 | The *implement* set | Not yet applied. All are small and none is a storage or note-layout change, so they can land in one commit before 0.3. A-1 and G-2 have since been fixed — see below. |
| A-2, D-1 | Loop hoisting; cross-variant drift | Both are latent: A-2 costs nothing at `MAX_ADDR_PER_CALL = 1`, D-1 costs nothing while the three files agree. Both become expensive exactly when someone changes the thing that makes them matter. |
| B-3, C-2, C-6, G-3, H-1, H-3, H-4 | The *decide* set | Each is a design choice with a defensible answer either way; the report states the trade-off rather than picking. |

---

## Gate-count baseline

Measured with `aztec profile gates ./target` at commit `6728a8a`, after a clean `aztec-nargo compile --workspace`. **These are per-function circuit sizes for this contract only — they exclude the protocol kernel overhead entirely.**

| Function | `CMTATAztec` | `CMTATAztecDebt` | `CMTATAztecLight` |
|---|---:|---:|---:|
| `transfer` | 120,824 | 120,824 | 110,416 |
| `transfer_batch` | 119,145 | 119,145 | 108,737 |
| `burn` | 83,656 | 83,656 | 83,656 |
| `burn_batch` | 81,736 | 81,736 | 81,736 |
| `mint` | 30,776 | 30,776 | 30,776 |
| `mint_batch` | 30,776 | 30,776 | 30,776 |
| `cancel_authwit` | 6,436 | 6,436 | 6,436 |
| `private_get_issuer` | 8,347 | 8,347 | 8,347 |
| `private_get_name` / `_symbol` | 8,229 | 8,229 | 8,229 |
| `private_get_decimals` | 8,230 | 8,230 | 8,230 |

> The `burn` row is the **pre-fix** baseline. A-1 has since been applied, so `burn` is now 81,736 in all three variants; the row is left at its measured value so the saving below is reproducible.

Three differences in that table are themselves measurements, and each supports a finding below:

| Quantity | Derivation | Gates |
|---|---|---:|
| The validation module's cost on a transfer | base `transfer` − Light `transfer` | **10,408** |
| The `Transfer` event | `transfer` − `transfer_batch` (which does not emit one) | **1,679** |
| The duplicated freeze check in `burn` | `burn` − `burn_batch`, confirmed by removing it | **1,920** |

**What is not measured here.** Whole-transaction cost — `private_kernel_init` / `_inner` / `_tail` plus the account entrypoint — needs `aztec-wallet profile` against a running sandbox, which this review did not start. The reference figures (~290,000 fixed kernel overhead per transaction, ~101,000 per additional private call) are quoted from `writing_efficient_contracts.md`, **not measured**, and are used below only to argue about the *shape* of a change, never as a finding's evidence. Public functions are AVM bytecode and cost gas, not gates; no gate number in this report is quoted for a public function.

---

## A. Circuit cost — private functions

### A-1. `burn` reads the freeze flag twice — `contracts/cmtat-aztec/src/main.nr:562` and `:540`

`burn` checks the sender's freeze flag, then calls `_burn_internal`, which checks it again:

```noir
fn burn(from: AztecAddress, amount: u128, authwit_nonce: Field) {
    assert(!self.storage.enforcement_module.is_frozen(from), "Frozen: Sender");   // :562
    self.internal._burn_internal(from, amount);
    ...
}

fn _burn_internal(from: AztecAddress, amount: u128) {
    assert(!self.storage.enforcement_module.is_frozen(from), "Frozen: Recipient"); // :540
    ...
}
```

Because `_burn_internal` is `#[internal("private")]` it is inlined, so both reads land in the same circuit. `is_frozen` is a `DelayedPublicMutable` read.

**Measured.** Deleting line 562 and recompiling `cmtat_aztec` moved `burn` from **83,656 → 81,736** gates — a saving of **1,920**, and exactly the value of `burn_batch`, which reaches `_burn_internal` without the extra check. That is well under the ~4,000 the docs quote for a `DelayedPublicMutable` read, which is worth stating: the second read of the same slot shares most of its constraints with the first, so the naive "one read = 4,000 gates" arithmetic overstates it by more than 2×. The probe was reverted and the baseline reproduced.

**Consequence.** 1,920 gates of proving time on the user's own device, on every burn, for a check that has already run. Against a whole transaction of roughly 290k+ kernel gates it is ~0.5% — small, but it is free to remove and the removal also fixes G-2.

**Verdict: implement — done.** Line 562 was deleted and the surviving assertion in `_burn_internal` now reads `"Frozen: Sender"` (G-2), in all three variants. Re-profiled after the change: `burn` is **81,736**, exactly matching `burn_batch`, as predicted. The regression test is `burn_batch_restricted_when_freezed` (see G-2); the full suite is 76 tests passing, up from 75.

### A-2. The issuer read and the freeze reads sit inside the per-address loop — `:508`, `:511`, `:406`, `:540`

`mint_batch`, `transfer_batch` and `burn_batch` call their `_*_internal` helper once per array entry, and each helper reads `issuer_address.get_current_value()` — a `DelayedPublicMutable` read — plus one or two freeze flags:

```noir
for i in 0..MAX_ADDR_PER_CALL {
    self.internal._transfer_internal(from, accounts[i], amount[i]);
}
```

At `MAX_ADDR_PER_CALL = 1` this costs nothing, which is why it does not show up in the baseline. The issuer address is loop-invariant, and in `transfer_batch` and `burn_batch` so is `is_frozen(from)` — only the recipient varies.

**Consequence.** The comment at `main.nr:49` observes that the protocol now allows 16 private logs and 8 nested private calls, and that the cap "could now be raised". Raising it to 3 makes the contract pay 3 issuer reads and 3 sender-freeze reads where 1 of each is correct. This is the finding that turns from free into expensive at exactly the moment someone acts on that comment.

**Verdict: decide, and record the decision next to the cap.** Either hoist the invariant reads into the batch entry points and pass them down, or add a line to the `MAX_ADDR_PER_CALL` comment saying that hoisting is a prerequisite for raising it. The second is cheaper today and loses nothing, provided it is written down.

### A-3. The `#[internal("private")]` helpers are the right structure — keep

`_mint_internal`, `_transfer_internal` and `_burn_internal` are `#[internal("private")]`, so the macro inlines them at compile time: no nested call, no extra `private_kernel_inner` iteration. Had they been `#[external("private")]` or `#[only_self]`, each call site would add a kernel iteration — on the order of 101,000 gates per call by the framework's own figure, which is roughly **the whole of `mint`** (30,776) three times over.

The mirror-image structure — splitting unbounded work across `#[only_self]` recursion — is not applicable here: every loop is bounded by `MAX_ADDR_PER_CALL`, a compile-time constant of 1.

**Verdict: keep, and this is worth a comment.** The temptation to "clean up" these three helpers into ordinary private functions is real and the penalty is invisible in the source. One line above `_transfer_internal` saying *this must stay `#[internal]`; making it a private call adds a kernel iteration* would prevent a five-figure regression that no test would catch.

### A-4. Patterns checked and absent

- **No runtime-bounded loops.** Every loop bound is `MAX_ADDR_PER_CALL`, a `global`.
- **No unconstrained-then-constrained computation.** There is no `sqrt`, sort or array-compaction pattern, so the "constraint is incomplete" failure mode does not arise. `balance_of_private` is `#[external("utility")] unconstrained` and its result is returned to the caller, never fed into an assertion.
- **No `self.utility.call(...)` from a private function**, so there is no unproven value crossing into a constrained context.
- **No bit-manipulation or relational operators on a hot path.** The only bitwise code is `UserFlags`/`SetFlag` pack/unpack (`&`, `|` on a `u64`), which runs at most twice per transfer.

**Verdict: nothing to do.** Recorded so the absence is visible as *checked* rather than *not looked at*.

---

## B. Storage, packing and note reads

### B-1. ⚠️ Corrected — `SetFlag`'s derived `Packable` is *not* worth replacing

**The finding as originally written.** `lib/src/modules/validationModule.nr:23` derives `Packable` on `SetFlag`, a struct of two `bool`s, giving `N = 2`. Twelve lines below, `UserFlags` — also two `bool`s — carries a **hand-written** `Packable` with `N = 1`, and `SetFlag` already has the exact bit-packing logic written out in its `ToField`/`FromField` impls. It looked like a copy-paste omission: the pack function exists, it is simply not wired to `Packable`. `SetFlag` lives in a `DelayedPublicMutable`, and the module's storage span is declared as `M + 2` where `M` is the packed length of `DelayedPublicMutableValues<SetFlag, …>`, so a smaller `SetFlag` shrinks the module's slot span too.

**What the measurement showed.** I wired `Packable for SetFlag` to the existing `to_field`/`from_field` (`N = 1`), recompiled `cmtat_aztec`, and re-profiled:

| | `transfer` | `transfer_batch` |
|---|---:|---:|
| Derived `Packable`, `N = 2` (current) | 120,824 | 119,145 |
| Hand-written `Packable`, `N = 1` | 120,831 | 119,152 |

The change made the private hot path **7 gates more expensive**, not cheaper. The bit-packing arithmetic in-circuit costs marginally more than reading one additional field out of the already-hashed `DelayedPublicMutableValues`. The prediction was wrong in sign, if trivially so in size.

**What survives.** The storage-slot argument is untouched by that measurement — `N` really does go 2 → 1, and the module's span shrinks with it, which is fewer `SLOAD`/`SSTORE` in `set_operations` and `get_operations`. **I did not measure public gas**, and the honest position is that a sub-ten-gate private regression against an unmeasured public saving is not a case for a change that moves every storage slot after the validation module.

**Verdict: leave it, and this entry is the reason.** The asymmetry with `UserFlags` looks like an oversight and will be re-proposed by the next reader; the measurement above is what stops that happening twice. If the packing is ever revisited as part of an unrelated storage break, the round-trip test `assert(SetFlag::unpack(x.pack()) == x)` is mandatory — a hand-written pack/unpack is code the derive cannot get wrong, and that assertion is the only thing keeping it honest.

### B-2. `UserFlags` splits its encodings correctly — keep

`UserFlags` (`validationModule.nr:29–35`, `:189`) derives `Serialize`/`Deserialize` and hand-writes `Packable`. That is exactly the split the framework requires and it is easy to get backwards:

- `Serialize`/`Deserialize` is the **ABI boundary**. `UserFlags` is an argument to `add_to_list` and `remove_from_list`, so its serialization must match Noir's intrinsic layout. Hand-rolling it here would produce an "arguments hash mismatch" at call time — a runtime failure, not a compile error.
- `Packable` is the **storage encoding**, internal to the contract, and may be packed freely. It is.

**Verdict: keep.** Worth naming in the report precisely because B-1 makes the opposite change look attractive.

### B-3. `CreditEventsStruct` spends two Fields on two `bool`s — `creditEventsModule.nr:10`

`#[derive(Deserialize, Eq, Packable, Serialize)]` on `{ flagDefault: bool, flagRedeemed: bool, rating: FieldCompressedString }` gives `N = 3`; the two flags could share one Field for `N = 2`.

Unlike B-1 this is **public state only** — there is no private read path for credit events — so the cost is one `SLOAD` and one `SSTORE` per access, not gates, and no gate number applies. It is small, and it is a storage-layout change.

**Verdict: decide.** Not worth a break on its own. If another storage break lands before 0.3 (and the debt realignment already is one), folding this in costs nothing extra; otherwise leave it. Same reasoning applies to `PauseModule`'s two one-`bool` slots (**B-4**), where the two flags are read on different paths and separating them is arguably clearer anyway — **verdict: leave**.

### B-5. Note reads — not applicable, and worth saying why

The `get_notes`-vs-`pop_notes` question, `NoteGetterOptions` limits, and post-retrieval filtering do not arise: this contract never calls the note-getter API directly. All note handling goes through `Owned<BalanceSet>` from the `balance_set` aztec-nr library (`private_balances.at(x).add/sub/balance_of`), which owns those choices. There is no `PrivateMutable` in the storage struct, so the "reading a `PrivateMutable` is a write" contention issue does not apply either.

**Verdict: nothing to do** — but note the flip side. Delegating note handling to the library means the project's note-read efficiency is the library's to change, and a future `balance_set` upgrade can move these gate counts without a line changing here. The baseline table above is what makes that visible.

---

## C. Deliveries, events and messages

### C-1. `transfer_batch` emits no `Transfer` event — `main.nr:478` vs `:495`

`transfer` emits `Transfer { from, to, amount }`; `transfer_batch` performs the same state change and emits nothing.

**Consequence.** Two entry points that move tokens identically leave different trails. Anything built on the event — an issuer's reconciliation, a block explorer, a compliance feed — silently misses every batched transfer. At `MAX_ADDR_PER_CALL = 1` the two functions are the *same operation*, so this is not a batching edge case: it is one of two equivalent paths having no record.

**Measured cost of the event:** 1,679 gates (`transfer` 120,824 − `transfer_batch` 119,145). Adding it to `transfer_batch` costs that per recipient.

**Verdict: implement**, and the direction should be decided together with C-2 — if the event moves to `offchain()` delivery it becomes cheaper and the argument for emitting it in both places gets stronger.

### C-2. The `Transfer` event pays for data availability and buys no guarantee — `main.nr:478`

```noir
self.emit(Transfer { from, to, amount }).deliver_to(
    to,
    MessageDelivery::onchain_unconstrained(),
);
```

Three things are worth separating:

- **The mode.** `onchain_unconstrained()` pays blob cost for the log and gives no guarantee the sender delivered correct content. The framework documentation is blunt that this is strictly worse than `offchain()` where an offchain channel is available. The recipient does **not** depend on this event — they receive their note via `onchain_constrained()` two lines earlier — so the guarantee `onchain_constrained()` would buy is not needed, and the DA cost `onchain_unconstrained()` incurs is not bought back.
- **The recipient set.** Only `to`. The sender gets no record of their own transfer, and neither does the issuer.
- **The issuer omission is a rule violation.** `CLAUDE.md` states: *"Any note written for a user must also be delivered to the current `issuer_address` — auditability is a hard requirement of the design."* Both note messages in `_transfer_internal` honour that. The event does not. An event is not a note, so this is not a contradiction of the letter — but the event carries `from`, `to` and `amount` in one place, which is precisely what an auditor wants, and it is the one message the issuer does not receive.

**Verdict: decide.** The defensible combination is `offchain()` to `to` and `from` and the issuer — same information, no blob cost, and consistent with how the issuer's note copies are already delivered. The counter-argument for keeping DA is that an offchain-only trail is exactly the weakness the CHANGELOG's Security section already documents for the issuer's note copies, and doubling down on it makes that weakness total. Whichever way it goes, the choice should be recorded next to the emit, as the issuer-copy decision already is at `main.nr:57`.

### C-3. `set_terms` emits nothing while `set_token_id` emits `TokenId` — `main.nr:288` vs `:309`

The two setters sit in the same module, are guarded by the same role, and were added in the same release. One is observable, the other is not. CMTAT Solidity emits `Terms(CMTATTerms)` from `setTerms`, so the reference implementation has the event this one is missing.

**Verdict: implement.** A `Terms` event mirroring `TokenId` is a few lines, and the inconsistency between two sibling functions is the evidence that this is drift rather than a decision.

### C-4. The constructor configures the contract and emits nothing — `main.nr:119–122`

```noir
self.storage.access_control._grant_role(DEFAULT_ADMIN_ROLE, admin);   // :119
self.storage.access_control._grant_role(VALIDATION_ROLE, admin);      // :120
self.storage.issuer_address.schedule_value_change(admin);             // :122
```

`grant_role` emits `NewRole`. `_grant_role`, called twice here, does not. So the two most consequential role grants in the contract's life — the admin and the validation role, both to the deployer — are the only two with no event, and the issuer address is set for the only time it is ever set (G-3) with no event either.

**Consequence.** An indexer built on `NewRole` sees every subsequent grant and misses the founding ones, which is worse than seeing none: the role table it reconstructs is wrong rather than obviously incomplete.

**Verdict: implement.** Emit `NewRole` twice from the constructor. The general shape the framework guidance recommends — one `#[internal]` helper owning validate + write + emit — would also close this structurally, and has the side benefit that the validation currently living in `grant_role` would start guarding the constructor path too.

### C-5. No undelivered messages — checked, clean

`aztec-nargo compile --workspace` produces **33 warnings, all identical** (`Return variable contains a constant value`) and **all originating in aztec-nr's own macro expansion** (`aztec/src/macros/internals_functions_generation/external/private.nr:166`). Zero warnings point at project source, and specifically there is no unused-value warning — which is the signal an undelivered `EventMessage` or `NoteMessage` would produce. Every `self.emit(...)` site (15 across the three variants) either has a `.deliver_to(...)` or is a bare public event.

**Verdict: nothing to do** — but note the hazard this creates. A build that always prints 33 warnings trains everyone to ignore the warning stream, which is exactly where an undelivered-message warning would appear. Worth a line in the agent guide saying the expected count is 33 and all should be from aztec-nr, so a 34th is noticed.

### C-6. Nine state-changing entry points emit nothing

`pause_contract`, `unpause_contract`, `freeze`, `unfreeze`, `set_operations`, `add_to_list`, `remove_from_list`, `revoke_role`, `renounce_role`. Four entry points do emit (`grant_role`, `deactivate_contract`, `set_token_id`, `transfer`), plus three added with the debt realignment.

The README already records event coverage as future work, so this is not news. It is listed here to make the shape visible: the emitting set is not a coherent subset — `grant_role` emits and `revoke_role` does not; `deactivate_contract` emits and `pause_contract` does not. Any observer reconstructing contract state from events gets a partial and asymmetric picture.

**Verdict: decide.** If the whole set is out of scope for 0.3, the cheapest honest step is pairing: whatever emits should have its inverse emit too (`revoke_role` with `grant_role`, `unpause` with `pause`). Half a pair is worse than neither.

---

## D. Duplication

### D-1. The three `main.nr` files are 99–100% identical

Measured over code lines only (comments and blanks stripped):

| Pair | Identical code lines | As a share of the smaller file |
|---|---:|---:|
| `cmtat-aztec` (378) vs `cmtat-aztec-debt` (431) | 377 | 100% |
| `cmtat-aztec` (378) vs `cmtat-aztec-light` (341) | 339 | 99% |
| `cmtat-aztec-debt` (431) vs `cmtat-aztec-light` (341) | 339 | 99% |

So roughly **340 lines exist in triplicate**, and the Light variant is the base variant minus one module.

**Why it was not shared, which is the part that matters.** This is not a missed extraction. Noir allows one contract per crate, and every user-callable entry point must be declared *inside* the `#[aztec]` contract module — a `#[external("private")]` function cannot live in a `type = "lib"` crate. The logic is already in `cmtat_aztec_lib`; what is duplicated is the declaration shell that the framework requires. There is no extraction available at 5.2.0.

**Consequence.** `CLAUDE.md` already carries the rule — *"Adding an entry point to a shared module means adding it to every variant that should expose it … Keep the three `main.nr` files in step"* — which is an accurate statement of a manual invariant with 340 lines of surface and no enforcement. The debt realignment in `6728a8a` is a live example: it touched only `cmtat-aztec-debt`, correctly, but nothing would have caught it if it had needed to touch the others.

**Verdict: decide — guard it mechanically rather than trying to remove it.** A short script that strips the variant-specific banner sections and diffs the remainder across the three files, run in CI, converts a convention into a check. That is the whole of the available fix, and it is worth saying plainly in the report that the duplication itself is not a defect.

### D-2. `test/utils.nr` is duplicated across three crates, and part of it need not be

All three copies are 78 code lines; 75 are identical between any pair. Unlike D-1, this is ordinary Noir with no framework constraint — but only *part* of it can move:

- **Cannot move:** `setup`, `setup_and_more_addresses`, `setup_and_mint`, `check_private_balance`. All name the contract type (`crate::CMTATAztec as Token`) and the deploy string, which differ per variant. This is the same constraint as D-1.
- **Can move:** `advance_past_delay` (4 lines) and `call_private_on_behalf_of` (14 lines). Neither mentions a contract type; both are generic helpers over `TestEnvironment`. They are currently maintained in triplicate, and `call_private_on_behalf_of` carries a six-line doc comment explaining the authwit/scopes interaction — the kind of explanation that drifts between copies.

**Verdict: implement, partially.** Move those two into `cmtat_aztec_lib` (a `pub mod test_helpers`, or a fourth `type = "lib"` crate if the project prefers to keep test scaffolding out of the shipped library — the latter is cleaner and costs one manifest). Leave the rest and note in the guide that the per-variant `setup` triplication is structural.

---

## E. Macro and attribute convention drift

### E-1. `#[view]` is missing on four read-only entry points

The contract's own convention is unambiguous — `has_role`, `get_operations`, `token_id`, `version`, `total_supply`, `public_get_name`/`_symbol`/`_decimals`/`_issuer`, `public_get_pause`, `public_get_deactivated` and `get_frozen` all carry `#[view]`. These do not:

| Function | File:line | Mutates state? |
|---|---|---|
| `only_role` | `cmtat-aztec/src/main.nr:136` (all three variants) | No — reads the role map and asserts |
| `terms` | `cmtat-aztec/src/main.nr:298` (all three variants) | No |
| `get_credit_events` | `cmtat-aztec-debt/src/main.nr:324` | No |
| `get_debt` | `cmtat-aztec-debt/src/main.nr:371` | No |

`#[view]` is an enforced guarantee, not a hint. Its absence matters most on `terms`, `get_credit_events` and `get_debt`, which exist to be read by other contracts and by integrators: without it, a caller composing against them cannot rely on their being side-effect-free, and the framework will not stop a future edit from adding a write.

The evidence that this is drift rather than intent is the sibling test: `get_operations` — the same shape of function, in the same banner block, written by the same hand — has it.

**Verdict: implement.** Add `#[view]` to all four in all variants that declare them. The guard is a test that compiles: a caller exercising the read path, so that removing the attribute breaks the build rather than passing silently.

### E-2. Three getters return without `pub`

`terms() -> [Field; 5]` (`:298`), `get_credit_events() -> [Field; 3]`, `get_debt() -> [Field; 16]`, and `total_supply() -> u128` (`:379`) return without the `pub` return marker that every other getter uses (`-> pub Field`, `-> pub FieldCompressedString`, `-> pub AztecAddress`). `total_supply` is the interesting one: it has `#[view]` but not `pub`, so it is not the same omission as the other three and is likely older.

**Verdict: implement** alongside E-1 — same files, same edit, and consistency is the entire value.

### E-3. Attribute discipline elsewhere — checked, clean

- **`#[only_self]`** is present on all three enqueued targets (`_mint`, `_transfer`, `_burn`) in all three variants — 9 of 9. This is the highest-consequence item in this check and there is nothing to report.
- **`#[noinitcheck]`**: zero occurrences. Correct — it is right for pre-funded-account patterns and wrong essentially everywhere else.
- **`#[allow_phase_change]`**: zero occurrences.
- **`#[initializer]`**: exactly one per contract, and `contracts/*/src/test/utils.nr` deploys through it via `with_public_initializer`, so the declared and the called initializer agree.
- **`unconstrained` on `#[external("utility")]`**: one such function (`balance_of_private`), correctly declared `unconstrained`, and no caller treats its result as proven.

---

## F. Standard conformance

### F-1. The project implements CMTAT, not AIP-20 — and does not say so

Checked against `aztec-nr/standards/` and the DeFi Wonderland `aztec-standards` repository as the canonical source. This contract makes **no AIP-20 conformance claim**, and correspondingly has no AIP-20 surface: no `initialize_transfer_commitment` / `complete_from_private` partial-note path, no `PRIVATE_ADDRESS_MAGIC_VALUE`, no `INITIAL_TRANSFER_CALL_MAX_NOTES` / `RECURSIVE_TRANSFER_CALL_MAX_NOTES`, no `asset` / `vault_offset`. There is therefore no conformance gap to report, and the sentinel-conflation bug that the partial-note pattern invites cannot occur here.

That is a coherent position — the token implements the CMTAT functions directly, as the assessment document explains — but it is only coherent to a reader who already knows it.

**Consequence.** An Aztec integrator's default assumption is that a token contract is AIP-20-shaped. Discovering by compile error that `transfer` has a different signature and that the commitment path does not exist costs them the time it takes to read the source.

**Verdict: implement — one sentence in the README.** Something to the effect of *this contract implements CMTAT directly and is deliberately not AIP-20; there is no partial-note transfer path.* The Conclusion of `doc/cmtat-assessment/README.md` already says there is no native token standard on Aztec comparable to ERC-20 and that the contract implements CMTAT functions directly; the README is where an integrator will look first.

---

## G. Code / documentation mismatch

### G-1. `mint`'s NatSpec claims a validation check that does not run — `main.nr:427`

```noir
* - The recipient must respect the allowlist constraints of the validation module.
```

`_mint_internal` (`:405–416`) checks the freeze flag and nothing else; `operateOnTransfer` is called only from `_transfer_internal` (`:509`). The identical claim on `transfer` at `:468` **is** accurate.

This behaviour is already recorded, correctly, in `doc/cmtat-assessment/README.md` — *"mint and burn are not screened by the lists at all … A blacklisted address can therefore still be minted to and burned from"*. So the code is understood and the assessment is right; the defect is the source comment, which tells the opposite story to whoever reads the contract without the assessment beside it.

**Verdict: implement.** Two ways to resolve it and they are not equivalent: either screen mint (a behaviour change with compliance consequences, matching CMTAT Solidity's `RuleBlacklist`, and needing its own test) or correct the comment. The assessment treats the current behaviour as the design, so **correct the comment** and cross-reference the assessment's note — but the choice belongs to whoever owns the compliance posture, not to this review.

### G-2. `_burn_internal` reports the wrong party — `main.nr:540`

```noir
fn _burn_internal(from: AztecAddress, amount: u128) {
    assert(!self.storage.enforcement_module.is_frozen(from), "Frozen: Recipient");
```

There is no recipient in a burn. The caller at `:562` gets it right (`"Frozen: Sender"`), which is how the mistake is visible at all. `_mint_internal:406` uses `"Frozen: Recipient"` correctly, so this looks like a copy from there.

**Consequence.** `burn_batch` reaches `_burn_internal` without the `:562` check, so a frozen holder's batched burn fails with `Frozen: Recipient` — pointing the operator at the wrong address to investigate. On a circuit the assertion message is the only debugging output there is.

**Root cause, addressed separately.** The parameter was called `from`, which implies a counterparty and invites the mint module's wording. CMTAT Solidity avoids this by naming the target of `burn` and `mint` `account`, reserving `from`/`to` for transfers. The burn path has been renamed to match (`burn`, `burn_batch` and `_burn_internal` now take `account`), which removes the conditions that produced the bug rather than only its symptom. `mint` still uses `to`; aligning it too would be a second ABI change and was left.

**Verdict: implement — done**, together with A-1.

The fix was pinned by a test written *before* it and confirmed to fail against the unfixed code, which is the only thing that makes it a regression test rather than a guess:

```
[cmtat_aztec] Testing test::test_enforcement_module::burn_batch_restricted_when_freezed ... FAIL
error: Test failed with the wrong message.
Got: "Assertion failed: Frozen: Recipient"
```

`burn_batch_restricted_when_freezed` freezes a holder and calls `burn_batch`, asserting `"Frozen: Sender"`. It lives in the base variant's suite, which by project convention carries the full test surface. After the fix it passes, and the pre-existing `burn_restricted_when_freezed` (which exercised `burn`, and passed only because the now-deleted duplicate check ran first) still passes.

### G-3. `issuer_address` cannot be changed, and three documents imply it can — `main.nr:383`

```noir
//TODO: we should be able to change the address of the issuer and put some ACL on it
```

The TODO is accurate. `issuer_address` is written exactly once, by `schedule_value_change` in the constructor (`:122`); there is no setter in any of the three variants. Against that:

- `CLAUDE.md` lists `issuer_address` among the `DelayedPublicMutable` values whose changes take `CHANGE_ROLES_DELAY_SECONDS`, which describes a change operation.
- `CHANGELOG.md` states the delay change "affects operators: freezing an account, blacklisting an address **and changing the issuer** now take six minutes rather than two blocks" — a migration note about an operation that does not exist.
- `doc/cmtat-assessment/README.md` describes the issuer as receiving audit copies without qualifying that the address is fixed for the contract's life.

**Consequence.** The issuer address is the audit endpoint for every note this contract ever creates. That it is immutable after deployment — so a compromised or rotated issuer key means redeploying and migrating every holder — is a material operational constraint that no document states and one document contradicts.

**Verdict: decide, and document either way.** Adding a role-guarded setter is small (the storage variable already supports scheduling) and would make the three documents true. Leaving it immutable is defensible for an audit endpoint, but then the CHANGELOG line must be corrected and the constraint stated in the README's limitations.

### G-4. `EXTRA_INFORMATION_ROLE = 11` is missing from two role lists

The code defines eleven roles (`access_controlModule.nr`), and `CLAUDE.md` lists all eleven. Two documents stop at ten:

- `doc/cmtat-assessment/README.md:289` — the criterion-29 implementation-details cell enumerates `DEFAULT_ADMIN_ROLE` 1 … `DEBT_CREDIT_EVENT_ROLE` 10.
- `README.md:544` — the glossary's **Role** entry, same enumeration.

Both were written before the extra-information module existed and were not revisited when it landed. (The assessment's prose count of roles was corrected to eleven during the debt work; these two enumerations were missed.)

**Verdict: implement.** Append `EXTRA_INFORMATION_ROLE` 11 to both.

### G-6. `yarn compile` produces artifacts that `yarn codegen` cannot consume — `package.json:13`

Found while regenerating artifacts after the A-1 fix, not by reading. The build script was:

```json
"compile": "${AZTEC_NARGO:-aztec-nargo} compile --workspace",
```

At 5.2.0, `aztec-nargo` is a bare symlink to `nargo`:

```
/home/ryan/.aztec/versions/5.2.0/bin/aztec-nargo: symbolic link to ../internal-bin/nargo
```

so it compiles Noir but does **not** run the AVM transpiler over the public bytecode. Running the project's own documented sequence — `yarn compile` then `yarn codegen` — therefore fails:

```
Error: Could not generate contract artifact for CMTATAztec:
       Error: Contract's public bytecode has not been transpiled
```

**Why it was not noticed.** `aztec test` transpiles as a side effect. Anyone who runs the tests between compiling and generating — which is the normal working order, and the order `yarn test` enforces — never sees it. It only bites on the pre-release path in `CHANGELOG.md`, which is `yarn clean && yarn compile && yarn codegen` with no test run in between: precisely the clean-tree rebuild the checklist exists to guarantee.

**Verdict: implement — done.** The script is now `${AZTEC_COMPILE:-aztec} compile --workspace`. `aztec compile` runs nargo and then post-processes ("Successfully processed 3 artifact(s)"), and `--workspace` forwards through to nargo unchanged. Verified: `aztec compile --workspace` → `aztec codegen` → `yarn typecheck` all succeed from a compiled tree. The environment override is renamed `AZTEC_COMPILE` because it now names the `aztec` CLI rather than the nargo binary, and `CLAUDE.md` / `AGENTS.md` record why the distinction matters.

### G-5. Doc-comment health and doc pointers — checked, clean

- **Comments referencing documentation files:** zero. Grepped `.nr` sources for `.md`, `docs/`, `doc/` and `See <file>` — nothing. So the failure mode where a docs reorganisation invalidates a pointer baked into deployed source does not exist here.
- **Doc-comment block lengths:** 103 blocks; **median 4 lines, mean 5.3, longest 18**. The three longest (18 lines, one per variant) document `transfer`'s authwit semantics — the caller-vs-`from` distinction, the nonce-zero rule and the replay protection — which is a genuine footgun and earns the space. Next is 17 lines on `pauseModule::deactivate`, documenting an irreversible operation. Nothing in the distribution suggests comments that have outgrown their code.

**Verdict: nothing to do.** Recorded because "the comments are fine" is only credible with the distribution attached.

---

## H. Weird behaviour and privacy leakage

### H-1. `burn` publishes the caller's address and the amount — `main.nr:565`, `:613`

```noir
self.enqueue_self._burn(self.msg_sender(), amount);
...
fn _burn(caller: AztecAddress, amount: u128) {
    self.storage.access_control.only_role(BURNER_ROLE, caller);
```

Every argument to a public function is public, so both `caller` and `amount` are published in the clear. `mint` does the same with the minter and the minted amount.

**Scoping this honestly, because the obvious reading overstates it:**

- The **holder** is not published. `from` stays in the private half; only `msg_sender()` crosses over. A burn from Alice, executed by the issuer under an authwit, publishes the issuer — not Alice.
- The address published **always holds `BURNER_ROLE`** (or `MINTER_ROLE`), and the role table is public state that anyone can already enumerate. So the marginal disclosure is *which* role-holder acted and *when* — not a new identity.
- The **amount is unavoidable**. `total_supply` is a `PublicMutable<u128>` by design and moves by exactly that amount in the same transaction; passing it as an argument reveals nothing the state change does not.

**What remains.** An observer learns that a specific role-holder minted or burned a specific quantity at a specific time. Where the issuer is the sole minter and burner — the expected deployment — that is a public issuance-and-redemption ledger keyed to the issuer, which is arguably what a security token wants. It becomes a real leak only if burner authority is ever delegated to holders, at which point the burner *is* the holder and the burn becomes fully public.

**Verdict: decide — document, do not redesign.** The README's privacy table should state that mint and burn publish the acting role-holder and the amount, and that delegating `BURNER_ROLE` to holders would make their burns public. There is no cheap fix: the role check needs the caller, and moving it into the private half would require reading the role table privately, which is the exact problem `DelayedPublicMutable` exists to solve and would cost a delay on every burn.

### H-2. `mint` hides its recipient and `_transfer` takes no arguments — keep, and protect

Two things this contract gets right, and both are the kind of thing a later "simplification" removes:

- **`mint(to, amount)` enqueues `_mint(msg_sender(), amount)` — `to` never crosses into public.** The recipient of newly issued tokens is exactly what an issuance should hide, and it is hidden. The obvious-looking refactor — pass `to` to `_mint` so the public half can do something with it — would publish it.
- **`_transfer()` takes no arguments at all.** It asserts not-paused and nothing else. `from`, `to` and `amount` all stay private. This is the single most important privacy property in the contract and it is achieved by the public half being deliberately ignorant.

**Verdict: keep, and comment.** A line on `_transfer` saying *this must not take arguments; anything passed here is published* costs nothing and defends a property that no test can assert.

### H-3. The enqueued public selector reveals which operation ran — decide

Tabulating the observable public footprint per private entry point:

| Private entry point | Public calls | L2→L1 messages | Public callee | Public arguments |
|---|---:|---:|---|---|
| `mint`, `mint_batch` | 1 | 0 | `_mint` | minter, amount |
| `transfer`, `transfer_batch` | 1 | 0 | `_transfer` | *none* |
| `burn`, `burn_batch` | 1 | 0 | `_burn` | burner, amount |
| `cancel_authwit` | 0 | 0 | — | — |
| `private_get_*` | 0 | 0 | — | — |

**The good news:** the *count* does not distinguish the three value-moving operations — all enqueue exactly one public call and produce no L2→L1 messages. Count-based fingerprinting, which the framework documentation identifies as the leak that padding does not cover, does not apply. Note hashes, nullifiers and private logs are padded by the protocol, so the differing note counts (mint 1, transfer 2, burn 1) are not distinguishing either.

**What does distinguish them** is the callee: `_mint`, `_transfer` and `_burn` are three different public functions, so an observer sees which of the three occurred. For transfer that reveals only "a transfer happened", which is unavoidable and harmless. For mint and burn it composes with H-1.

`cancel_authwit` enqueues nothing, so it is distinguishable from every value-moving operation by having zero public calls — but it also moves no value, so there is little to learn.

**Verdict: decide, and the honest answer is probably "document".** Collapsing the three public halves into one `_post_op(kind, …)` would hide the selector but move `kind` into the arguments, publishing the same fact one level down; it only helps if the operation kind can be folded into something already public, which it cannot here. Padding every private entry point to a common public-call count is already satisfied. The residual leak is small and structural — worth a row in the README's privacy table rather than a redesign.

### H-4. The `Transfer` event's DA record — see C-2

The privacy angle on C-2: `onchain_unconstrained()` posts a log to data availability whose recipient set is `{to}`. The content is encrypted, so this does not publish `from`/`to`/`amount` in the clear, but it does add a durable onchain artifact tied to the transaction, on top of the two note messages already delivered `onchain_constrained()`. Since the recipient does not depend on it, it is DA cost and an extra artifact for no guarantee.

**Verdict: decide — folded into C-2.**

### H-5. Patterns checked and absent

- **`self.enqueue(...)` to another contract:** none. The contract makes no cross-contract calls at all, so the "enqueueing publishes `msg_sender`" leak has no site beyond the `enqueue_self` calls analysed in H-1. `enqueue_incognito` is therefore not applicable.
- **L2→L1 messages:** none anywhere, so the "fully public message and L1 execution" exposure does not arise.
- **Unsupported primitives in public functions:** none. No ECDSA, AES-128, Blake2s or Blake3 in any `#[external("public")]` function, so the transpiler-panic failure mode does not apply. Public code uses only comparisons, arithmetic and state access.
- **Cross-contract utility calls:** none, so no getter depends on the wallet's `authorizeUtilityCall` hook. The one utility function (`balance_of_private`) reads only this contract's own notes.
- **Hardcoded "everything is fine" answers:** none found. `operateOnTransfer` returning without checking when no mode is enabled is the closest thing, and it is documented behaviour in both the module and the assessment rather than a stub.

---

## I. Dependency and interface granularity

### I-1. The workspace graph — checked, clean

| Crate | Type | Depends on |
|---|---|---|
| `cmtat_aztec_lib` | `lib` | aztec, compressed_string, uint_note, balance_set |
| `cmtat_aztec` | `contract` | the above + `cmtat_aztec_lib` (path) |
| `cmtat_aztec_debt` | `contract` | same |
| `cmtat_aztec_light` | `contract` | same |

- **No contract crate depends on another contract crate**, so the circular generated-interface hazard the framework warns about does not exist here.
- **No crate pulls in a whole contract to call one function**, because there are no cross-contract calls at all.
- **Shared code is in a `type = "lib"` crate**, which is the required structure and is what makes the three variants possible.

**One prose obligation worth naming:** `issuer_address` is documented as the party that must capture offchain note messages, and nothing in the contract can check that it does — the CHANGELOG's Security section states this plainly ("a sender who drops one is not detectable onchain"). Aztec has no ERC-165 equivalent, so **no interface check could be added even in principle**; this remains operational discipline and is correctly documented as such rather than guarded by code that could not exist.

**Verdict: nothing to do.**

---

## J. Modularity

### J-1. The generic type parameters are decorative, because their trait bounds are private

`ValidationModule<T, Context>` and `Freezable<T, Context>` are generic in `T`, bounded on `UserFlagsTrait` (`validationModule.nr:35`) and `FreezableFlagTrait` (`enforcementModule.nr:16`). Neither trait is `pub`.

**Verified by compiling a probe** — a separate contract crate depending only on `cmtat_aztec_lib`, declaring its own three-flag type and implementing the trait:

```
error: UserFlagsTrait is private and not visible from the current module
   ┌─ src/main.nr:12:28
   │
12 │         validationModule::{UserFlagsTrait, ValidationModule},
   │                            -------------- UserFlagsTrait is private
```

So `T` can only ever be the module's own `UserFlags` / `FreezableFlag`. Every declaration site in the repo confirms it: `ValidationModule<UserFlags, Context>`, `Freezable<FreezableFlag, Context>` in all three storage structs.

**Consequence.** The genericity reads as an extension point and is not one. A downstream contract wanting blacklist/whitelist plus one extra flag — the obvious first customisation — cannot have it, and discovers this only at compile time.

**Verdict: implement — two words.** Make both traits `pub`. There is no downside: they are already implemented for the module's own types and exporting them costs nothing. Then the type parameter means what it appears to mean.

### J-2. ⚠️ Corrected — tests live in the contract crates, but the compiler does not object

`#[test]` functions live inside the contract crates (`contracts/*/src/test/*.nr`, 75 tests across three crates), not in separate test crates. General Aztec guidance holds that `aztec compile` warns about this.

**It does not, at 5.2.0.** A full `aztec-nargo compile --workspace` produced 33 warnings, all of them from aztec-nr's macro expansion and none mentioning tests. The expected warning did not reproduce, and I am recording that rather than repeating the claim.

**What remains true** is the build-time consequence: `#[test]` functions in a contract crate are part of that crate's compilation unit, so a test-only edit recompiles the contract. With three contract crates and a workspace build measured in minutes, that is a real cost on the inner loop — but it is a build-time consideration, not a correctness or convention violation, and the current layout keeps each variant's tests beside the variant they exercise, which has its own value (see D-2 for why `setup` cannot be shared anyway).

**Verdict: leave.** Reported so that the next reviewer who reaches for the "tests in the wrong crate" finding sees that it was checked and that the usual evidence for it is absent here.

### J-3. The module structs are genuinely reusable — verified by compilation

The central Aztec modularity question is whether a *different* contract can hold one of this project's modules in its own `#[storage]`. Because `#[storage]` may be used once per contract, the unit of storage reuse must be a struct implementing `StateVariable<N, Context>` with `new(context, storage_slot)` and `get_storage_slot` — which is exactly what every module here does.

**This was tested rather than asserted.** A throwaway contract crate (`probe_reuse`) depending only on `cmtat_aztec_lib` was written to hold `AccessControlModule` and `ValidationModule<UserFlags>` in its own storage struct, expose `set_operations` / `get_operations`, and — the part that matters — call `operateOnTransfer` from a **private** function:

```noir
#[storage]
struct Storage<Context> {
    access_control: AccessControlModule<bool, Context>,
    validation_module: ValidationModule<UserFlags, Context>,
}

#[external("private")]
fn guarded_op(from: AztecAddress, to: AztecAddress) {
    self.storage.validation_module.operateOnTransfer(from, to);
}
```

**It compiles, with no changes to the library.** The probe crate was then deleted.

That is a stronger result than "the code looks modular": a downstream project can lift the validation module — including its private-context read path, which is the hard part — into an unrelated contract. The same shape applies to `PauseModule`, `Freezable` and `ExtraInformation`.

**Two caveats the probe also established:**

1. It works because `UserFlags` is the library's own type. Substituting a custom flag type fails on J-1.
2. The modules take their `AccessControlModule` as an explicit parameter (`ac: AccessControlModule<bool, PublicContext>`) rather than reaching for `self.storage.access_control`. That is the hook pattern, done right: a host supplies its own access control instead of being forced to have a field with a particular name and semantics. It is the single design decision that makes the probe compile, and it is worth naming so that a future refactor toward "convenience" does not undo it.

**Verdict: keep — and consider promoting the probe.** If reuse is a property the project wants to hold, the probe crate belongs in the workspace as a compiling test fixture; otherwise the property regresses silently the first time a module reaches into its host's storage. That said, this project has three known deployments and no prospective external consumer, so **do not manufacture further modularity work here** — the structure is already better than it needs to be for its current use.

### J-4. Legibility — checked, clean

```
./lib/Nargo.toml                          type = "lib"        (no contract — correct)
./contracts/cmtat-aztec/Nargo.toml        type = "contract"   pub contract CMTATAztec
./contracts/cmtat-aztec-debt/Nargo.toml   type = "contract"   pub contract CMTATAztecDebt
./contracts/cmtat-aztec-light/Nargo.toml  type = "contract"   pub contract CMTATAztecLight
```

Every `type = "contract"` crate contains exactly one `pub contract`, whose name matches the directory. The `type = "lib"` crate contains no contract and is named for what it is. No crate has grown a second conceptual contract inside one `#[aztec]` module. A reader can tell what each crate is from its name and manifest.

---

## Method and limitations

**What was run.** `aztec-nargo compile --workspace` (clean, exit 0); `aztec test --workspace` (75 tests passing at review time: 62 base, 9 debt, 4 light; 76 after the A-1/G-2 regression test); `aztec profile gates ./target` for the baseline and for three before/after comparisons; two throwaway contract crates compiled for J-1 and J-3 and deleted; a full-text sweep of `.nr` sources for doc pointers, attribute usage, emit sites and trait visibility.

**What was reasoned about but not executed.**

- **Whole-transaction cost.** `aztec-wallet profile` needs a running sandbox, which this review did not start. Every kernel figure quoted (~290k fixed, ~101k per private call) is from the framework documentation, not measured here, and is used only to argue about the shape of a change — never as a finding's evidence.
- **Public gas.** Nothing in B-3, B-4 or the public halves was measured in gas. Where a public-side saving is claimed it is stated as a change in `Packable::N` (a slot count), with the measurement gap named.
- **The e2e suite.** `yarn test:js` was not run; it needs a sandbox and the `CHANGE_ROLES_DELAY_SECONDS` wait. No finding depends on it.

**Before acting on any structural finding**, note the refactoring hazards that apply to this contract specifically:

- **B-1 and B-3 are storage-layout changes.** `#[storage]` allocates slots sequentially in declaration order, so changing any module's packed length moves every state variable declared after it and orphans the public state at the old slots.
- **There is no upgrade path.** The contract is not upgradeable and there is no proxy; the CHANGELOG says so. A storage change is a redeployment plus a holder migration, and because balances are notes in holders' own PXEs, the issuer cannot perform that migration unilaterally. Nothing in this report should be deferred to "we can fix it in an upgrade".
- **Note layout is untouched by every finding here**, which is fortunate: the storage slot feeds the note hash and the note hash feeds the nullifier, so a change there would make existing notes unspendable. No recommendation in this report alters `UintNote` or the `balance_set` layout.
- **E-1/E-2 do not change the ABI** (attributes and return markers only), so no TypeScript regeneration is forced. C-1/C-3/C-4 add events, which do change the artifact; `yarn codegen` and `yarn typecheck` must run in the same change.

**How to guard what this report recommends.** For A-1, the guard is not a unit test — a functional test cannot see a gate count. Capture `aztec profile gates --json ./target` and diff it in CI. For E-1, the guard is a test that *compiles*: a caller exercising the read path, so removing `#[view]` breaks the build. For G-1 and G-4, the "test" is against the documented claim, not the code.

---

*Produced with Claude Code against `aztec` 5.2.0 / `aztec-nr` v5.2.0 / Noir 1.0.0-beta.25, commit `6728a8a`, on 2026-09-09. Findings were verified against the code at that commit; line numbers drift.*

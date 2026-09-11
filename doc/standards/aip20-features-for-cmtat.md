# AIP-20 features that CMTATAztec could adopt while staying CMTAT-equivalent

The third step of a three-step plan. Step one brings the [`aztec-standards`](https://github.com/defi-wonderland/aztec-standards) fork to Aztec 5.2.0 ([`upgrading-aztec-standards.md`](./upgrading-aztec-standards.md)); step two packages the compliance modules as an ARC-403 authorization contract for a stock AIP-20 token, with its known limits on mint and burn ([`cmtat-as-aip20-auth-contract.md`](./cmtat-as-aip20-auth-contract.md)). This document is step three: **which AIP-20 features can be brought into the CMTAT token itself without breaking its equivalence to CMTAT, and in what order.**

## Table of contents

- [The test each feature has to pass](#the-test-each-feature-has-to-pass)
- [A correction that changes the answer](#a-correction-that-changes-the-answer)
- [Summary table](#summary-table)
- [F1 — Note budget with recursive subtraction](#f1--note-budget-with-recursive-subtraction)
- [F2 — Commitment transfers, screened at initialization](#f2--commitment-transfers-screened-at-initialization)
- [F3 — A rule-engine hook, in the ARC-403 shape but complete](#f3--a-rule-engine-hook-in-the-arc-403-shape-but-complete)
- [F4 — AIP-20 entry-point names](#f4--aip-20-entry-point-names)
- [F5 — The private-party marker in public events](#f5--the-private-party-marker-in-public-events)
- [F6 — Public balances](#f6--public-balances)
- [F7 — Named constructors](#f7--named-constructors)
- [Rejected — features that are not CMTAT-compatible](#rejected--features-that-are-not-cmtat-compatible)
- [Recommended order](#recommended-order)
- [What each feature changes in the equivalency assessment](#what-each-feature-changes-in-the-equivalency-assessment)

## The test each feature has to pass

Four questions, asked of every feature:

1. **CMTA equivalency.** Does any of the 61 criteria in [`doc/cmtat-assessment/README.md`](../cmtat-assessment/README.md) regress — in particular any of the 19 mandatory ones? Does any improve? The standard is the *Solidity* CMTAT and the criteria mapped from it; nothing in it names a function or forbids an extra capability, so most features pass this test trivially. The ones that fail are the ones that change *who may do what*.
2. **The CMTA privacy table.** The equivalency assessment carries a *Privacy and Confidentiality* section — outside the count, but the section that makes this a **private** CMTAT rather than merely a CMTAT. It tabulates nine data items and, for each, its visibility in the implementation and whether the issuer can still see it: balance of an address, transfer amount, transfer participants, total supply, decimals, frozen/blacklisted addresses, allowlisted addresses, roles, pause status. Today the first three are `private` and everything else `public`, and the issuer sees all nine. **A feature that moves any row from `private` toward `public`, or takes a row away from the issuer, changes the privacy table and must be disclosed there.** That is the test this section applies.
3. **Which product it belongs in.** Two products are in scope:
   - **CMTAT-private** — the three variants that exist today (`CMTATAztec`, `CMTATAztecDebt`, `CMTATAztecLight`), keeping CMTAT's own names and surface, no AIP-20 entry points.
   - **CMTAT-private-AIP20** — a variant that integrates AIP-20: its entry-point names, its commitment flow, and whatever else from the standard survives the first two tests. Still private by construction; still CMTAT-equivalent.
   A feature can belong in both, in one, or in neither.
4. **Cost and prerequisites.** Gates, measured where they could be; ABI or storage breaks; what must be true before starting.

Everything measured below was measured on Aztec 5.2.0, on this repository's `CMTATAztec` and on the `aztec-standards` token forked to the same version.

## A correction that changes the answer

The comparison document originally said that commitment transfers cannot be screened because "the recipient is not yet determined when funds are locked". **That is what the Aztec documentation's prose says, and it is wrong about the contract.** The source is:

```noir
fn initialize_transfer_commitment(to: AztecAddress, completer: AztecAddress) -> Field
// → UintNote::partial(to, self.context, to, completer)
```

The recipient is a parameter of initialization and the partial note is bound to it. What the contract does not know until later is the **sender** and the **amount**, which arrive in `transfer_private_to_commitment(from, commitment, amount)`. `PRIVATE_ADDRESS_MAGIC_VALUE` is not a "recipient unknown" sentinel; it appears only in the token's *public* events, standing in for whichever party holds a private balance.

The consequence for this document: **the commitment path is not excluded** — it is a screening-at-initialization design with a timing gap that has to be bounded. That moves F2 from "rejected" to "second priority", and it is the single largest change from the earlier analysis. The comparison document's Conflict 2 has been corrected to match.

## Summary table

| # | Feature | CMTA equivalency (61 criteria) | CMTA privacy table (9 rows) | CMTAT-private | CMTAT-private-AIP20 | Cost | Verdict |
|---|---|---|---|---|---|---|---|
| F1 | Note budget with recursive subtraction | Neutral | **Unchanged** | ✔ | ✔ (inherits) | **−43,046 gates** per transfer, common case (measured); a recursive kernel iteration when fragmented | **Do first, in both** |
| F2 | Commitment transfers, screened at initialization | Neutral; enables delivery-versus-payment | **Changes two rows** — *transfer amount* becomes visible-but-unlinked on the commitment path; *issuer availability* holds only with an added delivery | ✘ — keep the direct path only | ✔ — the defining feature, with three additions | New entry points, one storage field | **Second, AIP20 variant only** |
| F3 | Rule-engine hook passing recipient and caller | **Improves** — CMTAT's `RuleEngine`, criteria 26–28 | Unchanged **if the engine runs private**; an engine that enqueues public leaks *transfer participants* | ✔ | ✔ | ~101,000 gates per transfer when set, ~0 unset (docs figure) | **Third, in both** |
| F4 | AIP-20 entry-point names | Neutral | Unchanged | ✘ — CMTAT names stay | ✔ | ABI break, five renames; `burn` excluded | **AIP20 variant, bundled with F2** |
| F5 | Private-party marker in public events | Neutral | Unchanged — it is what *keeps* participants private if public events are ever emitted | ✘ (no public events) | ✔ when public events exist | Trivial | **With public events, if ever** |
| F6 | Public balances | Neutral — CMTAT Solidity *is* public | **Changes three rows** — *balance*, *transfer amount* and *participants* become `public` on the public side | ✘ | ✘ — contradicts "private" in both names | Every path re-guarded | **A fifth, hybrid variant at most** |
| F7 | Named constructors | Neutral | Unchanged | ✘ | ✔ | Trivial | **AIP20 variant, optional** |
| — | Holder self-burn | **Regresses criterion 11** | — | ✘ | ✘ | — | **Rejected** |
| — | Single immutable minter | **Regresses 29–31** | — | ✘ | ✘ | — | **Rejected** |

Read as a product map: **CMTAT-private gains F1 and F3 and nothing else; CMTAT-private-AIP20 is CMTAT-private plus F2, F4, F5 and F7.** F6 belongs to neither, because both are named *private* and F6 is the one feature that makes a balance public.

## F1 — Note budget with recursive subtraction

**What AIP-20 does.** A transfer first tries to settle with at most `INITIAL_TRANSFER_CALL_MAX_NOTES = 2` notes. If the sender's balance is more fragmented than that, the contract recurses into itself through an `#[only_self]` function at `RECURSIVE_TRANSFER_CALL_MAX_NOTES = 8` per level until the amount is covered.

**What this token does.** `BalanceSet::sub` hardcodes its budget to `MAX_NOTE_HASH_READ_REQUESTS_PER_CALL` (16), so every transfer and burn sizes its circuit for sixteen notes regardless of how many the sender holds.

**Equivalency.** Neutral. No criterion mentions note handling. The comparison document's suggestion C-1 proposes that CMTAT *require* the bound be documented — adopting F1 would make this repository the worked example.

**Privacy table.** Unchanged. No data item's visibility moves and the issuer still receives the change note.

**Premise.** Fully compatible. The compliance checks (freeze, lists, issuer read) run once at the entry point before any note is touched; the recursion only consumes notes and neither reads compliance state nor delivers messages. The change note is still produced once, at the end, and delivered to the sender and the issuer exactly as today. The invariant chain is untouched.

**Cost, measured.** Replacing the sixteen-note `sub` in `_transfer_internal` with a two-note budget moved `transfer` from **120,824 to 77,778 gates — 43,046 saved, 36%**, on the proof the sender's device produces. That is the common-case figure. A sender whose balance needs three to eight notes pays a recursive call instead — one extra private kernel iteration, roughly 101,000 gates by the framework's figure — and is worse off than today. So the feature wins if most transfers settle in one or two notes and loses otherwise.

**Prerequisites.**

- **Measure the note-count distribution of realistic holders before choosing the budget.** That number is unknown and it is the whole decision. Two is AIP-20's choice for a DeFi token; a security token with infrequent, large transfers may justify two, or may justify four.
- **Re-measure the batch cap.** `MAX_ADDR_PER_CALL = 4` was established with no nested private calls in a batch. Recursion *is* a nested private call, and the protocol allows eight per call; four recipients each recursing once is four, plus whatever the recursion itself nests. The cap may hold or may need to drop, and only a run at each value will say.
- **Interaction with the issuer copy.** The recursive step subtracts and returns change; the delivery of the final change note must remain at the top level, where the issuer address has already been read. Structure the recursion so it never delivers.

**Verdict: do first, in both products.** It is the only feature that pays for itself with no design trade, and its prerequisite is a measurement, not an architecture decision.

## F2 — Commitment transfers, screened at initialization

**What AIP-20 does.** Three entry points:

| | Knows | Screens (in this design) |
|---|---|---|
| `initialize_transfer_commitment(to, completer)` | the recipient, the permitted completer | **`to`** — freeze and lists |
| `transfer_private_to_commitment(from, commitment, amount, nonce)` | the sender, the amount | **`from`** — freeze and lists; the authwit |
| `mint_to_commitment(commitment, amount)` | the amount | **`MINTER_ROLE`** on the caller |

The commitment is bound to a *completer* — the address permitted to finalize it, checked at completion via a validity commitment in the nullifier tree — which is a control point CMTAT can use.

**What it enables.** Delivery-versus-payment and primary subscription: an investor initializes a commitment (and is screened doing so), the counterparty or the issuer pays into it when the other leg settles. The comparison document's suggestion C-3 records that CMTAT has no criterion for this because account-model ledgers never needed one. It is the capability that would let a CMTAT token trade on-chain.

**Equivalency.** Neutral: no criterion regresses, because every screening the criteria require still runs — on `to` at initialization, on `from` at completion. Criteria 26–27 (conditional transfer) do not become `y`; a commitment is not an approval mechanism.

**Privacy table — two rows change, and this is the reason F2 is confined to the AIP20 variant.**

| Row | Today | On the commitment path |
|---|---|---|
| Transfer amount | `private` — inside an encrypted note | **visible, unlinked** — the completion log carries the value unencrypted; an observer who cannot compute the tag cannot attach it to a recipient, but the number is there |
| Transfer participants | `private` | `private` — the commitment reveals neither party |
| Available to the issuer | `y` | `y` **only with addition 2 below**; without it the issuer never learns of the partial note |

The other seven rows are unchanged. Because the assessment answers *transfer amount* as `private` today, a token that ships F2 must answer it `private on the direct path; visible but unlinked on the commitment path`, and say so in the note. That is a disclosure, not a disqualification — but it is why CMTAT-private, whose value is the unqualified answer, does not get F2.

**Premise — compatible, with three additions that are each mandatory.**

1. **An expiry on the commitment.** The recipient is screened at initialization and cannot be re-screened at completion, because at that point the contract holds only the commitment. If `to` is frozen or delisted in between, the transfer still completes. This token already accepts a bounded window of that kind — `CHANGE_ROLES_DELAY_SECONDS`, documented under *Enforcement* in the assessment — but AIP-20 puts **no bound** on the life of a commitment. A commitment initialized in January and completed in June carries January's screening. The addition is a timestamp in the partial note's public data and an `assert(now < expiry)` at completion. Without it, F2 fails the premise.
2. **A second delivery to the issuer at initialization.** The library's `UintNote::partial` delivers its private log to exactly one `recipient` (`do_private_message_delivery(..., recipient, onchain_unconstrained())`) and returns no message the caller can re-deliver. The token's "issuer receives a copy of every note" rule therefore cannot be met with the library call as it stands. Either the token sends a second, explicit message to the issuer carrying the commitment's preimage, or `partial` is forked to accept a second recipient. Both are small; one of them is required.
3. **Accepting that the completion amount is not encrypted.** `complete_from_private` emits the completion as an *unencrypted* private log — `emit_private_log_unsafe(log_tag, [storage_slot, value])`, per the library's own comment — tagged by the commitment so the recipient can find it. An observer who cannot compute the tag cannot link the log to a recipient, but the **value is visible**. On the direct transfer path the amount is inside an encrypted note; on the commitment path it is not. The README's per-operation privacy requirement — "only the issuer and the receiving address should know the amount" — would have to carve out the commitment path explicitly, and an issuer deciding whether to enable F2 must know this.

**Cost.** New entry points and one storage field for the expiry — an ABI change and a storage-layout change, so it belongs in the same release as any other break. Gates were not measured; the library's `transfer_private_to_commitment` profiles at 41,527 on the fork, and this token would add its compliance reads to that.

**Verdict: second, after F1, in CMTAT-private-AIP20 only, and only with all three additions.** It is the one feature that gives the token something it structurally cannot have today — and the one that qualifies a privacy-table answer, which is why the unqualified product does not carry it.

## F3 — A rule-engine hook, in the ARC-403 shape but complete

**What AIP-20 does.** An `auth_contract: PublicImmutable<AztecAddress>` called on every transfer and burn with `(from, amount, selector)`; zero address disables it.

**What CMTAT does.** `ValidationModuleRuleEngine` — a pluggable, *settable* external `RuleEngine` receiving `from`, `to`, `value` and the spender, behind which the Rules repository supplies whitelist, blacklist, sanctions, max-balance, conditional-transfer and per-minter-quota rules. This token merged the engine into the validation module; the assessment's Restriction table records "RuleEngine / transfer hook — ✘".

**The feature, then, is not AIP-20's hook but CMTAT's own extension point, in ARC-403's calling convention and with its omissions repaired:**

```noir
rule_engine: DelayedPublicMutable<AztecAddress, CHANGE_ROLES_DELAY_SECONDS, Context>,
```

```noir
// in _transfer_internal, after the built-in checks
let engine = self.storage.rule_engine.get_current_value();
if !engine.is_zero() {
    self.call(RuleEngine::at(engine).validate_transfer(from, to, amount, self.msg_sender(), selector));
}
```

Passing **`to`** and the **original caller** — the two arguments ARC-403 lacks — is what makes it able to express CMTAT rules. Making it `DelayedPublicMutable` rather than `PublicImmutable` is what makes it a CMTAT rule engine rather than an AIP-20 hook: settable under `VALIDATION_ROLE`, after the delay, readable from private.

**Equivalency — improves.** Restriction table row "RuleEngine / transfer hook" becomes ✔. Criteria 26–28 (conditional transfer, whitelist assignment through an engine) become answerable through an external rule, and the Restriction table's `n` rows for max balance, aggregated whitelists, receiver-only whitelist and per-minter quota become reachable without touching the token.

**Privacy table.** Unchanged provided the engine runs privately. An engine that enqueues a public call to read a `PublicMutable` publishes the sender on every transfer — the *transfer participants* row moves to `public` for the sender — so the extension point must state that an engine MUST NOT enqueue, and the assessment note must say what the deployed engine does.

**Premise.** Compatible provided the engine itself runs privately — reads `DelayedPublicMutable` state and enqueues nothing — which the [authorization-contract probe](./cmtat-as-aip20-auth-contract.md) demonstrates is achievable. An engine that enqueues a public call publishes the caller; that is the engine author's responsibility and must be documented at the extension point.

**Cost.** When no engine is set: one delayed read and a branch, on the order of the 1,920 gates a delayed read measured at in the code-quality review. When set: a cross-contract private call, roughly **101,000 gates per transfer** by the framework's figure — not measured here — plus the engine's own circuit. That is the price CMTAT Solidity does not pay for its `RuleEngine`, and it should be stated next to the setter.

**Verdict: third, in both products.** It is how CMTAT's own extension model looks on Aztec, and this repository's module library already provides everything an engine needs.

## F4 — AIP-20 entry-point names

Covered in detail in [`building-on-aip20.md`](./building-on-aip20.md#interface-alignment--an-aip-20-private-profile). Renaming `transfer`, `mint`, `public_get_name`, `public_get_symbol` and `public_get_decimals` to AIP-20's names makes them answer AIP-20's selectors exactly — verified by computing selectors on both artifacts; parameter names are not part of the selector, so `authwit_nonce` stays. `balance_of_private` and `total_supply` already match.

**Equivalency.** Neutral; no criterion names a function. The assessment's implementation-details cells that name them must be updated.

**Premise.** Compatible.

**Exclusion.** `burn` must not be renamed to `burn_private`: AIP-20's is holder-authorised, CMTAT's requires `BURNER_ROLE`, and an identical selector with different authorisation is a trap.

**Verdict: CMTAT-private-AIP20 only, bundled with F2.** CMTAT-private keeps CMTAT's names — that is part of what makes it the reference product. In the AIP20 variant both are ABI breaks; one release, one migration note.

## F5 — The private-party marker in public events

`PRIVATE_ADDRESS_MAGIC_VALUE` in a *public* log wherever one party's balance is private, distinct from the zero address. This token emits its `Transfer` event privately to the recipient, so today nothing needs it. If the open event-coverage items from the code-quality review (C-6) are ever answered with public events, the marker is the right idiom and costs nothing.

**Verdict: adopt when public events are added, not before.**

## F6 — Public balances

**Equivalency — neutral, and worth being precise about why.** CMTAT Solidity's balances are entirely public. Nothing in the criteria requires privacy; the Privacy and Confidentiality section of the assessment sits outside the count. A hybrid token would remain CMTAT-equivalent.

**Privacy table — three rows change.** *Balance of an address* moves from `private` to `private or public, at the holder's choice`; *transfer amount* and *transfer participants* become `public` on every public-side path. That is the largest privacy-table change of any feature here, and it is the reason F6 is excluded from **both** products: each is named *private*, and F6 is the one feature that makes a balance public.

**Premise — contradicts it.** The README's assumptions are that balances and transfers are private and only supply is public. Adding `public_balances` and the hybrid paths adds a transparent second ledger, and every public path then needs the full invariant chain — freeze, lists, role, pause — re-implemented in public context, doubling the compliance surface to test and audit.

**A narrow form that might be legitimate:** a single issuer-owned public balance — a treasury — rather than public balances for everyone. Even that adds the hybrid paths.

**Verdict: in neither product.** If an issuer needs it, it is a separate *hybrid* variant with its own assessment and its own privacy table, not a change to CMTAT-private or CMTAT-private-AIP20 — both of which are named for the property F6 removes.

## F7 — Named constructors

`constructor_with_initial_supply` and `constructor_with_minter` are conveniences. Neutral on every axis; a matter of deployment ergonomics. Optional.

## Rejected — features that are not CMTAT-compatible

Two AIP-20 behaviours fail the first test outright and are recorded so they are not proposed again:

- **Holder self-burn.** AIP-20's `burn_private` is holder-authorised only. CMTAT's criterion 11, *Cancel tokens*, is an issuer act under `BURNER_ROLE`; allowing any holder to redeem unilaterally regresses it. This is also why F4 excludes the rename.
- **A single immutable minter.** AIP-20's `minter: PublicImmutable<AztecAddress>` cannot be granted, revoked or shared. Criteria 29–31 require administered roles; the token already has them.

## Recommended order

**CMTAT-private** (the three existing variants):

1. **F1** — measure the note-count distribution, then implement the budget and recursion, then re-measure the batch cap. No ABI or storage change; can ship alone.
2. **F3** — the rule engine, `DelayedPublicMutable`, unset by default, with the "an engine MUST NOT enqueue" rule at the extension point.

That is the whole list. CMTAT-private keeps its names, its single transfer path and its unqualified privacy table.

**CMTAT-private-AIP20** (a fourth variant, `CMTATAztecAIP20` or similar):

1. **F1** — inherited.
2. **F2 + F4 + F7** together — commitment entry points with expiry, issuer delivery and the documented amount exposure; the five renames; the named constructors. One ABI break, one storage break, one migration note, one privacy-table disclosure.
3. **F3** — inherited; and once F2 exists, a conditional-transfer rule gating settlement is the first engine anyone will want.
4. **F5** — when public events are added.

**Neither:** F6. A hybrid variant, or never.

## What each feature changes in the equivalency assessment

| Feature | Assessment change |
|---|---|
| F1 | None to answers. Add the note bound and its behaviour to the *Transfer* note, per suggestion C-1 |
| F2 | No criterion answers change. **Privacy table:** *transfer amount* becomes `private on the direct path; visible but unlinked on the commitment path`, and *available to the issuer* is `y` only because of the added delivery — both stated in the note. New Supplementary-features entry; the Enforcement note records the commitment expiry as a second bounded window. Applies to the AIP20 variant's assessment only |
| F3 | Restriction table: "RuleEngine / transfer hook" ✘ → ✔; criteria 26–28 re-examined; the per-transfer cost recorded next to the setter. **Privacy table:** unchanged, with a note that the deployed engine runs private and enqueues nothing |
| F4 | Implementation-details cells that name `transfer`, `mint`, `public_get_*` updated; a note that the private profile matches AIP-20 selectors and that `burn` deliberately does not |
| F6 | A separate assessment for the separate variant, whose privacy table would answer *balance*, *transfer amount* and *participants* as `public` on the public side |

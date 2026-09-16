# A second payment into the same commitment (K-6)

> **Status (2026-09-16): open, documented.** Finding `K-6` of the [0.4.0 review](../audits/tools/v0.4.0/CLAUDE_ANALYSIS.md). The behaviour is measured by `a_second_payment_into_the_same_commitment_is_lost` in `tests/cmtat-aztec/src/test_edge_cases.nr`; the README states the wallet rule. Nothing in the contracts has changed.

A design note on one property of the commitment flow that the private/public bridges inherited from AIP-20: a commitment can be paid into more than once, and the recipient's wallet sees only the first payment. What happens, exactly, in CMTAT-Aztec and in the AIP-20 reference; what the earlier assessment got right and what it did not; and the ways the project could respond, from doing nothing to a one-line contract change.

## Table of contents

- [The commitment flow in one page](#the-commitment-flow-in-one-page)
- [What happens on a second payment](#what-happens-on-a-second-payment)
- [CMTAT-Aztec and AIP-20 side by side](#cmtat-aztec-and-aip-20-side-by-side)
- [Consequences specific to a security token](#consequences-specific-to-a-security-token)
- [Checking the earlier assessment](#checking-the-earlier-assessment)
- [Options](#options)
- [Comparison](#comparison)
- [Recommendation](#recommendation)
- [Verification plan](#verification-plan)

## The commitment flow in one page

A **partial note** is a `UintNote` whose private part — owner and randomness — is fixed first, and whose value is filled in later by someone else. `UintNote::partial(owner, context, recipient, completer)` (aztec-nr v5.2.0, `uint_note.nr`) does three things:

1. computes the **commitment** `C = H(owner, randomness)` — the only thing the payer ever sees;
2. sends the recipient a private message so its PXE registers the partial note as *pending*, keyed by `C`;
3. pushes a **validity commitment** `V = H(C, completer)` to the nullifier tree — a proof, readable by anyone, that *this contract* created *this* partial note for *this* completer.

Completion — `PartialUintNote::complete` in public or `complete_from_private` in private — checks that `V` **exists** (it does not consume it), emits a log tagged `T = H(C, DOM_SEP__NOTE_COMPLETION_LOG_TAG)` whose payload is `[storage_slot, value]` in clear, and pushes the note hash `H(slot, [C, value])`. The recipient's PXE finds the log by the tag `T`, pairs it with the pending partial note, and now holds a spendable `UintNote`.

In this repository the flow is reached through three entry points, present in all three token variants behind the `public_side_enabled` flag:

| Entry point | Who calls | What it does with the commitment |
|---|---|---|
| `initialize_transfer_commitment(to, completer) -> C` | the recipient, or anyone on its behalf | opens the partial note for `to`, completable by `completer`; screens `to` (`Screening::recipient`); emits `CommitmentInitialized { to, completer, C }` constrained to the issuer |
| `transfer_private_to_commitment(from, C, amount, nonce)` | the completer | screens `from`, spends its notes (issuer gets the change-note copy), completes `C` with `amount` **from private** (`complete_from_private`), enqueues the argument-less `_transfer` pause check |
| `transfer_private_to_public_with_commitment(from, to, amount, nonce) -> C` | the sender | a private→public transfer to `to` **plus** a fresh commitment for `to` that the sender may later complete |

The shared code is `open_commitment` / `pay_commitment` in `lib/src/modules/tokenModule.nr` and `initialize_commitment` / `complete_commitment` in `lib/src/modules/hybridModule.nr` (MIT-only, derived from AIP-20).

## What happens on a second payment

Nothing in the library or in either contract records that a commitment has been completed. The completion check is *existence* of `V`, and `V` stays in the nullifier tree forever. So a second `transfer_private_to_commitment(from, C, amount', nonce')` by the same completer is a perfectly valid transaction:

- the completer's notes are spent again — `from` is debited `amount'`;
- a second completion log with the **same tag** `T` is emitted, payload `[slot, amount']`;
- a second note hash `H(slot, [C, amount'])` is inserted — a distinct leaf even for `amount' = amount`, because the protocol makes leaves unique with a per-transaction nonce;
- `total_supply` does not move — it is a transfer, not a mint or burn.

On the recipient's side the aztec docs are explicit (`partial_notes.md`, *Single-use semantics*): the PXE "treats the partial note as pending until the first matching completion log is found. After the first match, the pending entry is removed. A second completion against the same commitment may not be discovered". The TXE behaves the same way. Measured in `test_edge_cases.nr`:

| | Before | After two payments of 100 |
|---|---:|---:|
| Sender's private balance | 1,000 | **800** |
| Recipient's private balance | 0 | **100** |
| `total_supply` | 1,000 | 1,000 |

One hundred units are in the note tree, owned by the recipient, and visible to no wallet.

Two things the library documents alongside the discovery loss:

- **Linkability.** Both completion logs carry the same tag `T`; anyone watching the log stream learns that two payments went to the same partial note, hence the same recipient. `UintNote::partial` says so: "Each partial note should only be used once, since otherwise multiple notes would be linked together and known to belong to the same owner."
- **Recoverability, in principle.** The lost note's preimage is fully known to the recipient: owner and randomness from its own partial note, slot and value from the public log, the nonce from the transaction. A PXE that re-adds the note by hand would make it spendable. No wallet flow does this today, and the docs' own wording is "most likely lost". Operationally: lost.

## CMTAT-Aztec and AIP-20 side by side

The AIP-20 `Token` of the [CMTA fork of `aztec-standards`](https://github.com/CMTA/aztec-standards) (`5433e9c`, `src/token_contract/src/main.nr`) has the same three entry points plus two public ones, `transfer_public_to_commitment` and `mint_to_commitment`, which complete in public through `_increase_commitment_balance` → `PartialUintNote::complete`. None of the five records a completion; the check is the library's existence check in every case. Its test suite (79 tests) has no reuse case — the behaviour is documented in aztec-nr and in the Aztec docs, not asserted by the standard.

| | CMTAT-Aztec 0.4.0 | AIP-20 `Token` (fork) |
|---|---|---|
| Completion context | private only (`complete_from_private`) | private (`transfer_private_to_commitment`) and public (`transfer_public_to_commitment`, `mint_to_commitment`) |
| Reuse guard | none | none |
| Second payment: sender | debited | debited |
| Second payment: recipient | first payment only (PXE) | first payment only (PXE) |
| Second payment: supply | unchanged | unchanged for transfers; **`mint_to_commitment` twice inflates `total_supply` by an amount no one can spend** |
| Log tag | `T = H(C, …)`, identical on both completions | same |
| Who knows `C` | recipient, completer, and the **issuer** (`CommitmentInitialized`) | recipient and completer |
| Recipient screened | at opening (`initialize_transfer_commitment`) | not applicable (the hook screens `from`) |
| What a wallet is told | README: one commitment per expected payment | Aztec docs: "treat each partial note as a one-shot object" |

The behaviours are identical on the transfer paths because the code is: `pay_commitment` is a screened `debit_private` followed by the same `complete_from_private` call the reference makes. CMTAT-Aztec did not import AIP-20's public completion paths, so the supply-inflating variant (`mint_to_commitment` twice) does not exist here.

## Consequences specific to a security token

For a payment token the loss is the payer's problem and the docs' one-shot rule is the answer. CMTAT is a security token with an issuer that audits every movement, and two further things go wrong:

1. **The audit trail and the holder's wallet disagree.** The issuer knows `C` from `CommitmentInitialized`, derives `T`, and reads *both* completion logs — it books 200 for the recipient. The recipient's wallet holds 100. `total_supply` says 1,000; the sum of what every wallet can spend is 900. Nothing on chain is inconsistent — the second note exists — but every off-chain view is, and an issuer reconciling positions (a register of holders, a corporate action, a redemption) has a discrepancy it cannot resolve from chain data alone.
2. **The loss is not the payer's alone.** With `transfer_private_to_public_with_commitment` the *sender* opens the commitment and is its completer: a sender that later pays into it twice loses its own funds — acceptable. With `initialize_transfer_commitment` the *recipient* opens the commitment and hands `C` to a payer; a careless or malicious payer who pays twice hurts the recipient's reconciliation (and the second amount is still the payer's loss). A frozen or blacklisted recipient cannot be reached this way — the recipient was screened at opening, and a second completion changes nothing about who owns the note — so this is an operational hazard, not a compliance bypass.

There is also a small privacy point: a security-token issuer that publishes nothing about its holders still leaks, on a reuse, that two payments went to one holder (shared tag `T`). The first payment already leaks that *a* completion happened; the reuse adds the link.

## Checking the earlier assessment

The review recorded K-6 with three claims. Checked against the library and the fork:

| Claim in the review | Verdict |
|---|---|
| "Inherited from `PartialUintNote::complete`" — the behaviour is the library's | **Correct**, with a precision: CMTAT-Aztec completes through `complete_from_private`, whose validity check is `assert_nullifier_exists(for_settled(V))`; the public `complete` uses `nullifier_exists_unsafe`. Both are existence checks; neither consumes `V`. |
| "AIP-20 has the same behaviour" | **Correct by code reading** — same library call, no guard in any of its five completion paths. Not demonstrated by a test in the fork; the fork cannot be built in place (see `doc/standards/upgrading-aztec-standards.md`, trap 3), and the Aztec docs make the same statement about AIP-20 directly. |
| "The contract could refuse it — the public half pushes a nullifier of the commitment" | **Wrong place.** The completion is in the *private* half; the enqueued `_transfer` deliberately takes no arguments, and passing `C` to it would publish the commitment in the public call's arguments. The nullifier belongs in the private chain (`pay_commitment`), where `UintNote::partial` itself pushes `V`. Corrected in the README and the review. |
| "100 units are no one's, yet still counted in supply" | **Imprecise.** They are the recipient's — owner and randomness are the recipient's — and unknown to its wallet. Supply is right; the wallets are wrong. This matters for the options below: the funds are recoverable in principle, not burned. |

One thing the review did not say and should have: `initialize_transfer_commitment` lets *anyone* open a commitment for any `to` (the recipient is screened, the caller is not, exactly as in AIP-20). Combined with reuse this does not create a new attack — the opener chooses the completer, and only the completer can pay — but it is why option 5 below (letting the recipient close a commitment) has to be authorised by `to`, not by the opener.

## Options

### 1. Keep the behaviour; state the rule

What the repository does today. The README's bridge section carries the wallet rule (one commitment per expected payment; never republish a consumed commitment), the test pins the behaviour so it cannot change silently, and the review carries K-6 as an open decision.

- **Cost:** none in gates or code.
- **Fits:** exactly AIP-20's semantics — a wallet written for the standard sees no difference.
- **Leaves:** the reconciliation discrepancy in the issuer's hands; the loss depends on every wallet following a rule the contract does not enforce.

### 2. Nullify the commitment at completion, in private

In `pay_commitment`, after `complete_commitment`, push one nullifier derived from the commitment under a CMTAT-specific domain separator: `context.push_nullifier_unsafe(H(C, DOM_SEP_CMTAT_COMMITMENT_COMPLETED))`. A second completion emits the same nullifier and the transaction is **invalid**, refused by the node before inclusion — the payer's funds never move.

- **Cost:** one nullifier per completion (`MAX_NULLIFIERS_PER_CALL = 16`, and the review's K-7 shows the side-effect budget is what binds a transfer — the ceiling of `transfer_private_to_commitment` may drop by one note; to be measured). No storage change, no ABI change, no public argument.
- **Privacy:** the nullifier is `H(C, sep)`; without `C` it is unlinkable to the tag `T = H(C, sep')`. Nothing new is published.
- **Failure mode:** a duplicate nullifier is not a revert with a message. The payer's PXE simulation passes (it does not check the nullifier tree for the *new* nullifier) and the node drops the transaction; in the TXE this surfaces as `Nullifier collision`, the same signature as an authwit replay. A wallet gets "transaction rejected" rather than "commitment already paid". A `#[utility] fn is_commitment_paid(C) -> bool` reading the nullifier through the PXE oracle would let a wallet pre-check.
- **Departure from AIP-20:** a second payment fails instead of vanishing. `transfer_private_to_commitment` keeps AIP-20's name and parameter types (the bridges are outside the *pinned* private profile, but the selector is the same by construction), so a caller written for the standard meets a stricter contract, never a laxer one.
- **Does not fix:** a completion that already happened twice on an existing deployment — there is none; the bridges are new in 0.4.0.

### 3. Record completed commitments in public state

Give the enqueued half the commitment — `_transfer_commitment(C)` — and keep a `Map<Field, bool>` of completed commitments; assert not set, then set. A second payment reverts in public with a message a wallet can show.

- **Cost:** one public storage read and write per completion; a new public entry point; a new storage variable (slot layout of every variant changes — a MAJOR bump under the project's own semver policy unless placed last).
- **Privacy:** **publishes `C`** in the arguments of a public call, per completion. Anyone who has seen `C` — a payer, a lookup channel — can link the payment to it; anyone else learns nothing about the parties but sees one more field than today. This is the leak option 2 avoids, and it is why the review's "public half" phrasing was wrong.
- **Failure mode:** the best of the four — a named revert (`"Commitment already paid"`).

### 4. Ask upstream for a single-use completion

`PartialUintNote::complete` / `complete_from_private` could push the completion nullifier themselves — a `complete_once` pair, or a flag — so every AIP-20 token gets the guard. aztec-nr already pushes `V` at creation; pushing `H(C, sep)` at completion is the symmetric operation.

- **Cost to this repository:** nothing until it lands; then option 2 collapses into a library call.
- **Fits:** the ecosystem — the docs describe the hazard as a rule for wallets, which suggests the library authors have not wanted to spend the nullifier; an issue with the measured loss (this document) is the way to find out.
- **Timing:** unknown. Not a substitute for a decision here.

### 5. Let the recipient close a commitment

An entry point `close_commitment(C)` callable by `to` (the owner encoded in `C`) that pushes the same nullifier as option 2 without paying. Useful on its own for a recipient that has published a commitment and wants it retired — the *expiry* discussed under F-1 by another route — and as the recovery for a lookup channel that cannot be pruned in time.

- **Cost:** one nullifier, one private entry point per variant, and the authorisation problem: the contract cannot check that the caller is `to` without the recipient proving knowledge of `randomness` (the preimage of `C`) — a small circuit, but new code that AIP-20 does not have.
- **Fits:** only together with option 2 (the same nullifier), as a complement, not an alternative.

### 6. Fix it in the wallet layer

The loss is a PXE property. A PXE that kept the partial note pending after the first match, or that let a user re-add a note from its known preimage, would recover the funds. The linkability leak would remain.

- **Cost to this repository:** none; **control:** none. Worth knowing because it changes how "lost" the funds are — recoverable by a determined recipient with a custom PXE — and because it is the only route that recovers a payment already made.

### 7. Issuer-side monitoring, today

Independent of the above: the issuer already holds every `C` through `CommitmentInitialized`, so it can derive every `T` and watch the log stream for a tag that appears twice. That flags a reuse on the day it happens, names the holder concerned, and costs nothing on chain. It does not prevent the loss, but it closes the reconciliation gap of consequence 1 above, which is the part specific to a security token.

## Comparison

| Option | Second payment | Payer's funds | Gates / side effects | Layout / ABI | Publishes `C` | Departs from AIP-20 | Effort |
|---|---|---|---|---|---|---|---|
| 1. Document only | lost to wallets | debited | — | — | no | no | done |
| 2. Private nullifier | tx invalid | untouched | +1 nullifier | none | no | stricter | ~10 lines + tests |
| 3. Public map | named revert | untouched | +1 public read/write, new entry point | new slot, new public fn | **yes** | stricter | ~40 lines + tests, MAJOR if slot moves |
| 4. Upstream | depends | depends | as 2 | none | no | no (becomes the standard) | an issue; open-ended |
| 5. Recipient close | as 2 + retire unpaid | untouched | as 2 | new private fn | no | new surface | preimage proof; with 2 only |
| 6. Wallet layer | recovered later | debited | — | — | no | no | out of scope |
| 7. Issuer monitoring | detected, not prevented | debited | — | — | no | no | off-chain tooling |

## Recommendation

Option **2**, with **7** as the operating practice until it ships and after.

The behaviour is a loss of a holder's funds that the contract can prevent for one nullifier, without publishing anything, without touching a storage slot, and without changing the selector or the parameters of any entry point. The price is a failure that surfaces as an invalid transaction rather than a named revert — the same way a replayed authwit fails today, which wallets already handle — and a divergence from AIP-20 in the direction of refusing something the standard lets a payer lose. The K-7 note ceiling of `transfer_private_to_commitment` must be re-measured after the change, because the nullifier budget is the one that binds.

Option 3 buys a better error message with a public commitment and a storage-layout change; the trade is the wrong way round for a token whose whole design keeps the parties out of public state. Option 4 is worth an upstream issue regardless, quoting the measurement. Option 5 is a separate feature — the expiry the F-1 discussion asks for, from the recipient's side — and should be decided with F-1, not here.

If the decision is *not* to change the contract, option 1 stays as it is now, and option 7 becomes a documented issuer duty in the operations section of the README rather than a footnote.

## Verification plan

For option 2:

1. Flip `a_second_payment_into_the_same_commitment_is_lost` into `a_second_payment_into_the_same_commitment_is_refused` with `should_fail_with = "Nullifier collision"`; keep the balances assertion in a first-payment test so the happy path still proves the recipient receives the note.
2. Add the same test for `transfer_private_to_public_with_commitment`'s commitment (the sender is its completer).
3. Re-run the gate profile for `transfer_private_to_commitment` in the three variants (0.4.0 baseline: 93,011 / 93,011 / 86,812) and re-probe its note ceiling the way K-7 was measured (`spend_n_notes`-style helper against the commitment path).
4. Break the change on purpose — remove the `push_nullifier_unsafe` — and watch test 1 fail, per the project's rule for chain changes.
5. Update the README bridge section, `doc/standards/building-on-aip20.md` (behavioural difference from the standard) and the review's K-6 row.

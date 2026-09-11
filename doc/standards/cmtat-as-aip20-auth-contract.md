# Could the Aztec CMTAT become an authorization contract for AIP-20?

The [`aztec-standards`](https://github.com/defi-wonderland/aztec-standards) AIP-20 token implements **ARC-403**: at deployment it is given the address of an *authorization contract*, which it calls on every transfer and burn and which may revert. This document asks whether the compliance modules in this repository — `cmtat_aztec_lib` — could be packaged as that contract, so that a **stock, unmodified AIP-20 token** gains CMTAT compliance by pointing at it.

It is the mirror image of [`building-on-aip20.md`](./building-on-aip20.md), Option B. There the question was whether the token could be built *on* AIP-20; here the token stays exactly as the standard ships it, and CMTAT becomes a sidecar.

## Table of contents

- [What was checked](#what-was-checked)
- [Short answer](#short-answer)
- [How it would work](#how-it-would-work)
- [What the hook gives a policy to work with](#what-the-hook-gives-a-policy-to-work-with)
- [Feature by feature](#feature-by-feature)
  - [Refusing paths by selector — the trick that does most of the work](#refusing-paths-by-selector--the-trick-that-does-most-of-the-work)
  - [The two arguments the hook does not pass](#the-two-arguments-the-hook-does-not-pass)
  - [The audit trail](#the-audit-trail)
  - [Metadata moves to the sidecar](#metadata-moves-to-the-sidecar)
- [Mandatory-criteria scorecard](#mandatory-criteria-scorecard)
- [Cost and privacy footprint](#cost-and-privacy-footprint)
- [The library is already the right shape](#the-library-is-already-the-right-shape)
- [Verdict](#verdict)
- [What would change the verdict](#what-would-change-the-verdict)
- [Appendix — the compiled probe](#appendix--the-compiled-probe)

## What was checked

| | |
|---|---|
| AIP-20 token | `lib/aztec-standards`, commit `a3859e5`, `src/token_contract/src/main.nr` |
| Hook interface | `authorize_private(from, amount, selector)` and `authorize_public(from, amount, selector)`, read from the token source |
| Hook call sites | 9 — all 7 transfer paths and both burns. **Not** the 3 mint paths |
| `auth_contract` storage | `PublicImmutable<AztecAddress>` — fixed at deployment |
| Probe | A `CMTATAuthorization` contract composing `AccessControlModule`, `PauseModule`, `Freezable`, `ValidationModule` and `ExtraInformation` from `cmtat_aztec_lib`, exposing the two hook functions. **Compiles against the library unmodified**; `authorize_private` measures **20,715 gates** |
| Toolchain | Aztec `5.2.0` throughout, with the library forked to `v5.2.0` as in Option F |

Figures quoted from the Aztec documentation rather than measured here are marked as such.

## Short answer

**Yes, it can be built — the probe compiles against the library as it stands — and it delivers real compliance to a stock AIP-20 token. But it is a weaker CMTAT than the one in this repository, costs more per transfer, and the two things it cannot do are the two a regulator asks about first: screen the recipient, and know who initiated an operation.**

The interesting part is how much *can* be recovered. Two of the three "irreducible conflicts" from the comparison document turn out to be closable by refusal: the hook is told which token function is running, so a CMTAT policy can simply reject every commitment path and every public-balance path. What remains unrecoverable is not a conflict but a missing argument.

## How it would work

```
   holder ──► AIP-20 Token.transfer_private_to_private(from, to, amount, nonce)
                    │
                    │  self.call(AuthorizationContract::at(auth)
                    │            .authorize_private(from, amount, selector))
                    ▼
            CMTATAuthorization                 ◄── the sidecar, built from cmtat_aztec_lib
              · pause / deactivation
              · freeze(from)
              · blacklist / whitelist(from)
              · refuse commitment and public paths by selector
              · terms, tokenId, version, debt, credit events   (metadata lives here)
              · roles, administering all of the above
                    │
                    └── revert  ⇒  the token's transfer reverts
```

Two deployed contracts instead of one. The token is the standard artifact, byte for byte; anything that recognises AIP-20 recognises it. The sidecar is where the issuer administers policy and where an assessor looks for the CMTAT surface.

## What the hook gives a policy to work with

Everything below follows from three facts about the interface.

**It receives `(from, amount, selector)`.** The address whose balance is being spent, the amount, and the function selector of the token operation that triggered the call. Nothing else.

**It is called on transfers and burns, not mints.** `mint_to_private`, `mint_to_public` and `mint_to_commitment` never reach the hook. Minting is governed only by the token's own single, immutable `minter`.

**`msg_sender()` inside the hook is the token.** The token calls the hook, so the hook sees the token as its caller. The account that actually signed the transaction is not available — Aztec has no `tx.origin`, by design — and the token does not forward it.

## Feature by feature

### Refusing paths by selector — the trick that does most of the work

The comparison document names two conflicts between CMTAT and AIP-20: public balances, and commitment transfers whose recipient is unknown. A sidecar cannot remove those paths from the token. **It can make them unusable**, because the hook is told which path is running:

```noir
fn _policy(from: AztecAddress, _amount: u128, selector: Field) {
    for i in 0..5 {
        assert(selector != REFUSED_SELECTORS[i], "CMTAT: path not permitted");
    }
    ...
}
```

Refuse `transfer_private_to_commitment`, `transfer_private_to_public_with_commitment`, `transfer_public_to_commitment`, and every `transfer_public_to_*` — and the token is, in practice, private-only with no undetermined recipients. `authorize_public` can simply refuse everything, since a CMTAT never wants a public transfer.

This is cleaner than it sounds. A wallet calling a refused path gets a clear revert from the policy rather than a silent gap, and the AIP-20 artifact is untouched. Two holes remain: `mint_to_public` and `mint_to_commitment` are not hooked, so the minter *can* create public or commitment-held balances. Those balances are then stranded — every path out of them is refused — so this is an operational rule for the issuer rather than an exploitable one, but it is not enforced.

### The two arguments the hook does not pass

**No recipient.** `is_frozen(to)` and the recipient half of `operateOnTransfer(from, to)` cannot run. A frozen account can still be paid into; a whitelist does not constrain who ends up holding the instrument. This is the same limitation as in [`building-on-aip20.md`](./building-on-aip20.md#why-the-missing-recipient-is-decisive), and it is the most important one, because the population of permitted *holders* is what a whitelist exists to define.

**No original caller.** CMTAT gates operations by *who initiates them*: only `BURNER_ROLE` may burn, only `MINTER_ROLE` may mint. The hook cannot see who initiated anything — it sees the token. So a role-based policy on token operations is not expressible: the sidecar's roles can gate the sidecar's own administration (who may freeze, who may set the lists), but not the token's mint and burn.

For burn specifically the consequence is subtle. AIP-20's `burn_private` already demands the holder's authwit, and so does CMTAT's — the difference is that CMTAT *additionally* requires the initiator to be a burner. Through the hook, any holder can redeem their own tokens without the issuer. CMTAT treats burning as an issuer act; a sidecar cannot make it one.

### The audit trail

This repository's design delivers a copy of every note to the issuer. That is what makes holder balances auditable, and the CMTA criterion *Know balance* is answered on it.

**The sidecar cannot do this.** Note delivery happens inside the token's own note machinery, which the hook does not touch. What the hook *can* do is emit its own event to the issuer from `authorize_private` — `(from, amount, selector)`, delivered privately — giving the issuer a record that `from` moved `amount` on a given path. **Without the recipient.** The issuer learns who sent and how much, but not to whom, and it cannot reconstruct balances from that. It is a partial trail, materially weaker than note copies.

### Metadata moves to the sidecar

The reverse also holds, and it is a genuine convenience: everything in CMTAT that is *pure public state with a role-gated setter* — terms, token ID, version, the debt record, credit events — has no dependency on the token at all. It can live on the authorization contract, administered by its roles, and read from there. The probe carries `ExtraInformation` for exactly this reason. Criteria 2, 5 and 48–61 are satisfied on the sidecar with no loss.

## Mandatory-criteria scorecard

Against the 19 mandatory CMTA equivalency criteria, for a stock AIP-20 token plus a CMTAT authorization contract:

| # | Criterion | Sidecar answer | Why |
|---|---|---|---|
| 1 | Name attribute | ✔ | Token |
| 2 | Legally required documentation | ✔ | Hosted on the sidecar |
| 3 | Decimals | ✔ | Token |
| 7 | Know total supply | ✔ | Token |
| 8 | Know balance | **partial** | Holder: `balance_of_private`. Issuer: no note copies, only a sender-side event trail |
| 9 | Transfer | ✔ | Token, screened on the sender |
| 10 | Create tokens | ✔ with caveat | Token's single immutable minter; not hooked, not role-based |
| 11 | Cancel tokens | **partial** | Holder self-redemption cannot be prevented; issuer-only burn is not expressible |
| 14–16 | Pause, unpause, status | ✔ | Sidecar. Immediate if checked via an enqueued public call, delayed if held as `DelayedPublicMutable` — the same choice this repository faces |
| 17–18 | Deactivate, status | ✔ | Sidecar: a permanent unconditional revert |
| 19 | Freeze | **partial** | Sender only; a frozen account can still receive |
| 20 | Unfreeze | ✔ | Symmetric with 19 |
| 21 | Know frozen status | ✔ | Sidecar |
| 29–31 | Grant, revoke, role attribution | **partial** | Roles exist and administer the sidecar, but cannot gate the token's mint or burn |

**No mandatory `n`**, so under the template's letter the arrangement is equivalent. Five `partial`s, and every one of them is the same story told four ways: the hook does not know the recipient or the initiator, and does not see the notes. An assessor should read the partials, not the count.

## Cost and privacy footprint

**Gates.** Per private transfer, the holder's device proves:

| Component | Gates | Source |
|---|---:|---|
| AIP-20 `transfer_private_to_private` | 63,310 | measured on the `v5.2.0` fork |
| `CMTATAuthorization::authorize_private` | 20,715 | measured on the probe (pause, one freeze read, sender list checks) |
| One additional private kernel iteration for the cross-contract call | ~101,000 | Aztec documentation — **not measured here** |
| **Total** | **~185,000** | |

Against **120,824** for this repository's single-circuit `transfer`, which does *more* compliance work. The cross-contract hop costs more than all the compliance logic it carries. That is the structural price of the sidecar: every screened operation is two circuits and a kernel iteration instead of one circuit.

**Privacy.** Better than expected in one respect. Because the probe holds its pause flag as `DelayedPublicMutable`, `authorize_private` decides entirely in private and enqueues **nothing** — the token's transfer then has exactly the public footprint the token already had. This repository's own transfer enqueues a public `_transfer()` purely to read a `PublicMutable` pause flag, publishing that a transfer occurred. The sidecar can avoid that leak, at the cost of a delayed pause. (The library's own test hook does the opposite and enqueues a public call carrying `from`; a real policy must not.)

**Immutability.** `auth_contract` is `PublicImmutable`: the token's pointer to the sidecar can never change. A policy bug means redeploying the token. One mitigation is a *router* — the sidecar holds a mutable pointer to a policy contract and forwards to it — which restores replaceability at the cost of a second cross-contract hop per transfer, roughly another 101,000 gates. Worth stating so the trade is visible; not worth recommending.

## The library is already the right shape

This is the part that was not obvious in advance and is worth recording as a result in its own right.

The probe was written against `cmtat_aztec_lib` with **no changes to the library**: five module structs held in a foreign contract's `#[storage]`, the private hook calling `is_frozen` and `operateOnTransfer` from private context, the public administration functions calling `freeze` and `set_operations` with the sidecar's own `AccessControlModule` as the authority. It compiled first time.

That is the module design paying off exactly as the code-quality review's `J-3` probe predicted: because each module takes its access control as a parameter rather than reaching into its host, and because each is a `StateVariable` with its own slot, the same modules serve a token and a sidecar without modification. Whatever is decided about this document's question, the library needs nothing added to support either answer.

## Verdict

**Feasible, and not recommended as the primary design — but a legitimate second product.**

- **As a replacement for this repository's token: no.** It gives up recipient screening, issuer-controlled burn, role-gated minting and the note-copy audit trail, costs roughly 50% more gates per transfer, and pins the policy to an immutable pointer. Every one of those is a regression against what already works here.
- **As a way to give compliance to a token that must be stock AIP-20: yes, with the partials disclosed.** If an issuer needs the AIP-20 artifact itself — for wallet support, for a vault that composes with it, for whatever reason makes "the standard, unmodified" a hard requirement — then a CMTAT sidecar is the best compliance available for it, and it is a few hundred lines over a library that already exists. The five partials in the scorecard are the disclosure that must accompany it.

The two are not in tension. The library supports both; the question is which artifact an issuer needs to deploy.

## What would change the verdict

Four upstream changes to ARC-403, in order of impact. Together they would turn the sidecar from "a weaker CMTAT" into "a CMTAT", and they are the substance of what this project should propose to `aztec-standards`:

1. **Pass the recipient.** `authorize_private(from, to, amount, selector)`, with `PRIVATE_ADDRESS_MAGIC_VALUE` on commitment paths. Closes criterion 19 fully and makes whitelisting meaningful. This alone removes the most serious partial.
2. **Pass the initiator.** The account the token saw as `msg_sender()`. Closes 11 and 29–31: role-gated mint and burn become expressible.
3. **Hook the mint paths.** Closes the `mint_to_public` / `mint_to_commitment` hole and lets the sidecar gate issuance.
4. **Make `auth_contract` mutable under an admin.** So a compliance policy can be corrected without redeploying the token and migrating holders.

None of these is exotic. ERC-3643's compliance hook receives sender, recipient and amount; ERC-1404 checks both parties; CMTAT's own `RuleEngine` receives `from`, `to`, `value` and the spender. AIP-20's hook is the outlier, and it is an outlier by omission rather than by design decision — ARC-403 landed on 2026-07-06 and has had one consumer.

The audit-trail gap (criterion 8) is the one thing no hook change fixes: only the token can copy notes to an observer. That would be a separate proposal — an optional *observer* delivery in AIP-20 itself — and is the same auditability conversation the comparison document already suggests the standard should have.

## Appendix — the compiled probe

The contract below compiled against `cmtat_aztec_lib` at Aztec `5.2.0` with no library changes, and `authorize_private` profiled at 20,715 gates. The refused-selector values are placeholders; a deployment computes them from the token artifact. Administration entry points beyond `freeze` and `set_operations` are omitted for brevity — they are the same calls the token makes today.

```noir
#[aztec]
pub contract CMTATAuthorization {
    use cmtat_aztec_lib::modules::{
        access_controlModule::{AccessControlModule, DEFAULT_ADMIN_ROLE},
        enforcementModule::{Freezable, FreezableFlag},
        extraInformationModule::ExtraInformation,
        pauseModule::PauseModule,
        validationModule::{SetFlag, UserFlags, ValidationModule},
    };

    global REFUSED_SELECTORS: [Field; 5] = [/* commitment and public-balance paths */];
    global PAUSE_DELAY_SECONDS: u64 = 360;

    #[storage]
    struct Storage<Context> {
        access_control: AccessControlModule<bool, Context>,
        paused: DelayedPublicMutable<bool, PAUSE_DELAY_SECONDS, Context>,
        deactivation: PauseModule<Context>,
        enforcement_module: Freezable<FreezableFlag, Context>,
        validation_module: ValidationModule<UserFlags, Context>,
        extra_information_module: ExtraInformation<bool, Context>,
    }

    /// ARC-403 private hook. Reads only DelayedPublicMutable state, so it runs entirely in
    /// private and enqueues nothing: the token learns "authorised" or a revert, and no more.
    #[external("private")]
    fn authorize_private(from: AztecAddress, amount: u128, selector: Field) {
        self.internal._policy(from, amount, selector);
    }

    /// ARC-403 public hook. A CMTAT never permits a public-balance operation.
    #[external("public")]
    fn authorize_public(from: AztecAddress, amount: u128, selector: Field) {
        assert(false, "CMTAT: public balances are not permitted");
    }

    #[internal("private")]
    fn _policy(from: AztecAddress, _amount: u128, selector: Field) {
        assert(!self.storage.paused.get_current_value(), "CMTAT: paused");
        for i in 0..5 {
            assert(selector != REFUSED_SELECTORS[i], "CMTAT: path not permitted");
        }
        assert(!self.storage.enforcement_module.is_frozen(from), "Frozen: Sender");
        // Only the sender can be screened: the hook is not given the recipient.
        self.storage.validation_module.operateOnTransfer(from, from);
    }

    #[external("public")]
    fn freeze(user: AztecAddress, value: FreezableFlag) {
        self.storage.enforcement_module.freeze(
            self.msg_sender(), user, value, self.storage.access_control,
        );
    }

    #[external("public")]
    fn set_operations(operations: SetFlag) {
        self.storage.validation_module.set_operations(
            self.msg_sender(), operations, self.storage.access_control,
        );
    }
}
```

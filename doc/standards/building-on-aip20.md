# Could private-CMTAT-aztec be built on top of AIP-20?

An assessment of whether this project could be rebuilt on the [`aztec-standards`](https://github.com/defi-wonderland/aztec-standards) AIP-20 token rather than implementing CMTAT from scratch — written after checking out the library at `lib/aztec-standards` and reading its source, rather than its documentation.

> **Companion document.** [`cmtat-vs-aip20.md`](./cmtat-vs-aip20.md) compares the two *standards*. This one asks the engineering question: given the library as it actually is, what would "building on top" mean, and does any version of it work?

## Table of contents

- [What was checked](#what-was-checked)
- [Correction to the earlier analysis](#correction-to-the-earlier-analysis)
- [Short answer](#short-answer)
- [The six things "on top of" could mean](#the-six-things-on-top-of-could-mean)
  - [Option A — depend on the crate and extend it](#option-a--depend-on-the-crate-and-extend-it)
  - [Option B — use the ARC-403 authorization hook](#option-b--use-the-arc-403-authorization-hook)
  - [Option C — wrap the token in a compliance contract](#option-c--wrap-the-token-in-a-compliance-contract)
  - [Option D — vendor the contract and modify it](#option-d--vendor-the-contract-and-modify-it)
  - [Option E — copy the patterns, not the code](#option-e--copy-the-patterns-not-the-code)
  - [Option F — fork the library and move it to v5.2.0](#option-f--fork-the-library-and-move-it-to-v520)
- [Interface alignment — an AIP-20 private profile](#interface-alignment--an-aip-20-private-profile)
- [Practical blockers independent of the design](#practical-blockers-independent-of-the-design)
- [Recommendation](#recommendation)
- [What to do with the submodule](#what-to-do-with-the-submodule)

## What was checked

| | |
|---|---|
| Library | `lib/aztec-standards`, commit `a3859e5`, described as `prerelease-0200230-14-ga3859e5` |
| Token source | `src/token_contract/src/main.nr`, 695 lines, one contract |
| Its aztec-nr pin | `v5.0.0-rc.2`, from `aztec-packages/noir-projects/aztec-nr` |
| This project's pin | `v5.2.0`, from the standalone `AztecProtocol/aztec-nr` repository |
| Workspace members | 11 crates, **all `type = "contract"`** — there is no `type = "lib"` crate |

Everything below is from reading that source. Where a figure is from the Aztec documentation rather than measured here, it says so.

## Correction to the earlier analysis

**[`cmtat-vs-aip20.md`](./cmtat-vs-aip20.md) states that AIP-20 has "no compliance surface at all, and no extension point at which one could be added in a standard way", and suggestion A-1 proposes adding one. That is wrong for this version of the library.**

The token implements **ARC-403, an authorization hook**:

```noir
auth_contract: PublicImmutable<AztecAddress, Context>,
```

```noir
#[internal("private")]
fn _call_auth_private(from: AztecAddress, amount: u128) {
    let auth = self.storage.auth_contract.read();
    if !auth.eq(AztecAddress::zero()) {
        let selector = self.context.selector().to_field();
        self.call(AuthorizationContract::at(auth).authorize_private(from, amount, selector));
    }
}
```

An external contract nominated at deployment is called on every transfer and burn, and may revert. That is exactly the extension point the comparison document said was missing. The companion document has been corrected; this section records the correction so the mistake is visible rather than quietly edited away.

**It does not change the conclusion**, for the reason set out in Option B — but it changes the reasoning, and it makes the honest answer "the hook gets you about half of CMTAT" rather than "there is nowhere to put compliance".

## Short answer

**No — but closer than expected, and one option is worth keeping on the table.**

- Building on the library as a *dependency* is impossible: every crate is `type = "contract"`, and Noir has neither inheritance nor a way to extend a contract crate. This is a property of the language, not an oversight in the library.
- The ARC-403 hook can express **pause, deactivation, amount limits, and sender-side freeze/blacklist/whitelist**. It cannot express **recipient screening**, because the hook is not given the recipient — and recipient screening is not optional in CMTAT.
- Every other route is a fork, a wrapper that re-implements the token, or copying patterns without the code.
- **The fork itself is cheap** — moving the library to `v5.2.0` took eleven manifest edits and no source changes, and all 79 of its tests pass. What is not cheap is what comes after the fork, and that is unchanged.
- **Interface alignment is available without any of the above**: selectors depend on function names and parameter *types* only, so renaming five entry points makes this token answer AIP-20's private-path selectors exactly (two already match). `burn` must stay unaliased — its authorisation differs. See [Interface alignment](#interface-alignment--an-aip-20-private-profile).

## The six things "on top of" could mean

### Option A — depend on the crate and extend it

**Verdict: impossible, and not for want of trying.**

Noir permits one contract per crate, and a `type = "contract"` crate cannot be extended. Importing `token_contract` gives you its *generated interface* — `Token::at(address).transfer_private_to_private(...)` — for making calls to a deployed instance. It does not give you its implementation to build on.

The library confirms this is the intended reading: AIP-4626, which the documentation describes as "extending the AIP-20 token contract", depends on it exactly that way —

```toml
# src/vault_contract/Nargo.toml
token_contract = { path = "../token_contract" }
```

— and then *calls* it: `Token::at(shares_token).burn_public(from, shares, nonce)`. The vault is a separate deployed contract that holds and moves a separate deployed token. "Extends" means "composes with", not "inherits from".

There is no `type = "lib"` crate anywhere in the workspace, so there is not even a partial reuse path for note types or balance helpers. The reusable pieces this project does depend on — `aztec`, `uint_note`, `balance_set`, `compressed_string` — come from aztec-nr, which both projects already use directly.

### Option B — use the ARC-403 authorization hook

**Verdict: the only genuinely interesting option, and it fails on one specific thing.**

> The mirror image of this option — building the *hook contract* out of `cmtat_aztec_lib` so a stock AIP-20 token gains CMTAT compliance — is worked through, compiled and measured in [`cmtat-as-aip20-auth-contract.md`](./cmtat-as-aip20-auth-contract.md). It reaches the same limit from the other side, and adds a second missing argument: the hook is not told who initiated the operation either.

The design would be: deploy a stock AIP-20 token, deploy a CMTAT compliance contract, and nominate the latter as the token's `auth_contract`. The compliance contract holds the roles, the pause flag, the freeze flags and the lists, and reverts in `authorize_private` / `authorize_public` when a transfer must not proceed.

**What the hook is given:** `(from: AztecAddress, amount: u128, selector: Field)`.

**Where it is called:** nine sites — all five private transfer paths, both public transfer paths, `burn_private` and `burn_public`.

**Where it is not called:** `mint_to_private`, `mint_to_public` and `mint_to_commitment`. Minting is not hooked at all. *(As it happens this project has the same gap, recorded as `G-1` in the code-quality review — but there it is a comment that overstates the code, not a structural limit.)*

#### What CMTAT controls the hook can and cannot express

| CMTAT control | Expressible through the hook? | Why |
|---|---|---|
| Pause | ✔ | Revert unconditionally; needs no argument |
| Permanent deactivation | ✔ | Same |
| Maximum transfer amount | ✔ | `amount` is passed |
| Freeze the **sender** | ✔ | `from` is passed |
| Blacklist / whitelist the **sender** | ✔ | `from` is passed |
| Per-operation rules by function | ✔ | `selector` is passed |
| Freeze the **recipient** | ✘ | **`to` is not passed** |
| Blacklist / whitelist the **recipient** | ✘ | Same |
| Maximum balance per holder | ✘ | Needs the recipient and their balance |
| Restrictions on mint | ✘ | Mint does not call the hook |
| Forced transfer | ✘ | Not expressible anywhere in AIP-20 |

#### Why the missing recipient is decisive

CMTAT's enforcement module blocks a frozen address from **sending and receiving**. Its whitelist requires **both parties** to be listed; its blacklist rejects if **either** is listed. This implementation follows that: `_transfer_internal` asserts on `is_frozen(from)` *and* `is_frozen(to)`, and `operateOnTransfer(from, to)` screens both.

Through the hook, a frozen or blacklisted address can still **receive** tokens. An issuer who has frozen an account to stop it trading would find that the account can still be paid into — and under a whitelist regime, that tokens can be delivered to an address that was never approved to hold them. Whitelisting in particular becomes close to meaningless when only the sending side is checked: the population of addresses that may *hold* the security is exactly what a whitelist exists to control.

Two escapes, both unsatisfactory:

1. **Have the completer or recipient pull instead of push.** Restructures every transfer flow and does not help `transfer_private_to_private`, where the sender pushes by construction.
2. **Fork the token to pass `to` to the hook.** This works, and it is a small change — but it is Option D, not Option B: you now maintain a fork, and the resulting token is no longer the standard one, which was the entire reason for building on it.

#### The cost, which is not small either

The hook is a **cross-contract call from private context**. By the framework's own figure — quoted from the Aztec documentation, **not measured here** — each additional private call adds roughly 101,000 gates for the extra kernel iteration. A transfer in this project currently costs 120,824 gates, so routing every transfer through an external hook would be on the order of a 80% increase in the user's proving work, before the compliance contract does anything.

There is also a privacy consequence worth naming: a compliance contract that must consult public state (a role table, a pause flag) faces exactly the problem this project already solved. It must either enqueue a public call — publishing the sender's address on every transfer — or hold its flags as `DelayedPublicMutable` and accept the delay. The library's own test hook takes the first route: `authorize_private` enqueues `record_call_internal(from, amount, selector)`, which publishes `from`. A real hook must not do that.

### Option C — wrap the token in a compliance contract

**Verdict: collapses into re-implementing the token.**

The idea: deploy a stock AIP-20 token, have a CMTAT contract hold all of it, and let the CMTAT contract track who really owns what.

It fails immediately. AIP-20's private transfer functions are callable by any holder directly; a wrapper cannot intercept them. To make the wrapper authoritative it must be the sole holder — at which point the underlying token has one holder, all real balances live in the wrapper's own ledger, and the wrapper has re-implemented notes, balances, transfers and delivery. The AIP-20 token beneath it is then an accounting artefact that adds a contract call to every operation and nothing else.

This is the pattern AIP-4626 uses legitimately, because a vault genuinely *is* a separate instrument holding a separate asset. It does not transfer to a token that is meant to *be* the asset.

### Option D — vendor the contract and modify it

**Verdict: possible, honest, and probably not worth it.**

Copy `token_contract/src/main.nr` — 695 lines — into this repository, add the compliance modules, and extend the hook signature to include the recipient.

What it buys:

- The partial-note machinery, already written and tested.
- The recursive balance subtraction, which [`F-1`](../analysis/CLAUDE_ANALYSIS.md) measures as worth **43,046 gates, 36% of a transfer**.
- The public/private balance split, if wanted.
- The AIP-20 entry-point names, which tooling recognises — though a fork that adds recipient screening is no longer conformant, so this benefit is partly illusory.

What it costs:

- A hard fork with no upstream path. `aztec-standards` is pre-release and moving; every upstream fix becomes a manual merge into a file that has diverged.
- The compliance surface must be added to **every** path — five private transfer variants, two public, three mints, two burns — where this project has three. That is a larger attack surface to get right, and each path needs its own tests.
- The two conflicts from the comparison document remain in reduced form: public balances would have to be either screened or removed, and the commitment paths can screen the recipient only at initialization, so they need an expiry to bound the gap before completion (see the corrected Conflict 2).

### Option E — copy the patterns, not the code

**Verdict: this is what is already recommended, and it does not require the submodule.**

The valuable, portable ideas are:

- **The note budget with recursion** (`INITIAL_TRANSFER_CALL_MAX_NOTES = 2`, `RECURSIVE_TRANSFER_CALL_MAX_NOTES = 8`). Measured worth: 43,046 gates per transfer, with the caveat that the recursion has to be built to make it safe.
- **A named sentinel for "this party is private" in public events** rather than overloading the zero address.
- **The hook shape itself** — now that ARC-403 exists, a CMTAT-on-Aztec that wants to be hook-compatible could adopt the same signature *plus* the recipient, and propose the addition upstream.

None of these needs a dependency. All are implementable against the aztec-nr libraries this project already uses.

### Option F — fork the library and move it to v5.2.0

**Verdict: mechanically trivial — measured, not estimated — which relocates the argument rather than settling it.**

The hypothesis: fork `aztec-standards`, bring it from `v5.0.0-rc.2` to the `v5.2.0` this project already uses, and build from there. Rather than estimate the migration effort, it was done in a scratch copy of the checkout.

**What the migration consisted of.** Eleven `Nargo.toml` edits and **no source changes at all**:

- the four aztec-nr crates (`aztec`, `uint_note`, `balance_set`, `compressed_string`) repointed from `aztec-packages/noir-projects/aztec-nr/<crate>` at `v5.0.0-rc.2` to the standalone `AztecProtocol/aztec-nr` repository at `v5.2.0` — the same source this project uses;
- one protocol-circuits crate (`serde`, used by `escrow_contract`) left in `aztec-packages` with its tag bumped to `v5.2.0`, because that tree does not exist in the standalone repository.

That second point is the only trap: the library mixes crates that moved to the standalone repository with one that did not, so the remap is not a pure find-and-replace. Getting it wrong produces `Cannot read file .../noir-protocol-circuits/crates/serde/Nargo.toml`, which is what the first attempt hit.

**Result.**

| Step | Outcome |
|---|---|
| `aztec-nargo compile --package token_contract` | 0 errors |
| `aztec-nargo compile --workspace` (all 11 crates) | 0 errors |
| `aztec test --package token_contract` | **79 / 79 pass** |

The API gap between `v5.0.0-rc.2` and `v5.2.0` is, for this library, nil. That is not surprising in hindsight — the rc.2 → 5.2.0 hop is a patch series inside one major, where this project's own 0.63.1 → 5.2.0 migration crossed the macro rewrite — but it needed measuring, because the [blocker table](#practical-blockers-independent-of-the-design) below originally listed the version mismatch as a wall. It is a one-afternoon task, and the table has been corrected.

*(A first test run showed 78 failures; that was a setup error, not the fork — only `token_contract` had been compiled, and the "on behalf of" tests deploy `GenericProxy`, whose missing artifact crashed the TXE server and cascaded `client error (Connect)` into every later test. Compiling the workspace fixed it. Recorded because it is the same `ENOENT` class this project hit during its own migration.)*

**What the fork buys, measured.** With the artifacts built at `v5.2.0`, the two tokens can be profiled on the same toolchain:

| Operation | AIP-20 token (`v5.2.0` fork) | private-CMTAT-aztec |
|---|---:|---:|
| Private → private transfer | **63,310** | 120,824 |
| Private burn | 38,221 | 81,736 |
| Mint to private | 28,654 | 30,776 |
| One recursion step (fragmented balance) | 30,136 + a kernel iteration | — |

The transfer gap is large, and it reconciles almost exactly against components already measured in this repository: **120,824 − 10,408** (validation module, base vs Light) **− 1,679** (`Transfer` event) **− 43,046** (16-note vs 2-note budget) **= 65,691**, against AIP-20's 63,310. The residual ~2,400 gates is the two freeze reads, the issuer read and the two issuer note copies, less the hook's `PublicImmutable` check. In other words: the CMTAT features cost what they were measured to cost, and **the note budget is the only part of the gap that is a free lunch** — which is why Option E already recommends taking it.

**What the fork does not change.** Every design conclusion above stands:

- It is still a `type = "contract"` crate. A fork could *add* a `type = "lib"` crate by extracting the token's internal helpers — but that is new engineering the upstream has not done, and it is exactly the module-library structure this project already has.
- The ARC-403 hook is still not passed the recipient. Adding `to` is a small change in a fork — and the moment it is made, the token is no longer AIP-20, which was the point of starting from it.
- Public balances and commitment paths still conflict with screening (Conflicts 1 and 2 in the [comparison](./cmtat-vs-aip20.md)).

**The maintenance cost, quantified.** The upstream is slow-moving: 4 commits in the 90 days before the pinned commit, all four touching `token_contract`, and three of them version bumps (`upgrade to 4.3.0`, `upgrade v5.0.0`, `upgrade to 5.0.0 rc.2`). ARC-403 itself landed on 2026-07-06, which is why the Aztec documentation does not mention it. A fork would mostly be *ahead* of upstream on Aztec versions and would have little to merge — the "fast-moving target" concern in Option D is weaker than stated there.

**So where does that leave it?** Option F makes Option D cheap to *start*. It does not make it cheap to *finish*: the work is not the port, it is adding recipient screening to every one of twelve transfer, mint and burn paths and deciding what to do about public balances and commitments — after which the result is a CMTAT with AIP-20 function names that no AIP-20 wallet can safely treat as AIP-20. The fork is feasible; it is not obviously desirable.

## Interface alignment — an AIP-20 private profile

A narrower question than the options above: without adopting AIP-20's architecture, could this token's **entry points** be aligned with AIP-20's, so that tooling written for the standard's private paths works against it unchanged?

**Yes, and it is a rename.** On Aztec a caller reaches a function by its **selector**, which is derived from the function name and the parameter *types* — not the parameter names. That was checked rather than assumed, by computing selectors from both compiled artifacts with `FunctionSelector.fromNameAndParameters`:

| Function | AIP-20 | This token | Same selector? |
|---|---|---|---|
| `balance_of_private(owner)` | `0x4375727c` | `0x4375727c` | **already** |
| `total_supply()` | `0x8dd382ec` | `0x8dd382ec` | **already** |
| `transfer_private_to_private(from, to, amount, _nonce)` | `0xedc09d49` | `transfer(…)` → `0x49b80d25` | after rename: **`0xedc09d49`** — with `authwit_nonce` left as is |
| `mint_to_private(to, amount)` | `0xf8f84119` | `mint(…)` → `0x724402ae` | after rename: yes |
| `name()` / `symbol()` / `decimals()` | `0x5c5c9c42` / … | `public_get_name()` → `0xc8bbd7b4` / … | after rename: yes |
| `burn_private(from, amount, _nonce)` | `0xc282ed79` | `burn(account, …)` → `0x16a23d86` | after rename: yes — **but see below** |

The third row is the useful one: renaming `transfer` to `transfer_private_to_private` and changing nothing else — same types, `authwit_nonce` kept — produces AIP-20's exact selector. Parameter names are invisible to the selector, so the descriptive name this project chose costs nothing.

### What each entry point maps to

| This token | Alignment | Note |
|---|---|---|
| `transfer` | **rename** → `transfer_private_to_private` | Same shape; ours may also revert for compliance reasons, which AIP-20's may too, via its hook |
| `mint` | **rename** → `mint_to_private` | AIP-20 checks a single immutable minter, ours checks `MINTER_ROLE`; identical from the caller's side |
| `public_get_name` / `_symbol` / `_decimals` | **rename** → `name` / `symbol` / `decimals` | Pure rename. The `private_get_*` variants stay as this project's extras |
| `balance_of_private`, `total_supply` | **already aligned** | Nothing to do |
| `burn` | **do not alias** to `burn_private` | Different authorisation — see the trap below |
| `transfer_batch`, `mint_batch`, `burn_batch`, `cancel_authwit` | keep | No AIP-20 counterpart; harmless extras |
| every `*_to_public`, `*_to_commitment`, `balance_of_public`, `initialize_transfer_commitment`, `get_auth_contract` | **absent, deliberately** | Conflicts 1 and 2 in the [comparison](./cmtat-vs-aip20.md) |
| `constructor` | stays different | AIP-20's two constructors take an `auth_contract`; deployment tooling differs regardless |

The `Transfer` event already has the same name and the same fields (`from`, `to`, `amount`) on both sides.

### The burn trap

`burn` is the one function that *could* be renamed to match and *must not* be, because an identical selector with different semantics is worse than a different name.

- AIP-20 `burn_private(from, amount, _nonce)` is **holder-authorised**: `#[authorize_once("from", "_nonce")]` and nothing else. Any holder burns their own tokens.
- CMTAT `burn(account, amount, authwit_nonce)` is **privileged**: the caller must hold `BURNER_ROLE` *and* the holder must consent. A plain holder calling it gets `AccessControlUnauthorizedAccount`. This is by design — in CMTAT, burning is redemption, an issuer act.

A wallet that sees selector `0xc282ed79` would call it as a self-burn and fail with a role error it has no way to anticipate. Keeping the CMTAT name makes the difference discoverable instead of surprising. *(CMTAT Solidity's `BURNER_SELF_ROLE` lives in the cross-chain module, not the core, so there is no core self-burn to map to either.)*

### What alignment buys, and what it does not

**Buys.** Any tool or contract that uses only AIP-20's private paths — `transfer_private_to_private`, `mint_to_private`, `balance_of_private`, `total_supply`, `name`/`symbol`/`decimals` — works unchanged, because it addresses the token by selector. That includes *other contracts*: a Noir contract holding a generated `Token::at(address)` interface for those functions would call this token successfully. The generated TypeScript call shapes become identical too, since arguments are positional.

**Does not buy.** Aztec has no interface detection, so a partial profile is invisible until a missing function is called: a tool that also uses `transfer_public_to_public` or the commitment paths fails at that call, not at discovery. This is exactly why the README must state the non-conformance explicitly rather than let the matching names imply it. And the constructor still differs, so deployment tooling is unaffected either way.

**Costs.** It is an ABI break — five renames across three `main.nr` files, the generated TypeScript, the e2e tests, the interaction scripts, and every document that names the functions, including the equivalency assessment's implementation-details cells. One-time, mechanical, and no storage or note-layout change.

### Verdict

**Worth doing, as a bounded change, if being reachable by AIP-20 private-profile tooling is wanted** — five renames (`transfer`, `mint`, `public_get_name`, `public_get_symbol`, `public_get_decimals`), `burn` kept as is, and a README sentence stating that the token exposes the AIP-20 private profile only and why. It is not conformance and should not be described as such; it is the largest slice of compatibility available without touching any of the conflicts, and its entire cost is a rename.

## Practical blockers independent of the design

Even if one of the options above were chosen, these apply:

| Blocker | Detail |
|---|---|
| **Version mismatch** — *downgraded from blocker to chore* | `aztec-standards` pins `v5.0.0-rc.2` from `aztec-packages`; this project pins `v5.2.0` from the standalone `aztec-nr` repository. An earlier revision of this document called this a wall. It was then tried ([Option F](#option-f--fork-the-library-and-move-it-to-v520)): eleven manifest edits, no source changes, 79/79 tests pass. The only trap is that one crate (`serde`) lives in a tree that did not move to the standalone repository. |
| **Pre-release library** | The checkout describes itself as `prerelease-0200230-14-ga3859e5`. Its interfaces are not stable, and the Aztec documentation already warns that it differs from the reference contracts in `aztec-packages`. |
| **`auth_contract` is `PublicImmutable`** | The compliance contract is fixed at deployment and cannot be replaced. A bug in it, or a change of compliance policy that needs new state, means redeploying the token and migrating every holder. CMTAT's Solidity RuleEngine is settable for exactly this reason. |
| **The token depends on a test crate** | `token_contract/Nargo.toml` lists `authorization_contract = { path = "src/test/test_authorization_contract" }` — the production crate depends on a crate under `src/test/` for the hook interface. Workable, but it signals the hook interface has not yet been factored out for third-party use. |
| **No pause anywhere** | Confirmed by inspection: zero occurrences of pause, freeze, blacklist or allowlist in the token contract. Everything of that kind must live behind the hook. |

## Recommendation

**Do not rebuild on `aztec-standards` — and the reason is no longer "it would be hard to port".** Option F showed the port is trivial. The reason is that after the port every design problem is still there, and solving them produces a fork that is no longer the standard. Keep the current architecture — CMTAT modules over aztec-nr, three deployment variants — and take from AIP-20 the two things that are portable:

1. **Adopt the note-budget-plus-recursion pattern.** This is the measured win and it is independent of everything else. Prerequisite is a note-count distribution measurement, not an architecture decision.
2. **Consider aligning a future compliance hook with ARC-403's shape**, so that a CMTAT compliance contract could serve both this token and a stock AIP-20 token if the hook ever gains a recipient argument.

**And raise the recipient argument upstream.** `authorize_private(from, amount, selector)` cannot express recipient screening, which every regulated token needs and which is not an exotic requirement — ERC-3643, ERC-1404 and CMTAT all check both parties. Adding `to` to the hook signature would cost the standard very little and would be the difference between "a compliant token can use AIP-20" and "a compliant token must fork it". That is the single most valuable change this project could suggest to the standard, and it supersedes suggestion A-1 in the companion document, which asked for a hook that already exists.

## What to do with the submodule

`lib/aztec-standards` is currently checked out but nothing in the build references it — no `Nargo.toml` in this workspace depends on it, and the workspace members are unchanged.

Two coherent choices:

- **Keep it, as a reference.** It is the canonical AIP-20 source and the documentation explicitly says the reference contracts in `aztec-packages` differ from it. Having it pinned makes claims about AIP-20 checkable. If kept, it should move under `submodules/` with the other reference repositories, since `lib/` in this workspace means "the shared Noir library" and a second meaning there is confusing.
- **Drop it**, and cite the repository by URL and commit in these two documents instead.

Keeping it is the better answer while these comparisons are live, provided it moves out of `lib/`.

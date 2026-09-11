# Agent guide — private CMTAT on Aztec

> **Note — keep in sync:** `AGENTS.md` and `CLAUDE.md` must always be **identical**. Any edit to one must be applied verbatim to the other.

> **Note — commit messages:** After each group of modifications or each feature added, always provide a **one-line GitHub commit message** (Conventional-Commits style, e.g. `feat: ...`, `fix: ...`, `docs: ...`).
>
> **Never put `!` in a commit message** — not as the breaking-change marker (`feat!: ...`), not anywhere else. In an interactive bash, `!` inside double quotes triggers history expansion, so `git commit -m "feat!: ..."` aborts with `bash: !: unrecognized history modifier`. Signal a breaking change with an uppercase `BREAKING CHANGE:` line in the commit body instead, and keep the subject line free of `!`.

> **Note — no tool names in the changelog:** never name an assistant tool, skill or slash command in `CHANGELOG.md`. The changelog records what changed in *this project*, for readers who have no idea what tooling produced it. A line ending "the `<some-skill>` skill gained the corresponding check" documents the author's toolbox rather than the release, and it rots independently of the repository — the tool can be renamed or deleted, leaving a dangling reference to something the reader could never have seen. Describe the change and its effect; if the tooling matters, record it in the audit or analysis report instead.
>
> This is about **tool identities, not the word "Claude"**: files committed to the repository — `CLAUDE.md`, `AGENTS.md`, `CLAUDE_AUDIT.md`, `CLAUDE_ANALYSIS*.md` — are cited freely, because a reader can open them.

> **Note — do not hard-wrap prose in `CHANGELOG.md`:** one line per bullet or paragraph, and let the editor soft-wrap. Markdown collapses a single newline into a space, so a hard-wrapped bullet renders identically — the cost is invisible in the published changelog and paid entirely in the repository. Changing one word reflows every following line, so a one-word correction arrives as a multi-line diff in which a reviewer cannot see what actually changed; and because the wrap column depends on whoever wrote the entry, the file drifts into a mix of styles that reads as damage. Keep the line structure only where it is semantic: fenced code blocks, tables and blockquotes.

> **Note — long changelog entries get sub-bullets:** past roughly three sentences, a bullet stops being scannable — the defect, its blast radius, the fix, the precedent and the caveat all run together, so a reader looking for any one of them has to parse all five. Lead with one sentence naming *what changed*, then one sub-bullet per distinct claim: impact, fix, behaviour-change warning, cost, migration note. A useful trigger is length — compare against the file's own median bullet and split anything several times longer, since that length almost always means several claims in one paragraph. Sub-bullets follow the same no-hard-wrap rule: one line each.

## What this project is

A private version of the [CMTAT](https://github.com/CMTA/CMTAT) security token, written in Noir/Aztec.nr for the [Aztec](https://aztec.network/) privacy L2. Balances and transfers are private (encrypted notes in each user's PXE) while `totalSupply`, pause state, roles and freeze/blacklist flags stay public; the issuer receives a duplicate of every note so it can audit activity for compliance. The repository is a prototype: it has **not** been audited, it is not upgradeable, and it has no gasless/meta-transaction support.

## Key concepts

- **Three deployment variants, one library.** `CMTATAztec` (base), `CMTATAztecDebt` (adds credit events and debt) and `CMTATAztecLight` (drops the validation module) are separate packages that compose modules from `cmtat_aztec_lib`. Adding an entry point to a shared module means adding it to **every variant that should expose it** — there is no inheritance to do it for you. Keep the three `main.nr` files in step.
- **Single contract, module structs.** Noir has no Solidity-style inheritance, so "modules" are plain structs implementing `StateVariable<N, Context>` (which supplies both `new` and `get_storage_slot`) and held as fields of the contract's `#[storage] struct Storage<Context>`. Every user-callable entry point must be re-declared in `src/main.nr` — a module method alone is not callable.
- **Access control is public.** `AccessControlModule` maps `role: Field -> AztecAddress -> bool` in public state; roles are numeric globals (`DEFAULT_ADMIN_ROLE = 1`, `PAUSE_ROLE = 2`, `ENFORCEMENT_ROLE = 3`, `VALIDATION_ROLE = 4`, `ADDRESS_LIST_ADD_ROLE = 5`, `ADDRESS_LIST_REMOVE_ROLE = 6`, `MINTER_ROLE = 7`, `BURNER_ROLE = 8`, `DEBT_ROLE = 9`, `DEBT_CREDIT_EVENT_ROLE = 10`, `EXTRA_INFORMATION_ROLE = 11`). Because the check is public, private entry points enqueue a public `_mint`/`_transfer`/`_burn` that performs both the role check and the pause check. Public-context module methods take `PublicContext` by value, not `&mut PublicContext`.
- **Private/public split per operation.** `mint`, `transfer`, `burn` are `#[external("private")]`: they call an inlined `#[internal("private")]` `_*_internal` that mutates notes via `self.internal`, then `self.enqueue_self` a `#[external("public")] #[only_self]` counterpart that updates `total_supply` and asserts not-paused. A revert in the public part reverts the whole tx.
- **Balances are note sets.** `private_balances` is an `Owned<BalanceSet<Context>>` using the `balance_set` aztec-nr library, reached as `.at(address)`; a balance is the sum of a user's `UintNote`s. `add`/`sub` return a `MaybeNoteMessage` that must be delivered: the owner's copy goes out with `.deliver(MessageDelivery::onchain_constrained())` and the issuer's audit copy with `.deliver_to(issuer, MessageDelivery::offchain())`.
- **`DelayedPublicMutable` delay.** `issuer_address`, freeze flags and validation flags are `DelayedPublicMutable` with `CHANGE_ROLES_DELAY_SECONDS = 360`, so they are readable from private functions without leaking the caller. The delay is a duration in seconds, not a block count, and nothing that reads one of these works until it has elapsed — including every mint, transfer and burn, which all read `issuer_address`.
- **Batching cap.** `MAX_ADDR_PER_CALL = 4`, and that number is **measured, not derived** — 5 breaks batched mint and burn, 6 and above abort `transfer_batch` with `push out of bounds`. `transfer` sets the cap for all three because it creates two notes and two constrained deliveries per recipient. The nested-private-call limit is irrelevant: the `_*_internal` helpers are `#[internal]` and inlined, so a batch makes no nested calls. Raising this global means re-running the suite at the new value and updating every batch test's array literals, not re-reading the protocol constants; see *Batching limits* in the README.
- **Authwits.** `transfer` and `transfer_batch` carry `#[authorize_once("from", "authwit_nonce")]`; `burn` and `burn_batch` carry `#[authorize_once("account", "authwit_nonce")]`, following the CMTAT Solidity naming. The macro takes the parameter **by name**, so renaming that parameter means editing the attribute too. It validates the authwit when `msg_sender()` differs from that account and nullifies the nonce to prevent replay; the account itself must pass `authwit_nonce = 0`. `cancel_authwit` pushes the authwit nullifier. `mint` deliberately has no authwit — only the minter role may mint.
- **No force transfer.** Unlike Solidity CMTAT the issuer cannot move a user's notes; the compliance workaround is freezing the account (see README "Limitations").
- **Issuer audit copies go offchain.** The issuer's copy of each note uses `MessageDelivery::offchain()`, not `onchain_constrained()`. PXE cannot process an onchain note message addressed to a non-owner — note discovery computes the note's nullifier, which needs the owner's key — so an onchain copy compiles but breaks discovery. The trade-off (no onchain data availability for the issuer's copy) is documented in the README and CHANGELOG; do not "fix" this back to onchain without re-testing.

## File tree

The repository is a **Nargo workspace**: Noir has no inheritance and allows one contract per package, so the CMTAT deployment variants are separate contract packages over a shared library.

```
Nargo.toml                           # [workspace] — lib + the three contract packages
lib/                                 # cmtat_aztec_lib, type = "lib": every module lives here
├── src/lib.nr
├── src/modules.nr
└── src/modules/
    ├── access_controlModule.nr      # role constants, RoleData map, has_role/only_role/grant/revoke/renounce
    ├── pauseModule.nr               # PublicMutable<bool> pause + deactivation flags (2 slots)
    ├── enforcementModule.nr         # Freezable: per-address DelayedPublicMutable<FreezableFlag> freeze
    ├── validationModule.nr          # blacklist/whitelist flags, operateOnTransfer
    ├── extraInformationModule.nr    # CMTAT terms + token ID (6 slots): set_terms/terms, set_token_id/token_id
    ├── extensions.nr
    └── extensions/
        ├── creditEventsModule.nr    # CMTAT credit events (flagDefault, flagRedeemed, rating)
        └── debtModule.nr            # CMTAT debt: DebtIdentifier + DebtInstrument, mirroring ICMTATDebt

contracts/
├── cmtat-aztec/                     # CMTATAztec — the base token; carries the full Noir test suite
│   └── src/{main.nr, test.nr, test/*.nr}
├── cmtat-aztec-debt/                # CMTATAztecDebt — base + credit events + debt
│   └── src/{main.nr, test.nr, test/{utils,smoke,test_credit_events,test_debt}.nr}
└── cmtat-aztec-light/               # CMTATAztecLight — base without the validation module
    └── src/{main.nr, test.nr, test/{utils,smoke}.nr}

src/                                 # TypeScript only
├── artifacts/                       # generated: one .ts per variant
├── test/e2e/{index,accounts}.test.ts
└── utils/                           # setup_pxe.ts, setup_pxe_testnet.ts, deploy_account.ts,
                                     # create_account_from_env.ts, sponsored_fpc.ts

scripts/                             # tsx entry points, run via yarn
├── deploy_contract.ts               # deploy CMTATAztec on testnet and grant MINTER_ROLE
├── deploy_account.ts                # deploy a single account
├── interaction.ts                   # mint/transfer/read against a deployed contract
├── multiple_pxe.ts                  # two wallets with separate PXEs on one node
├── get_block.ts                     # query current block
├── fees.ts                          # sponsored FPC, bridge+claim and native Fee Juice payment
└── profile_deploy.ts                # gate-count / profiling of deployment
```

## Other important files

- `README.md` — the specification: assumptions, per-operation privacy requirements, module design, known limitations. Read before changing behaviour.
- `doc/standards/cmtat-vs-aip20.md` — detailed comparison of CMTAT against Aztec's AIP-20 fungible-token standard, why this contract is deliberately **not** AIP-20 (public balances and partial notes both conflict with transfer restriction), and suggestions in both directions. Read it before proposing AIP-20 conformance.
- `doc/standards/building-on-aip20.md` — whether this project could be rebuilt on the `aztec-standards` library. Answer: no. Every crate there is `type = "contract"`, so there is nothing to depend on, and AIP-20's ARC-403 authorization hook is not passed the transfer recipient, so it cannot express CMTAT's screening. Forking the library and moving it to `v5.2.0` was tried and is trivial (eleven manifest edits, no source changes, 79/79 tests pass) — so "hard to port" is **not** the reason; the design conflicts are. Separately, *interface* alignment is cheap: selectors ignore parameter names, so renaming five entry points would match AIP-20's private-path selectors exactly, but `burn` must not be aliased to `burn_private` because the authorisation differs. Read it before proposing a rewrite on top of AIP-20.
- `doc/standards/cmtat-as-aip20-auth-contract.md` — whether `cmtat_aztec_lib` could be packaged as an ARC-403 authorization contract so a stock AIP-20 token gains CMTAT compliance. It can — a probe compiles against the library unmodified and `authorize_private` measures 20,715 gates — but the hook receives neither the recipient nor the initiator, so recipient screening, issuer-only burn and role-gated mint are inexpressible, and the issuer gets no note copies. Five mandatory criteria come out `partial`. A legitimate second product, not a replacement for the token.
- `doc/standards/upgrading-aztec-standards.md` — step-by-step instructions to bring the `aztec-standards` fork from `v5.0.0-rc.2` to this repository's `v5.2.0`: eleven manifest repoints (four aztec-nr crates move to the standalone repository; the `serde` protocol-circuits crate stays in `aztec-packages` with its tag bumped), a script that does it, and the two traps — a blanket URL replace breaks `serde`, and compiling only `token_contract` crashes the TXE on a missing `GenericProxy` artifact. Both repositories must pin the same `aztec-nr` tag or the build fails with "distinct types".
- `doc/standards/aip20-features-for-cmtat.md` — which AIP-20 features could be adopted while staying CMTAT-equivalent, scored against the 61 criteria, the assessment's nine-row **privacy table**, and two products: **CMTAT-private** (the three existing variants, CMTAT names, no AIP-20 surface) and **CMTAT-private-AIP20** (a fourth variant integrating AIP-20). Product map: CMTAT-private gains only the note budget with recursion (measured −43,046 gates) and a settable rule-engine hook passing recipient and caller; the AIP20 variant adds commitment transfers screened at initialization (needing an expiry, an issuer delivery, and disclosure that the completion amount is unencrypted — a privacy-table change, which is why it stays out of CMTAT-private), the five renames and named constructors. Public balances belong to neither; holder self-burn and a single immutable minter are rejected. Also records a correction: the commitment flow *does* know the recipient at initialization.
- `doc/analysis/CLAUDE_ANALYSIS.md` — code-quality review (not a security audit) against Aztec 5.2.0, with a measured gate-count baseline. Findings carry stable IDs (`A-1`, `H-3`, …); cite them by ID in commits and code comments. Two entries are corrections of findings that measurement disproved — read those before re-proposing the change.
- `src/main.nr` holds `VERSION`, a compile-time `str<31>` returned by `version()`. It is not stored state, so it cannot drift from the code — but it must be bumped by hand with every release; the `CHANGELOG.md` checklist carries the step.
- `CHANGELOG.md` — release history plus the project's semver policy (storage/note-layout and external-API breaks are MAJOR) and the pre-release checklist. Add an entry with every release; follow the entry-style rules stated in the file.
- `LEARN-AZTEC.md` — condensed Aztec/Noir notes written while building; useful background, explicitly not kept up to date.
- `Nargo.toml` — Noir package and pinned `aztec-nr` dependencies.
- `package.json` — yarn scripts and pinned `@aztec/*` JS packages.
- `jest.integration.config.json` — ESM ts-jest config for the `src/**/*.test.ts` e2e suite.
- `.env.example` — `L1_URL`, `NODE_URL`, `CMTA_TOKEN_CONTRACT_ADDRESS`, `SECRET*`/`SALT*`, `L1_CHAIN_ID`; copy to `.env` for testnet scripts.
- `SECURITY.md`, `LICENSE-MIT.md`, `LICENSE-MPL.md` — vulnerability reporting; dual MIT / MPL-2.0, © 2025 Taurus SA.
- `doc/img/` — PlantUML sources and their rendered PNGs for the README's diagrams (architecture, public/private state split, mint, transfer, burn, and the delayed-flag model). The `.puml` file is the source of truth: edit it and re-run `plantuml -tpng doc/img/<name>.puml`, never hand-edit a PNG. The README embeds the **image** only; the source stays in `doc/img/`.
- `doc/docs.aztec.network-developers-docs/` — a local, untracked mirror of the Aztec developer docs; handy offline reference, not part of the project.
- Generated and gitignored: `target/`, `src/artifacts/`, `store/`, `codegenCache.json`.

## Dependencies (tested versions)

- Aztec toolchain and `aztec-nr` libraries (`aztec`, `compressed_string`, `uint_note`, `balance_set`) from `AztecProtocol/aztec-nr`: tag **v5.2.0**. Install the matching CLI with `aztec-up install 5.2.0`. `authwit` is now part of `aztec` (`aztec::authwit`); `value_note` is no longer used.
- Noir compiler: 1.0.0-beta.25, shipped with the 5.2.0 toolchain (`Nargo.toml` still declares `compiler_version = ">=0.18.0"`).
- JS: `@aztec/aztec.js`, `@aztec/accounts`, `@aztec/builder`, `@aztec/noir-contracts.js`, `@aztec/pxe`, `@aztec/kv-store` and `@aztec/wallets` at **5.2.0**.
- TypeScript `^5.5.3`, Jest `^29.7.0`, ts-jest `^29.1.4`, tsx `^4.20.3`, Node with `--experimental-vm-modules` (ESM project, `"type": "module"`).

## Common commands

- `yarn install` — install JS dependencies.
- `yarn compile` — `aztec compile --workspace` (override the binary with `AZTEC_COMPILE`); builds all three variants. It must be `aztec compile`, not `aztec-nargo compile`: at 5.2.0 `aztec-nargo` is a bare symlink to `nargo` and does not run the AVM transpiler, so `yarn codegen` then fails with `Contract's public bytecode has not been transpiled`.
- `yarn codegen` — generate TS artifacts from `target/` into `src/artifacts/` (required before any TS test or script).
- `yarn test` — `test:nr` (Noir `aztec test`) then `test:js` (Jest e2e); the e2e suite needs a running sandbox (`aztec start --sandbox`).
- `yarn test:nr` / `yarn test:js` — run one suite only. `test:nr` is `aztec test --workspace`; add a package path to run one variant.
- `yarn deploy`, `yarn deploy-account`, `yarn interaction`, `yarn multiple-pxe`, `yarn get-block`, `yarn fees`, `yarn profile` — testnet scripts (need `.env`).
- `yarn typecheck` — type-check the TypeScript with the compiler pinned in `package.json`. Do not run `npx tsc`: the Aztec toolchain ships its own `tsc` at `~/.aztec/current/node_modules/.bin/`, which lands on `PATH` ahead of `./node_modules/.bin` and type-checks the project with the wrong compiler version.
- `yarn clean` / `yarn clear-store` — drop `src/artifacts`, `target`, `codegenCache.json` / drop the local PXE `store`.

## Conventions

- Noir sources use `camelCase` file names for modules (`access_controlModule.nr`, `validationModule.nr`) and snake_case for functions; keep the existing style rather than renaming.
- Every new public/private entry point goes in `src/main.nr` under the matching banner comment block (`AUTHORIZATION MODULE`, `VALIDATION MODULE`, `MINT`, `TRANSFER`, `BURN`, `INTERNAL`, `UNCONSTRAINED`), with a NatSpec-style `@dev` / `Requirements:` comment.
- Any state-mutating operation must keep the invariant chain: freeze check + validation check in the private internal function, role check + pause check in the enqueued public internal function. That pause check is also what enforces **deactivation**: `deactivate_contract` requires an existing pause and then blocks `unpause_contract` forever, so no separate deactivation check is needed on the value-moving paths.
- Any note written for a user must also be delivered to the current `issuer_address` — auditability is a hard requirement of the design. The issuer's copy uses `MessageDelivery::offchain()`; see the key concept above before changing that.
- Every behaviour change needs a Noir test in `src/test/` (and an e2e test when it crosses the TS boundary); tests build their world through `src/test/utils.nr` `setup*` helpers.
- Bumping the Aztec version means updating `Nargo.toml`, `package.json` and the `aztec-up` version together — they must match. `aztec compile` warns when the dependency tag and the CLI disagree.
- The e2e suite and any operator runbook must account for `CHANGE_ROLES_DELAY_SECONDS`: a scheduled value change is not readable until the delay has elapsed, and a sandbox's clock cannot be fast-forwarded.

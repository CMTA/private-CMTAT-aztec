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

- **Single contract, module structs.** Noir has no Solidity-style inheritance, so "modules" are plain structs implementing `StateVariable<N, Context>` (which supplies both `new` and `get_storage_slot`) and held as fields of the contract's `#[storage] struct Storage<Context>`. Every user-callable entry point must be re-declared in `src/main.nr` — a module method alone is not callable.
- **Access control is public.** `AccessControlModule` maps `role: Field -> AztecAddress -> bool` in public state; roles are numeric globals (`DEFAULT_ADMIN_ROLE = 1`, `PAUSE_ROLE = 2`, `ENFORCEMENT_ROLE = 3`, `VALIDATION_ROLE = 4`, `ADDRESS_LIST_ADD_ROLE = 5`, `ADDRESS_LIST_REMOVE_ROLE = 6`, `MINTER_ROLE = 7`, `BURNER_ROLE = 8`, `DEBT_ROLE = 9`, `DEBT_CREDIT_EVENT_ROLE = 10`). Because the check is public, private entry points enqueue a public `_mint`/`_transfer`/`_burn` that performs both the role check and the pause check. Public-context module methods take `PublicContext` by value, not `&mut PublicContext`.
- **Private/public split per operation.** `mint`, `transfer`, `burn` are `#[external("private")]`: they call an inlined `#[internal("private")]` `_*_internal` that mutates notes via `self.internal`, then `self.enqueue_self` a `#[external("public")] #[only_self]` counterpart that updates `total_supply` and asserts not-paused. A revert in the public part reverts the whole tx.
- **Balances are note sets.** `private_balances` is an `Owned<BalanceSet<Context>>` using the `balance_set` aztec-nr library, reached as `.at(address)`; a balance is the sum of a user's `UintNote`s. `add`/`sub` return a `MaybeNoteMessage` that must be delivered: the owner's copy goes out with `.deliver(MessageDelivery::onchain_constrained())` and the issuer's audit copy with `.deliver_to(issuer, MessageDelivery::offchain())`.
- **`DelayedPublicMutable` delay.** `issuer_address`, freeze flags and validation flags are `DelayedPublicMutable` with `CHANGE_ROLES_DELAY_SECONDS = 360`, so they are readable from private functions without leaking the caller. The delay is a duration in seconds, not a block count, and nothing that reads one of these works until it has elapsed — including every mint, transfer and burn, which all read `issuer_address`.
- **Batching cap.** `MAX_ADDR_PER_CALL = 1`. The protocol allows 8 private calls and 16 private logs per call (up from 4 and 4 before Aztec v3), and a transfer delivers 5 messages per address, so the cap could now be raised — it is kept at 1 so the migration did not change the ABI further. Changing this global requires re-checking the log budget.
- **Authwits.** `transfer`, `transfer_batch`, `burn` and `burn_batch` carry `#[authorize_once("from", "authwit_nonce")]`, which validates the authwit when `msg_sender() != from` and nullifies the nonce to prevent replay; the `from` account itself must pass `authwit_nonce = 0`. `cancel_authwit` pushes the authwit nullifier. `mint` deliberately has no authwit — only the minter role may mint.
- **No force transfer.** Unlike Solidity CMTAT the issuer cannot move a user's notes; the compliance workaround is freezing the account (see README "Limitations").
- **Issuer audit copies go offchain.** The issuer's copy of each note uses `MessageDelivery::offchain()`, not `onchain_constrained()`. PXE cannot process an onchain note message addressed to a non-owner — note discovery computes the note's nullifier, which needs the owner's key — so an onchain copy compiles but breaks discovery. The trade-off (no onchain data availability for the issuer's copy) is documented in the README and CHANGELOG; do not "fix" this back to onchain without re-testing.

## File tree

```
src/
├── main.nr                          # the CMTAToken contract: storage, events, all entry points
├── modules.nr                       # module declarations
├── modules/
│   ├── access_controlModule.nr      # role constants, RoleData map, has_role/only_role/grant/revoke/renounce
│   ├── pauseModule.nr               # PublicMutable<bool> pause flag, guarded by PAUSE_ROLE
│   ├── enforcementModule.nr         # Freezable: per-address DelayedPublicMutable<FreezableFlag> freeze
│   ├── validationModule.nr          # blacklist/whitelist/sanction-list flags, operateOnTransfer
│   ├── extensions.nr                # extension declarations
│   └── extensions/
│       ├── creditEventsModule.nr    # CMTAT credit events (flagDefault, flagRedeemed, rating)
│       └── debtBaseModule.nr        # CMTAT debt terms (interest rate, par value, dates, conventions)
├── types.nr                         # dead: superseded by the balance_set library, delete
├── types/
│   └── balance_set.nr               # dead: superseded by the balance_set library, delete
├── test.nr                          # Noir test module declarations
├── test/
│   ├── utils.nr                     # TestEnvironment setup, check_private_balance, call_private_on_behalf_of
│   ├── reading_constants.nr         # name/symbol/decimals/total_supply reads
│   ├── test_mint.nr                 # mint + mint_batch, role and freeze failure cases
│   ├── test_burn.nr                 # burn + burn_batch, authwit cases
│   ├── transfer_private.nr          # private transfer, authwit, insufficient balance
│   ├── test_pause_module.nr         # pause/unpause and paused-operation reverts
│   ├── test_enforcement_module.nr   # freeze/unfreeze across the DelayedPublicMutable delay
│   ├── test_validation_module.nr    # blacklist/whitelist operate flags
│   ├── test_credit_events.nr        # credit events extension
│   ├── test_debt_base.nr            # debt base extension
│   └── e2e/
│       ├── index.test.ts            # end-to-end token flow against a sandbox
│       └── accounts.test.ts         # account deployment / multi-wallet flow
└── utils/                           # TypeScript helpers shared by tests and scripts
    ├── setup_pxe.ts                 # setupWallet(): EmbeddedWallet + node for a local sandbox
    ├── setup_pxe_testnet.ts         # setupWalletTestnet(): same for testnet (NODE_URL from .env)
    ├── deploy_account.ts            # deploy a Schnorr account
    ├── create_account_from_env.ts   # rebuild accounts from SECRET/SALT in .env
    └── sponsored_fpc.ts             # getSponsoredPaymentMethod(): registers the FPC and returns the payment method

scripts/                             # tsx entry points, run via yarn
├── deploy_contract.ts               # deploy CMTAToken on testnet and grant MINTER_ROLE
├── deploy_account.ts                # deploy a single account
├── interaction.ts                   # mint/transfer/read against a deployed contract
├── multiple_pxe.ts                  # two wallets with separate PXEs on one node
├── get_block.ts                     # query current block
├── fees.ts                          # sponsored FPC, bridge+claim and native Fee Juice payment
└── profile_deploy.ts                # gate-count / profiling of deployment
```

## Other important files

- `README.md` — the specification: assumptions, per-operation privacy requirements, module design, known limitations. Read before changing behaviour.
- `CHANGELOG.md` — release history plus the project's semver policy (storage/note-layout and external-API breaks are MAJOR) and the pre-release checklist. Add an entry with every release; follow the entry-style rules stated in the file.
- `LEARN-AZTEC.md` — condensed Aztec/Noir notes written while building; useful background, explicitly not kept up to date.
- `Nargo.toml` — Noir package and pinned `aztec-nr` dependencies.
- `package.json` — yarn scripts and pinned `@aztec/*` JS packages.
- `jest.integration.config.json` — ESM ts-jest config for the `src/**/*.test.ts` e2e suite.
- `.env.example` — `L1_URL`, `NODE_URL`, `CMTA_TOKEN_CONTRACT_ADDRESS`, `SECRET*`/`SALT*`, `L1_CHAIN_ID`; copy to `.env` for testnet scripts.
- `SECURITY.md`, `LICENSE-MIT.md`, `LICENSE-MPL.md` — vulnerability reporting; dual MIT / MPL-2.0, © 2025 Taurus SA.
- `doc/` — a local, untracked mirror of the Aztec developer docs; handy offline reference, not part of the project.
- Generated and gitignored: `target/`, `src/artifacts/`, `store/`, `codegenCache.json`.

## Dependencies (tested versions)

- Aztec toolchain and `aztec-nr` libraries (`aztec`, `compressed_string`, `uint_note`, `balance_set`) from `AztecProtocol/aztec-nr`: tag **v5.2.0**. Install the matching CLI with `aztec-up install 5.2.0`. `authwit` is now part of `aztec` (`aztec::authwit`); `value_note` is no longer used.
- Noir compiler: 1.0.0-beta.25, shipped with the 5.2.0 toolchain (`Nargo.toml` still declares `compiler_version = ">=0.18.0"`).
- JS: `@aztec/aztec.js`, `@aztec/accounts`, `@aztec/builder`, `@aztec/noir-contracts.js`, `@aztec/pxe`, `@aztec/kv-store` and `@aztec/wallets` at **5.2.0**.
- TypeScript `^5.5.3`, Jest `^29.7.0`, ts-jest `^29.1.4`, tsx `^4.20.3`, Node with `--experimental-vm-modules` (ESM project, `"type": "module"`).

## Common commands

- `yarn install` — install JS dependencies.
- `yarn compile` — `aztec-nargo compile` (override with `AZTEC_NARGO`).
- `yarn codegen` — generate TS artifacts from `target/` into `src/artifacts/` (required before any TS test or script).
- `yarn test` — `test:nr` (Noir `aztec test`) then `test:js` (Jest e2e); the e2e suite needs a running sandbox (`aztec start --sandbox`).
- `yarn test:nr` / `yarn test:js` — run one suite only.
- `yarn deploy`, `yarn deploy-account`, `yarn interaction`, `yarn multiple-pxe`, `yarn get-block`, `yarn fees`, `yarn profile` — testnet scripts (need `.env`).
- `yarn clean` / `yarn clear-store` — drop `src/artifacts`, `target`, `codegenCache.json` / drop the local PXE `store`.

## Conventions

- Noir sources use `camelCase` file names for modules (`access_controlModule.nr`, `validationModule.nr`) and snake_case for functions; keep the existing style rather than renaming.
- Every new public/private entry point goes in `src/main.nr` under the matching banner comment block (`AUTHORIZATION MODULE`, `VALIDATION MODULE`, `MINT`, `TRANSFER`, `BURN`, `INTERNAL`, `UNCONSTRAINED`), with a NatSpec-style `@dev` / `Requirements:` comment.
- Any state-mutating operation must keep the invariant chain: freeze check + validation check in the private internal function, role check + pause check in the enqueued public internal function.
- Any note written for a user must also be delivered to the current `issuer_address` — auditability is a hard requirement of the design. The issuer's copy uses `MessageDelivery::offchain()`; see the key concept above before changing that.
- Every behaviour change needs a Noir test in `src/test/` (and an e2e test when it crosses the TS boundary); tests build their world through `src/test/utils.nr` `setup*` helpers.
- Bumping the Aztec version means updating `Nargo.toml`, `package.json` and the `aztec-up` version together — they must match. `aztec compile` warns when the dependency tag and the CLI disagree.
- The e2e suite and any operator runbook must account for `CHANGE_ROLES_DELAY_SECONDS`: a scheduled value change is not readable until the delay has elapsed, and a sandbox's clock cannot be fast-forwarded.

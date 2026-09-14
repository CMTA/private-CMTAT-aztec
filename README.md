# Private CMTAT security token

A private version of the [CMTAT](https://github.com/CMTA/CMTAT) security token, written in Noir / [Aztec.nr](https://docs.aztec.network/) for the [Aztec](https://aztec.network/) privacy Layer 2 on Ethereum.

Balances and transfers are **private**: a holder's balance is a set of encrypted notes in their own client, and a transfer publishes neither the parties nor the amount. Compliance state stays **public**: total supply, the pause and deactivation flags, the role table, the freeze flags and the transfer-restriction lists. The **issuer** receives a copy of every note and a constrained `Transfer` event, so it can reconstruct every balance and audit activity without any user's cooperation.

> **Repository.** Since **v0.3.0** the project is maintained and released by the [Capital Market and Technology Association](https://cmta.ch/) at [github.com/CMTA/private-CMTAT-aztec](https://github.com/CMTA/private-CMTAT-aztec). Releases 0.1.0 to 0.2.0 were published by Taurus SA at [github.com/taurushq-io/private-CMTAT-aztec](https://github.com/taurushq-io/private-CMTAT-aztec), whose history this repository carries.

> **Disclaimer.** This is a prototype. It has **not** been audited, it is not upgradeable, it has no gasless-transaction support, and it may not be fully compliant with Swiss law. Aztec itself is under heavy development; expect breaking changes between toolchain versions.

## Table of contents

- [Deployment variants](#deployment-variants)
- [Features](#features)
- [Quick start](#quick-start)
- [Repository layout](#repository-layout)
- [Documentation](#documentation)
- [Intellectual property](#intellectual-property)
- [Security policy](#security-policy)

## Deployment variants

Noir has no inheritance and allows one contract per package, so the variants are separate contract packages composing modules from one shared library (`lib/`), built together as a Nargo workspace.

| Variant | Contents |
|---|---|
| `CMTATAztecLight` | Private token, pause, deactivation, freeze, access control, terms, version — no transfer-restriction lists |
| `CMTATAztec` | The above plus the validation module (blacklist / whitelist) |
| `CMTATAztecDebt` | The above plus credit events and debt, for bond-like instruments |

Two further contracts are not tokens but **ARC-403 authorization contracts**: they apply CMTAT's pause, deactivation, freeze and sender-side blacklist / whitelist to the stock tokens of the [CMTA fork of `aztec-standards`](https://github.com/CMTA/aztec-standards), which call them as a hook before every transfer and burn. See [`doc/auth/README.md`](doc/auth/README.md).

| Contract | Restricts |
|---|---|
| `CMTATAztecAuth` | AIP-20 `Token` |
| `CMTATAztecAuthMultiToken` | ARC-1155 `MultiToken` |

A fourth token variant, `CMTATAztecAIP20`, is the fork's AIP-20 `Token` with CMTAT's terms, token ID, roles and `version()` added on the token itself (Noir has no inheritance, so the standard's source is carried verbatim); pause, freeze and the lists reach it through `CMTATAztecAuth`. See [A CMTAT-flavoured AIP-20 token](doc/auth/README.md#a-cmtat-flavoured-aip-20-token).

## Features

- **Private** mint, transfer and burn, in single and batched form, with [authwits](https://docs.aztec.network/developers/docs/foundational-topics/advanced/authwit) in place of ERC-20 allowances.
- **Public** pause (immediate) and permanent deactivation, following the CMTAT Solidity semantics: a pause stops transfers only; deactivation stops everything, forever.
- **Freeze** of individual accounts and **transfer restriction** by blacklist or whitelist, screening both parties of a transfer, the recipient of a mint and the account of a burn.
- **Issuer auditability**: an audit copy of every note and a constrained, unforgeable `Transfer` event to the issuer; the issuer address can be rotated with `set_issuer`.
- **Role-based access control** with the CMTAT role set, plus CMTAT terms / token ID, and, on the debt variant, credit events and the `ICMTATDebt` record.
- **Events** for every state change, public where the state is public and private (encrypted to the parties) for transfers.

Not supported, unlike Solidity CMTAT: upgradeability, gasless transactions, and forced transfer (the issuer cannot move a holder's notes; the compliance lever is freezing the account).

## Quick start

Install the Aztec toolchain at the version pinned in `Nargo.toml` and `package.json`:

```bash
bash -i <(curl -s https://install.aztec.network)
aztec-up install 5.2.0
```

Start a sandbox in one terminal, then build and run every test in another:

```bash
aztec start --sandbox
```

```bash
yarn install
yarn compile      # aztec compile --workspace: all three variants
yarn codegen      # TypeScript artifacts for the e2e suite and the scripts
yarn test         # Noir suite (aztec test --workspace) then the Jest e2e suite
```

`yarn test:nr` runs the Noir suite alone and needs no sandbox. For the testnet scripts (`yarn deploy`, `yarn interaction`, …) copy `.env.example` to `.env` first; see [Deployment](doc/README.md#deployment) in the technical documentation.

## Repository layout

```
lib/                 cmtat_aztec_lib — every CMTAT module (access control, pause, enforcement,
                     validation, extra information, credit events, debt)
test-helpers/        cmtat_aztec_test_helpers — test scaffolding shared by the Noir suites
contracts/
  cmtat-aztec/       CMTATAztec, with the full Noir test suite
  cmtat-aztec-debt/  CMTATAztecDebt
  cmtat-aztec-light/ CMTATAztecLight
  cmtat-aztec-auth/  CMTATAztecAuth — ARC-403 hook for the AIP-20 token of aztec-standards
  cmtat-aztec-auth-multitoken/  CMTATAztecAuthMultiToken — the same for ARC-1155
  cmtat-aztec-aip20/ CMTATAztecAIP20 — the aztec-standards Token plus CMTAT terms, token ID, roles, version
  arc403-interface/  signature-only stub of CMTATAztecAuth, so the token can call the hook (never deployed)
src/                 TypeScript: generated artifacts, e2e tests, PXE / account helpers
scripts/             Testnet scripts (deploy, interact, fees, profiling)
doc/                 Technical documentation, diagrams, standards analyses, assessment, audits
submodules/          Pinned reference repositories: CMTAT, CMTAT-Confidential, the equivalency
                     assessment template, and the CMTA fork of aztec-standards on Aztec 5.2.0
```

## Documentation

- [**Technical documentation**](doc/README.md) — the full specification: assumptions and privacy requirements, the private/public split of each operation with sequence diagrams, batching limits, the event list, what each operation publishes, the module design, deployment, the comparisons with Solidity CMTAT and with CMTAT-Confidential (Zama FHE), known limitations and a glossary.
- [`CHANGELOG.md`](CHANGELOG.md) — release history, semver policy and the pre-release checklist.
- [`doc/standards/`](doc/standards/) — how this token relates to Aztec's AIP-20 token standard: a [detailed comparison](doc/standards/cmtat-vs-aip20.md), whether it could be [built on the `aztec-standards` library](doc/standards/building-on-aip20.md), used as an [ARC-403 authorization contract](doc/standards/cmtat-as-aip20-auth-contract.md), which [AIP-20 features fit CMTAT](doc/standards/aip20-features-for-cmtat.md), and how the [`aztec-standards` fork](https://github.com/CMTA/aztec-standards) checked out under `submodules/` was [brought to Aztec 5.2.0](doc/standards/upgrading-aztec-standards.md).
- [`doc/auth/README.md`](doc/auth/README.md) — the two authorization contracts: how the ARC-403 hook works, what they enforce and cannot (lists and freeze on the sender only, no recipient or initiator screening, mints unhooked, AIP-721 without a hook), how to deploy and operate them, and how they were verified against the real tokens.
- [`doc/cmtat-assessment/`](doc/cmtat-assessment/README.md) — the CMTAT equivalency assessment of this implementation, criterion by criterion.
- [`doc/audits/tools/v0.3.0/CLAUDE_ANALYSIS.md`](doc/audits/tools/v0.3.0/CLAUDE_ANALYSIS.md) — tool-assisted code-quality review against Aztec 5.2.0, with a measured gate-count baseline and the disposition of every finding.
- [`LEARN-AZTEC.md`](LEARN-AZTEC.md) — Aztec / Noir notes written while building; background, not kept up to date.
- [`CLAUDE.md`](CLAUDE.md) — the agent and contributor guide: key concepts, conventions and commands.

## Intellectual property

The code is copyright (c) Capital Market and Technology Association, 2026, and is released under the [Mozilla Public License 2.0](LICENSE-MPL.md) and the [MIT license](LICENSE-MIT.md). You may choose either license.

The history up to and including commit [`61f4220d5565840fd4fcdd2b723c9f55eb824c60`](https://github.com/taurushq-io/private-CMTAT-aztec/commit/61f4220d5565840fd4fcdd2b723c9f55eb824c60) (the 0.2.0 release, and so the 0.1.0, 0.1.1 and 0.2.0 releases) is copyright (c) 2025 Taurus SA, under the same two licenses. Later commits are copyright CMTA.

We are not aware of any patent or patent application covering the techniques implemented.

## Security policy

Please see [SECURITY.md](SECURITY.md).

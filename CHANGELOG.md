# CHANGELOG

Please follow [https://changelog.md/](https://changelog.md/) conventions.

> **This code has not been audited.** It is a prototype of a private CMTAT on Aztec, published for review and experimentation, and it is not fit for production use with real assets.

## Semantic Version 2.0.0

Given a version number MAJOR.MINOR.PATCH, increment the:

1. MAJOR version when the new version makes:
   - An incompatible change to contract **storage** — the `#[storage] struct Storage` layout, a state-variable type (`PublicMutable` / `SharedMutable` / `PrivateSet`), or the shape of a note (`UintNote`) or a packed struct (`UserFlags`, `FreezableFlag`, `CreditEventsStruct`, `DebtBaseStruct`)
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
npx tsc --noEmit
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

- Rewritten as a modular contract on a current Aztec version, with testnet deployment scripts and an end-to-end test suite.

### Added

- Testnet deployment and interaction scripts under [scripts/](./scripts): `deploy_contract.ts`, `deploy_account.ts`, `interaction.ts`, `multiple_pxe.ts`, `get_block.ts`, `fees.ts`, `profile_deploy.ts`.
- TypeScript helpers under [src/utils/](./src/utils) for PXE setup (sandbox and testnet), Schnorr account deployment, account recreation from `.env`, and the sponsored FPC fee-payment instance.
- CMTAT extension modules: credit events (`flagDefault`, `flagRedeemed`, `rating`) and debt base (interest rate, par value, maturity date, day-count and business-day conventions), each guarded by its own role.
- `cancel_authwit`, which pushes the authwit nullifier so a granted authentication witness can be revoked before use.
- Agent guide files [CLAUDE.md](./CLAUDE.md) and [AGENTS.md](./AGENTS.md).

### Changed

- Restructured the contract into module structs held as fields of the storage struct — access control, pause, enforcement (freeze), validation (blacklist/whitelist), and the two extensions — instead of keeping the logic inline in `main.nr`.
- Moved role checks and the pause check into enqueued public internal functions (`_mint`, `_transfer`, `_burn`), so private entry points do the note work and the public part enforces the public invariants.
- Replaced `ValueNote` with `UintNote` as the private balance note.
  - `BalanceSet` now wraps `PrivateSet<UintNote>` and stores a `u128` amount per note.
  - This is a note-layout change: notes created by an earlier version cannot be read by this one.
- Amount types moved to `u128` across mint, transfer, burn and `total_supply`.

### Dependencies

- Aztec and `aztec-nr` (`aztec`, `authwit`, `compressed_string`, `value_note`, `uint_note`) upgraded from `aztec-packages-v0.63.1` to **v0.87.8**, via 0.67.1 and 0.87.2.
- `@aztec/aztec.js`, `@aztec/accounts`, `@aztec/builder`, `@aztec/noir-contracts.js` pinned to v0.87.8; `@aztec/pxe` and `@aztec/kv-store` to `^0.87.8`.
- Noir `compiler_version` requirement relaxed to `>=0.18.0`.

### Testing

- Noir/TXE test suite covering mint, burn, private transfer, pause, enforcement, validation, the two extensions, and constant reads.
- Jest end-to-end suite (`src/test/e2e/`) exercising the token and account flows against a sandbox PXE with sponsored fee payment.

### Documentation

- README extended with testnet deployment instructions alongside the sandbox ones.

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

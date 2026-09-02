# Private CMTAT security token

This project implements a private version of the CMTAT security token,
using [Aztec](https://aztec.network/).
This allows banks and financial institutions to benefits from
tokenization while maintaining privacy and compliance.

[Aztec](https://aztec.network/) is a privacy-focused Layer 2 solution on
Ethereum that enables confidential transactions using zero-knowledge
proofs (ZKPs). 

[CMTAT](https://github.com/CMTA/CMTAT?tab=readme-ov-file) is a framework
for the tokenization of securities in compliance with local regulations.
This project integrates Aztec with CMTAT, allowing financial
institutions to adopt the standard while preserving transaction
confidentiality.

This repository contains a functional private CMTAT prototype, where
transactions remain private for users, while issuers retain the ability
to audit and monitor activity to ensure compliance. This marks a
significant step forward, enabling institutions to participate in
tokenized markets without exposing confidential data—overcoming one of
the key limitations of public blockchains.

**Disclaimer:** Aztec is under heavy developpment, and this repository
may be subject to rapid changes. Significant updates will needed once
Aztec reaches mainnet. Additionally, unlike CMTAT, this code has not
been audited and may not be fully compliant with the Swiss law. 


## Table of contents

- [Glossary](#glossary)
- [Functionalities overview](#functionalities-overview)
- [Private token implementation](#private-token-implementation)
  - [Assumptions and requirements](#assumptions-and-requirements)
  - [Storage](#storage)
  - [Mint private specifications](#mint-private-specifications)
  - [Transfer private specifications](#transfer-private-specifications)
  - [Burn private specifications](#burn-private-specifications)
  - [Security and confidentiality properties](#security-and-confidentiality-properties)
  - [Modules](#modules)
  - [Issuer's view of transactions and notes](#issuers-view-of-transactions-and-notes)
- [Deployment](#deployment)
- [Comparison with Solidity CMTAT](#comparison-with-solidity-cmtat)
- [Limitations](#limitations)
- [Miscellaneous](#miscellaneous)
- [Intellectual property](#intellectual-property)
- [Security](#security)


## Glossary

Terms you need in order to read this repository. The first table is Aztec the protocol, the second is the Aztec.nr code you will meet in `src/`, and the third is CMTAT and the decisions specific to this project.

### Aztec protocol

| Term | Definition |
|---|---|
| **Aztec** | A privacy-focused Layer 2 on Ethereum. Every transaction has a private part, proven on the user's own device with zero-knowledge proofs, and a public part, executed by the network like an EVM transaction. |
| **L1 / L2** | L1 is Ethereum, where Aztec settles and where fee juice is bridged from. L2 is Aztec itself. |
| **Private execution** | Contract code run locally by the user. Its inputs and outputs stay secret; the network only sees a proof plus the note hashes and nullifiers it produced. |
| **Public execution** | Contract code run by the sequencer over public state, visible to everyone. Public calls made from private code run *after* all private execution, so they cannot return a value to it. |
| **Utility function** | An unconstrained, offchain query (`#[external("utility")]`). It never appears in a transaction and carries no correctness guarantee — it is the Aztec analogue of an `eth_call`-only view. `balance_of_private` is one. |
| **Note** | The unit of private state: a small struct (here a `UintNote` holding a `u128` amount) whose *hash* is published onchain while its content stays private. A private balance is the sum of the notes a holder owns. |
| **Note hash tree** | The append-only onchain tree of note hashes. Append-only so that spending a note cannot be linked to its creation. |
| **Nullifier** | A deterministic, secret-derived value published when a note is spent. The protocol rejects duplicates, which is what prevents double-spending. Only the note's owner can compute it. |
| **Nullifier tree** | The append-only onchain tree of nullifiers. A note is unspent exactly when its nullifier is absent. |
| **Note discovery** | How a recipient learns that a note was created for them: the sender encrypts a message with the note's content and delivers it, and the recipient's PXE decrypts it and verifies the note hash onchain. |
| **PXE** | *Private eXecution Environment* — the client-side component holding a user's keys and private notes, and running private functions. Each user has their own; one PXE cannot read another's notes. |
| **Sequencer** | The network actor that orders transactions and executes their public parts. |
| **AVM** | The public virtual machine the sequencer runs, comparable in model to the EVM. |
| **Authwit** | *Authentication witness* — a signed authorisation letting a third party perform one specific action on your behalf. The Aztec equivalent of an ERC-20 `approve` + `transferFrom`, but scoped to an exact call and consumed once. |
| **Fee juice** | The native token used to pay transaction fees, bridged from L1. |
| **FPC / Sponsored FPC** | *Fee Payment Contract* — pays fees on a user's behalf. The sponsored FPC pays unconditionally, which is how fresh accounts in this repo transact without being funded first. |
| **Sandbox** | A local Aztec network for development (`aztec start --sandbox`). |
| **Testnet** | The public Aztec test network, targeted by the scripts in `scripts/`. |

### Aztec.nr and the code in `src/`

| Term | Definition |
|---|---|
| **Noir** | The language Aztec contracts are written in. Rust-like syntax, but it compiles to zero-knowledge circuits, which is why there is no inheritance and no early `return`. |
| **Aztec.nr** | The Noir framework providing the contract macros, state variables and note types. Pinned to **v5.2.0** here. |
| **TXE** | *Test eXecution Environment* — the harness behind `aztec test` that runs Noir tests against a simulated network. Everything in `src/test/*.nr` targets it. |
| **`#[external("private" \| "public" \| "utility")]`** | Marks a function callable from outside the contract, and says which environment runs it. |
| **`#[internal("private" \| "public")]`** | A helper callable only from inside the contract and **inlined** at the call site — reached through `self.internal`. `_mint_internal`, `_transfer_internal` and `_burn_internal` are these. |
| **`#[only_self]`** | A real (non-inlined) function only the contract itself may call. The enqueued public halves `_mint`, `_transfer` and `_burn` use it. |
| **`self.enqueue_self`** | Schedules one of this contract's public functions to run after private execution. This is how a private mint updates the public `total_supply`. |
| **`#[authorize_once("from", "authwit_nonce")]`** | Macro that validates the authwit when the caller is not `from`, and nullifies the nonce so it cannot be replayed. The `from` account itself must pass `authwit_nonce = 0`. |
| **Storage slot** | The index that keeps one state variable's data from colliding with another's. Assigned automatically. |
| **`PublicMutable<T>`** | Public value, read and written by public functions only. Used for `total_supply` and the role table. |
| **`PublicImmutable<T>`** | Public value written once and readable everywhere, including private functions. Used for `name`, `symbol`, `decimals`. |
| **`DelayedPublicMutable<T, DELAY>`** | A public value whose writes take effect only after `DELAY`. That delay is what makes it readable from a *private* function, since the circuit can prove the value cannot change for a known window. Used for `issuer_address`, freeze flags and validation flags. **`DELAY` is a number of seconds** (`CHANGE_ROLES_DELAY_SECONDS = 360`), not a block count. |
| **`Owned<V>`** | Wrapper required by private state variables, binding them to an owner; reached with `.at(address)`. |
| **`PrivateSet<Note>`** | A collection of notes belonging to one owner. |
| **`BalanceSet`** | The Aztec.nr state variable for private balances, a `PrivateSet<UintNote>` with `add` / `sub` / `balance_of`. `private_balances` is an `Owned<BalanceSet>`. |
| **`Map<K, V>`** | Key-value container for *public* state, the analogue of a Solidity `mapping`. Private state uses `Owned` instead. |
| **`UintNote`** | The built-in note type holding a `u128`, used here for token amounts. |
| **Note message / `MessageDelivery`** | Creating a note yields a message that **must** be delivered, and you choose how: `onchain_constrained()` (proven, most expensive), `onchain_unconstrained()` (onchain but trusts the sender), or `offchain()` (cheapest, no onchain data). See *Issuer's view of transactions and notes* for the choice made here. |
| **`deliver_to(address, mode)`** | Delivers a copy of a note message to somebody who is *not* the note's owner. They learn the note exists; they cannot spend it, and cannot see when it is spent. This is the issuer's audit channel. |
| **Module (in this repo)** | Because Noir has no inheritance, each concern is a plain struct held as a field of the contract's storage: `access_control`, `pause_module`, `enforcement_module`, `validation_module`, `credit_event_module`, `debt_base_module`. Every user-callable entry point is still re-declared in `src/main.nr`. |
| **`EmbeddedWallet`** | The TypeScript wallet used by `scripts/` and the end-to-end tests. It owns its own PXE and holds several accounts; each call names its sender with `from`. |
| **`aztec codegen`** | Generates the typed TypeScript contract bindings in `src/artifacts/` from the compiled artifact. Re-run it after any change to the contract's interface. |

### CMTAT and this project

| Term | Definition |
|---|---|
| **CMTAT** | *Capital Markets and Technology Association Token* — a standard for tokenising securities in line with local regulation. This repository is a private implementation of it. |
| **Security token** | A token representing a regulated financial instrument (a bond, an equity share, a private credit note) rather than a utility asset. |
| **Issuer** | The institution that issues the token. It mints and burns, and it receives a copy of every note so it can audit holdings. Its address lives in `issuer_address`. |
| **Admin** | Holder of `DEFAULT_ADMIN_ROLE` (role `1`), the only role that can grant and revoke the others. Granted at deployment. Note that `getRoleAdmin` returns `DEFAULT_ADMIN_ROLE` for *every* role, including itself, so an admin can appoint another admin — the *Assumptions* section below states the admin cannot be changed, but the code does not enforce that. |
| **Role** | A numeric permission checked in public state: `DEFAULT_ADMIN_ROLE` 1, `PAUSE_ROLE` 2, `ENFORCEMENT_ROLE` 3, `VALIDATION_ROLE` 4, `ADDRESS_LIST_ADD_ROLE` 5, `ADDRESS_LIST_REMOVE_ROLE` 6, `MINTER_ROLE` 7, `BURNER_ROLE` 8, `DEBT_ROLE` 9, `DEBT_CREDIT_EVENT_ROLE` 10. |
| **Authorisation module** | The role table (`access_control`) plus `only_role`, the check every other module calls. |
| **Pause module** | A public on/off switch. While paused, mint, transfer and burn all revert, because each enqueues a public call that asserts the contract is not paused. |
| **Enforcement module** | Per-address freezing. A frozen address can neither send nor receive. Because the flag is a `DelayedPublicMutable`, a freeze takes effect only after the delay. |
| **Validation module** | Transfer restriction by address list. Holds each address's flags and the switch saying which lists are enforced. |
| **Blacklist / whitelist / sanction list** | The three list modes (`BLACKLIST_FLAG` 1, `WHITELIST_FLAG` 2, `SANCTIONLIST_FLAG` 4). Blacklist blocks listed addresses, whitelist allows only listed ones, sanction list is declared but not implemented. |
| **Credit events extension** | CMTAT bond attributes recording default, redemption and rating. |
| **Debt base extension** | CMTAT bond terms: interest rate, par value, maturity date, day-count and business-day conventions, and related fields. |
| **Total supply** | Deliberately **public**. Balances are private, but the number of tokens in circulation is not, and it moves visibly on every mint and burn. |
| **Force transfer** | The CMTAT power to move a holder's tokens without their consent. **Not possible here**, because the issuer cannot compute another holder's nullifiers. Freezing the account is the workaround — see *Limitations*. |
| **Batch functions** | `mint_batch`, `transfer_batch` and `burn_batch`, capped by `MAX_ADDR_PER_CALL` (currently `1`) because the protocol limits how many messages and nested calls one call may produce. |
| **`CHANGE_ROLES_DELAY_SECONDS`** | The delay, in seconds (`360`), before a scheduled change to the issuer address, a freeze or a list entry becomes current. Nothing that reads those values sees the new one before it elapses — including every mint, transfer and burn, which all read the issuer address. |

## Functionalities overview

The private CMTAT supports the following core features:

 - **Private** mint, burn, and transfer operations
 - **Public** pause of the contract and public freeze of specific accounts
 - **Auditability** of users private transactions by a central issuer
 - **Transfer restriction** via address blacklisting/whitelisting

Unlike the reference [Solidity CMTAT](https://github.com/CMTA/CMTAT), it
does not support:
 - Upgradeability
 - Gasless transactions

This reference implementation aims to fulfill the criteria required to
tokenize financial instruments such as bonds, equity shares, and private
credit notes.

You may modify the token code by adding, removing, or modifying
features, at your own risk.


## Private token implementation

### Assumptions and requirements

- **Assumptions**:
  - **Total supply visibility**: The `totalSupply` should remain public and be updated according to mint and burn operations.
  - **Issuer and admin addresses**: The addresses of the issuer and admin can be publicly known.
  - **Third-party transactions**: We want to allow third parties to execute transactions on behalf of our users, so we use **authentication witnesses** when transferring. (same functionality as `transferFrom` on EVM)
  - **Mint and burn restrictions**: There is no authentication witness in the `mint` and `burn` functions, as a third party is not allowed to mint or burn; only the issuer can perform these actions.
  - **Admin role**: The admin cannot be changed. Issuers can be added or removed by the admin.

- **Functionalities**:
  - **Totalsupply - Public Context**: For a particular CMTAT token, anyone may know the total number of tokens in circulation at any point in time.

  - **BalanceOf - Private Context**: For a particular CMTAT token and a particular user, no one apart from the issuer should know the number of tokens currently recorded on the user's ledger address.

  - **Transfer - Private Context**: Users may transfer some or all of their tokens to another ledger address (which the transferor does not necessarily control). Each transfer must remain private: only the transacting parties and the issuer may know that the transfer occurred, who the participants are, and how much was transferred.

    > **Note**: The issuer cannot do a force transfer on behalf of the user, as he would do in the Solidity version of CMTAT. The solution is that in the case where we want to have the same behaviour as a force transfer, we freeze the account.

  - **Mint - Private Context** Issue a given number of tokens to a given ledger address. The issuer and the recipient should be the only ones who know that a transaction is happening. Only the issuer and the receiving address should know the amount minted.

    > **Note**: According to the assumption, the total supply will increase accordingly in a public function, and thus the new total supply will be visible to everyone. The supply change amount will be traceable to that particular private proof.

  - **Burn - Private Context** The issuer burns (destroys) a given number of tokens from a given ledger address. The issuer and the given address should be the only ones who know that a transaction is happening.

    > **Note**: Under the above assumptions, a public function will reduce the total supply when a burn happens. Therefore, the updated total supply will be visible to everyone, and the amount of the change can be traced back to a specific private proof.

### Storage

- **Issuer_address**: `DelayedPublicMutable<AztecAddress, CHANGE_ROLES_DELAY_SECONDS>` - The address of the issuer, which serves as a base reference to encrypt users' notes. As it is a `DelayedPublicMutable`, it can be changed if compromised, though only after the delay.
- **Balances**: `Owned<BalanceSet>` - Token balance of every user inside their PXE, accessed as `private_balances.at(address)`. The balance of a user is the sum of the amounts of all their private `UintNote`. `BalanceSet` now comes from the `balance_set` aztec-nr library rather than being defined in this repository.

### Mint private specifications

**Issuer**:

- The new notes of the recipient are broadcasted to the issuer.

**Failure cases**:

- **Enforcement module**: If the `recipient` address is frozen, the mint will fail.
- **Authorisation module**: If the caller doesn’t have the minter role, the mint will fail.
- **Pause module**: If the contract is paused, the mint will fail.

**Limitations**:

- According to protocol limitations, only **16 private logs** can be emitted in a function call and only **8 private functions** can be called from a function call. As we have 2 encrypted logs emitted in the mint function, our bottleneck is the encrypted logs, which means we can only batch **2 mint functions** at the same time.

### Transfer private specifications

**Issuer**:

- The added notes from sender and recipient are broadcasted to the issuer.

**Failure cases**:

- **Enforcement module**: If `from` or `to` addresses are frozen, the transfer will fail.
- **Validation module**: If operations are enabled, the module checks if `from` or `to` should be restricted.
- **Pause module**: If the contract is paused, the transfer will fail.

**Limitations**:

- According to protocol limitations, only **16 private logs** can be emitted in a function call. As the mint already emits 4 (2 for the user, 2 for the issuer), we can only have **1 transfer** in the transfer batch.

### Burn private specifications

**Issuer**:

- The new notes of the recipient (if any remaining) are broadcasted to the issuer.

**Failure cases**:

- **Enforcement module**: If `from` address is frozen, the burn will fail.
- **Authorisation module**: If the caller doesn’t have the burner role, the burn will fail.
- **Pause module**: If the contract is paused, the burn will fail.
- **Authwit**: If `from` doesn't issue an `AuthWit` the burn will fail

 > **Note**: The `AuthWit` issue is a key difference from Solidity smart contract logic, and users should be aware.  

**Limitations**:

- According to protocol limitations, only **16 private logs** can be emitted in a function call and only **8 private functions** can be called from a function call. As we have 2 encrypted logs emitted in the burn function, our bottleneck is the encrypted logs, which means we can only batch **2 burn functions** at the same time.

### Security and confidentiality properties

- **Private mint call to public function**:
  - **Reveals minter address**: Since it is a parameter in the public function call. It is the issuer, whose address is already known, but still, private to public function calls pose a problem as they also reveal that the contract was called.
  - **Randomizing `msg.sender`**: An out-of-protocol option is to deploy a diversified account contract and route transactions through this contract. Application developers might also do something similar to randomize the `msg.sender` of their app contract's address.
  - **Leakage of minted amount**: The amount being minted is leaked as it is passed to the public function from the private one.
  > In the case of our token, when an issuer mints tokens, it is publicly known how much tokens he mints. This means that if the issuer mints “on-demand“ (every time a user wants to mint some tokens, the issuer mints) then there is a leak of information. This can be mitigated by the issuer minting a fixed amount of tokens at a certain point in time (= circulating supply), and then privately distributing to the users, thus revealing way less information. 
  - **Traceability**: The public transaction will be traceable back to the private proof.
  - **Disclosure of private function call**: It will leak that a private function (`private_mint`) has been called.
  - **Recipient address privacy**: It will **not** leak the address to which this amount is being sent.


- **Note encryption constraints**:
  - Note encryption should be **constrained**. We could make note encryption and tagging unconstrained, as this is allowed, but we don’t want to.
  - **Incentive alignment**: Unconstrained note encryption is done when the sender has an incentive to send correct information to the receiver, as no one proves and verifies it. However, in our case, the sender is in no way incentivized to do the right thing.
  - **Optimization**: For optimization purposes, unconstrained might be acceptable in some places.

### Modules

Aztec Noir uses Rust-like modularity, which means that there is no Solidity-like abstract contract and inheritance. Instead, we use separated modules in the form of interfaces and implementations. Every function that can or should be called by a user needs to be exposed in the main contract. Consequently, not everything can be displaced from the main contract (e.g., `mint`, `burn`, and `transfer` are all in the main contract), and most functions are exposed there.

#### Authorisation module (access control) - Public Context

- This module is used by other modules and by the `mint` and `burn` functions.
- Modules only need to call the `only_role` function, which publicly verifies if an address has sufficient roles for the action; otherwise, it reverts.
- The default role is the `DEFAULT_ADMIN_ROLE`, which can grant other roles.
- **Implementation note**: This module's implementation is quite cumbersome, as in the main contract, an instance of this module is passed to each function call. This is because the object is unique, and we cannot pass it as a context (at least until a working implementation is found).

#### Validation module - Shared Context

- This module is called only when performing transfers.
- The `operateOnTransfer` function, used in a private context, is called by the transfer function.
- Each user flag update will be delayed by `CHANGE_ROLES_DELAY_SECONDS`.
- If no operations are enabled, no checks are done, but the function is still called.
- Operations can be enabled or disabled, and there is also a delay.
- Currently, no operations can be added; there is only blacklist/whitelist, and the sanction list is not implemented.

**Delay issue**:

- The delay is caused by the fact that the roles are stored in a `DelayedPublicMutable` variable type.
- This is needed to preserve privacy when doing a private transfer between two users while maintaining the strict rule that no tokens should be transferred from/to a blacklisted address.
- **Problem**: A user who knows they are going to be blacklisted before the delay elapses might send their funds to an address that is not blacklisted. This problem has no solution for now.
- **Consideration**: We need to think about whether the shared state will be changed often. If not, then `DelayedPublicMutable` is an acceptable solution; otherwise, it might be problematic.

**Potential solutions**:

- **Theoretical solution 1**: Using a `DelayedPublicMutable` is essential because otherwise, you would use a `PublicMutable`, which means that the user calling the transfer function needs to call a public function to read the `PublicMutable` variable, leaking the sender’s address. One possible solution might be to hide the caller's address using [Diversified and Stealth Addresses](https://docs.aztec.network/protocol-specs/addresses-and-keys/diversified-and-stealth). If reading `PublicMutable` did not leak the user address, then `DelayedPublicMutable` would be unnecessary.
- **Theoretical solution 2**: Have a counter that is set when the `DelayedPublicMutable` is changed. For the `COUNTER` amount of time, the token contract is paused to prevent any blacklisted address from retrieving funds. This solution is poor in terms of user experience and developer experience, as the issuer needs to manually unpause the contract.
- **Practical solution 3**: If we whitelist instead of blacklist, a new whitelisted address will not be able to transfer funds directly, which is not a significant issue.

#### Pause module - Public Context

- The pause module is a `PublicMutable`.
- The functions to set and unset the pausable flag are protected under Access Control.
- The pause check is done in public state for mint/transfer/burn operations.

#### Enforcement module - Shared Context

- This module is called in `mint`, `transfer`, and `burn` to check if an address has been frozen.
- Unlike the validation module, this module is mandatory.
- Changing an address to frozen has a delay, as the value is a `DelayedPublicMutable`.

> **"Freeze Address" Note**: The enforcement has a delay, similar to the validation module. One approach is to pause the contract before freezing some accounts for the delay time, then unpause it. This requires manual pause/unpause.

### Issuer's view of transactions and notes

- **Objective**: Enable the issuer to see all transactions.
- **Current implementation**: Note emission is duplicated: one message for the owner of that note, and a second copy of the same message for the issuer (`deliver_to(issuer, ...)`).
- **Delivery mode of the issuer's copy**: the owner's copy is delivered onchain and constrained; the issuer's copy is delivered **offchain**. Aztec's own documentation presents an onchain constrained copy to an auditor as the supported pattern, but PXE cannot process an onchain note message addressed to someone who is not the note's owner: note discovery computes the note's nullifier, which needs the owner's nullifier key. Delivering the issuer's copy offchain sidesteps that, at the cost of the issuer's copy having no onchain data availability - the issuer must capture these messages as they are produced, and a sender who drops them is not detectable onchain.
- **Other potential implementations**:
  - **App-siloed key**: Use an app-siloed key that the issuer can use for decrypting any note in the note hash tree of this app.

## Deployment

### Sandbox

Use these deployment instructions for quick testing.

Get the **sandbox, aztec-cli, and other tooling** with this command:

```bash
bash -i <(curl -s https://install.aztec.network)
```

Install the correct version of the toolkit with:

```bash
aztec-up install 5.2.0
```
version should match [Nargo.toml](https://github.com/taurusgroup/private-tokens/blob/master/Nargo.toml) dependency versions. More instructions [here](https://docs.aztec.network/guides/getting_started)

Start the sandbox with:

```bash
aztec start --sandbox
```

Run:

```bash
yarn install
yarn compile
yarn codegen
yarn test
```

The contract is deployed on the sandbox, by the [setup function](https://github.com/taurushq-io/private-CMTAT-aztec/blob/master/src/test/utils.nr), and all the tests are run.

### Testnet

---

Use these deployment instructions for Testnet interactions.Testnet interactions are possible via scripts in the `./scrpits` folder. With the below commands, we run the `deploy_contract.ts` script. 

Run:

```bash
yarn compile
yarn codegen
yarn deploy
```

If you run into troubleshooting issues, consult the [Aztec starter repository](https://github.com/AztecProtocol/aztec-starter/tree/main) and try running it first.


## Comparison with solidity CMTAT

### What can we actually do with private CMTAT?

- **Mint/transfer**: Behave the same way as in CMTAT. 
- **Burn**: We can perform `burn_from` with allowance.
- **Validation module**: Whitelisting and blacklisting are enabled on demand. The rule engine has been merged into the validation module, providing one interface that manages both and is always deployed along the main contract. The functionalities are private; storage can be read in public.
- **Pause module**: Same functionalities as CMTAT. Pause is public and instantaneous.
- **Enforcement module**: Freeze and unfreeze are supported. Functionalities are private; storage can be read in public. There is a delay.
- **Access control module**: Same functionalities as CMTAT. Admin has the default role, which can be used to grant roles to themselves or others.
- **Credit events and debt base modules**: Same functionalities as CMTAT.

### What will we be able to do in the future?

- **Batched mint/transfer/burn**:
  - Protocol limitations currently restrict us to 8 private calls and 16 private logs per function call.
  - In the long run, these limitations will be lifted, enabling batched transactions. The logic is already implemented in the contracts.

> These functions are not separated into their own “abstract contract” as it does not exist in Aztec. We could put them in a library but this would mean much more boilerplate code. Following Aztec improvements, we may improve composition/abstraction in the future. 

- **Validation module enhancements**:
  - The limitation regarding `DelayedPublicMutable` delay means changes to the whitelist/blacklist have a delay (minutes to hours) before reflecting on the blockchain.
  - Sanction lists are not yet enabled due to the lack of on-chain lists like Chainalysis on Ethereum.

- **Audit capabilities**:
  - Users may, in the future, be able to arbitrarly share to third-parties a shareable key for audit purposes.

- **Event management**:
  - Events are not yet enabled because they are cumbersome; they can only be in the main contract for now and make the code lengthy.

### What will we never be able to do by design?

- **Force burning without consent**:
  - We will never be able to burn someone else’s tokens without their approval.
  > This could be possible if the token is implemented at the account contract level, and the issuer has shared nullifiers with the user for that specific account that holds notes for this token.

- **Immediate shared state changes**:
  - We cannot have a shared state (public and private) that has no delay when changed, due to the protocol's construction.

## Limitations

- **Issuer's view of user balances**: [SEE](#issuers-view-of-transactions-and-notes)
- **Force transfer requirement**: [SEE](#transfer---private)
  - According to Swiss law, the issuer should be able to force the transfer of notes.
  - **Current limitation**: This is not possible in Aztec as it would require the issuer to nullify a user's notes without consent.
  - **Workaround**:
    - Freeze the account.
    - If the account is frozen indefinitely, decrease the circulating supply. As a central issuer, I know the number of tokens the user has, so I can decrease supply accordingly. 
> Note: account freeze could reveal how much tokens a user had. 

- **DelayedPublicMutable delay**: [SEE](#validation-module---shared)
  - Freezing and blacklisting addresses take effect only after a delay, measured in seconds, due to the `DelayedPublicMutable` type. Before Aztec v3 this delay was expressed in blocks.
  - **Options**:
    - Accept the delay.
    - Encrypt the blacklist with a key (implementation unclear).

- **Protocol limitations**: 
  - Only **8 private calls** can be made from a private function, limiting batch functions.
  - Only **16 private logs** can be emitted in a function call, further limiting batching.

## Miscellaneous

- **Wallet responsibilities**:
  - The wallet should implement note discovery and tagging mechanisms, not the application.

- **Mint function restrictions**:
  - Should we restrict the "to" address to not be the issuer to prevent a malicious issuer from hiding the real supply of the token by minting tokens to themselves?

- **Contract modification**:
  - Can a user modify a token contract function? No, it is not possible as each function is committed on the public state.

- **Encryption details**:
  - Encryption of note emission is done with AES-128. It's currently unclear if the encryption with AES is constrained at the protocol circuit level.

- **Transaction details**:
  - Notes are linked to their transaction hash because they are in the same transaction object when waiting in the mempool.
  - The transaction object cannot be modified between the point when it has been locally proven and when it reaches the sequencer because the output of the private kernel circuit is the input to the public kernel circuits, which it also verifies.

- **Replay attacks**:
  - The transaction hash is always emitted during local execution as the first nullifier of the transaction to prevent replay attacks. This is enforced by the private kernel circuit.

- **External references**:
  - Aztec Development Notes: [Engineering Designs](https://github.com/AztecProtocol/engineering-designs)
  - Protocol Limitations: [Aztec Protocol Circuits](https://github.com/AztecProtocol/aztec-packages/blob/aztec-packages-v0.49.1/noir-projects/noir-protocol-circuits/crates/types/src/constants.nr)

## Intellectual property

This code is copyright (c) 2025 Taurus SA and is dual-licensed under the MIT and MPL-2.0 licenses.  You may choose either license.

See [LICENSE-MIT.md](./LICENSE-MIT.md) and [LICENSE-MPL.md](./LICENSE-MPL.md) for details.

We are not aware of any patent or patent application covering the techniques implemented.

## Security policy

Please see [SECURITY.md](./SECURITY.md).





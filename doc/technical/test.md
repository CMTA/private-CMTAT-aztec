# The failing end-to-end test

One test of the end-to-end suite fails, and it has nothing to do with the token. This note records which one, why, what was measured, and what it would take to fix.

> **State (2026-09-23).** `yarn test:js` against a local network: **16 passed, 1 failed, 142 s**. The whole `Token` suite passes. The failure is `Accounts › Creates accounts with fee juice`, which exercises the protocol's own Fee Juice bridge rather than anything in this repository. `yarn test:nr` is unaffected: **239/239**.

## Table of contents

- [The symptom](#the-symptom)
- [What the test does](#what-the-test-does)
- [The cause, measured](#the-cause-measured)
- [Why the number is not a constant](#why-the-number-is-not-a-constant)
- [How to fix it](#how-to-fix-it)
- [What the failure does not mean](#what-the-failure-does-not-mean)
- [Reproducing](#reproducing)

## The symptom

```
● Accounts › Creates accounts with fee juice

  Simulation error: No L1 to L2 message found for message hash 0x00c56cf9…

    at FeeJuice.claim_and_end_setup
    at SchnorrAccount.entrypoint
    at MultiCallEntrypoint.entrypoint
```

The error is raised client-side, in `@aztec/stdlib`:

```ts
const l1ToL2Response = await node.getL1ToL2MessageMembershipWitness(referenceBlock, messageHash);
if (!l1ToL2Response) {
    throw new Error(`No L1 to L2 message found for message hash ${messageHash.toString()}`);
}
```

The message the test is trying to consume is not yet in the L1-to-L2 message tree of the block it is asking about, so no membership witness exists and the claim cannot be proved.

## What the test does

`src/test/e2e/accounts.test.ts` funds fresh accounts by bridging Fee Juice from L1 and letting each new account pay for its own deployment with the claim:

1. assert the new addresses hold no Fee Juice;
2. `l1PortalManager.bridgeTokensPublic(address, amount, true)` for each — an L1 deposit that sends a message to the `FeeJuice` contract on L2;
3. send two transactions "to progress 2 blocks, and have fee juice on Aztec ready to claim";
4. deploy each account with `FeeJuicePaymentMethodWithClaim`, which consumes the message in the transaction's setup phase.

Step 3 is the one that matters. An L1-to-L2 message is not available on L2 as soon as the deposit lands: the proposer batches messages from the `Inbox` and includes them in a later L2 block, and only from that block does a membership witness exist.

## The cause, measured

The test produces **two** blocks. The message needs **three**. Measured against the running network by bridging, then adding one block at a time and asking for the witness after each:

| Blocks produced after the deposit | Tip | Membership witness |
|---:|---:|---|
| 0 | 87 | absent |
| 1 | 88 | absent |
| 2 | 89 | **absent** — where the test claims |
| 3 | 90 | found |

So the test is one block short, deterministically. It is not a flake: run in isolation, with nothing else touching the network, it fails every time.

Two details make this easy to miss:

- **The Aztec documentation says "about two L2 blocks after the deposit".** The test took that as exact. The word doing the work is *about*.
- **A local network produces no blocks while idle.** Waiting does not help, because nothing advances until a transaction arrives. The two deploys in step 3 exist precisely to force blocks, and the count they force is the whole margin the test has.

## Why the number is not a constant

Three is what this network needed today; it is not a protocol guarantee. The delay is however long the proposer takes to pick the `Inbox` batch up and include it, which depends on when in the slot the deposit landed, on the archiver's L1 sync, and on how the network is configured. Hard-coding three would replace an off-by-one with a flakier off-by-one.

## How to fix it

**Poll for availability rather than counting blocks.** After bridging, produce a block and ask the node for the witness; repeat until it is found or a bound is reached. That is what the measurement above does, and it is correct whatever the batching latency turns out to be:

```ts
for (let i = 0; i < MAX_BLOCKS; i++) {
    if (await node.getL1ToL2MessageMembershipWitness('latest', messageHash)) break;
    await forceOneBlock();   // any transaction; a throwaway account deployment does
}
```

The weaker alternative is to raise the loop from two blocks to four or five. It would pass today and says nothing about why.

This has not been applied: the fix belongs with a decision about whether the suite should test the protocol's bridge at all, given that nothing in this token depends on it.

## What the failure does not mean

- **Nothing about the token.** The failing path is the protocol's `FeeJuice` contract and the L1 portal. The `Token` suite — mint, transfer, burn, roles, pause, the issuer's view — passes in full.
- **Nothing about the fee-paying route this repository relies on.** Every other test, and every script, pays through the sponsored FPC, which needs no bridging. See [Gas sponsorship](../README.md#gas-sponsorship).
- **Nothing that a release blocks on**, unless bridged Fee Juice is part of the deployment plan. It is an accurate report of a test that was written against a documented approximation.

## Reproducing

```bash
cp .env.example .env                 # supplies L1_MNEMONIC; the example carries the anvil default
aztec start --local-network          # in another terminal; not `--sandbox`, which was removed at 3.0
yarn compile && yarn codegen
SKIP_SANDBOX=true yarn test:js       # the suite, against the already-running network

# just this test
SKIP_SANDBOX=true NODE_NO_WARNINGS=1 node --experimental-vm-modules $(yarn bin jest) \
    --runInBand --config jest.integration.config.json -t "Creates accounts with fee juice"
```

`SKIP_SANDBOX=true` stops the suite spawning its own network. The rest of the suite clears the contract's `DelayedPublicMutable` delay by warping the chain rather than waiting for it (`src/utils/time_travel.ts`), which is why a full run takes minutes rather than the hour the delay would otherwise cost.

# CMTAT Equivalency Assessment — suggested improvement: the freeze window

## Purpose

This document suggests an addition to the **CMTAT Equivalency Assessment Criteria** (`CMTAT-equivalency-assessment`, template `v0.3.0`): a warning note under the Freeze section, recording that on many blockchains a targeted address can move its tokens between the moment a freeze is submitted and the moment it becomes effective.

It comes from filling that template for the Aztec implementation in this repository (see [`README.md`](./README.md)), and is a suggestion produced here, not a CMTA publication.

## The gap

Criteria 19 and 20 require freeze and unfreeze, and criterion 21 requires the frozen status to be readable. Nothing in the template addresses **when** a freeze takes effect, and the criteria are worded as though it were instantaneous.

Between the moment the issuer decides to freeze an address and the moment the ledger enforces it, there is always a window in which the target can still transfer. It exists on every chain the criteria are likely to be applied to, but its size and its character differ enough that an assessment which does not mention it will record two very different exposures as the same answer.

**On a public EVM chain.** The freeze transaction sits in the public mempool before inclusion. Anyone can read it there, including the address being frozen. A target monitoring the mempool can broadcast a competing transfer with a higher priority fee and be included first. The window is roughly one block, and it is a *race*: the issuer can usually win it by paying more, and can remove it entirely by submitting through a private relay so that the transaction is never publicly visible before inclusion.

**On a chain where compliance state is read privately.** Aztec is the case this repository documents. A private function cannot read current mutable public state, so a freeze flag has to be a value with a scheduled change and a minimum delay, and that delay is what lets a client-side proof rely on the value. The scheduled change is visible in public state as soon as it is submitted, and it becomes effective only when the delay elapses. The window is therefore *deterministic and guaranteed*: it cannot be shortened by paying more, and no private submission path removes it, because the delay is protocol-enforced rather than a consequence of transaction visibility.

**On a permissioned ledger** the window may be negligible or absent, depending on whether the target can observe pending state.

An assessment can currently answer criterion 19 with `y` in all three cases and record none of this. Two implementations with materially different enforcement guarantees then read identically to whoever relies on the assessment.

## Suggestion

Add a warning note to the **Freeze** subsection of *Guideline for New Blockchain Implementations*, and a sentence to the Notes column of criteria 19 and 20 pointing at it.

Proposed wording for the guideline subsection:

> **Warning — the freeze window.** A freeze is never instantaneous. Between the moment it is submitted and the moment the ledger enforces it, a targeted address that is monitoring the chain may be able to transfer its tokens. On a public blockchain the freeze transaction is visible in the mempool before inclusion, and the target can front-run it with a higher priority fee; the window is about one block and can be closed by submitting the transaction through a private relay (for example Flashbots Protect on Ethereum) so that it is never publicly visible before inclusion. On a blockchain where compliance state is read from private execution, the flag may instead carry a protocol-enforced delay, in which case the window is deterministic, publicly visible and cannot be closed by paying more or by routing the transaction differently.
>
> An implementation SHOULD state which of these applies, how long the window is, and what compensating measure is available — for example pausing the token for the duration of the delay, which blocks every holder rather than racing one address.

Proposed addition to the Notes column of criteria 19 and 20:

> The delay between submitting a freeze and its enforcement MUST be documented; see *Freeze* in the guideline section.

## Why a note rather than a new criterion

A freeze window is a property of the underlying ledger rather than of the token contract, so an implementation cannot be marked non-compliant for having one — CMTAT Solidity has one too. Making it a numbered criterion would also renumber every criterion after it and invalidate assessments already filled against the current template. A warning note in the guideline section, which sits outside the equivalency count, records the difference where an assessor will read it without changing any answer.

## How this repository answers it

The Aztec implementation answers criteria 19 and 20 `y`. The feature the criteria describe — a role-restricted flag that blocks transfers in both directions and is publicly readable — is fully present, and the template's definition of `y` allows the chain-level mechanism to differ. The delay is recorded in the Implementation details column and explained under *Enforcement*, together with the pause-based mitigation. This suggestion exists so that a future assessor is prompted to record the same thing rather than having to notice it.

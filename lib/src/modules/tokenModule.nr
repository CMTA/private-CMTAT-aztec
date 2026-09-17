//! The value-moving chains of the CMTAT token - mint, transfer, burn, their public halves and the
//! private/public bridges - written once for the three deployment variants.
//!
//! Noir keeps `#[external]` declarations, `enqueue_self` calls and `self.emit` in the contract
//! module, so each variant's `main.nr` still declares the entry points; every check and every note
//! movement behind them lives here (see `doc/design/token-module.md`). The functions take the state
//! variables as arguments and never own them, so the storage layout of each contract is untouched.
//!
//! Invariants, in one place:
//! - **Screening** runs in private before any note moves: freeze on every party, and the list check
//!   where the variant has a `ValidationModule` (the [`Screening`] trait; `CMTATAztecLight` has none).
//! - **Every note written for a holder is also delivered to the issuer**, offchain (a PXE cannot
//!   discover a note it does not own, so an onchain copy would compile and break discovery).
//! - **Lifecycle differs by operation**, as in CMTAT Solidity: a transfer needs not-paused, a mint or a
//!   burn needs not-deactivated. Roles are checked in public, where the role table lives.
//! - **The public halves take the minimum**: `require_transfer` takes nothing but the pause module;
//!   the caller of a mint or burn is published because its role must be checked in public.
use aztec::context::{PrivateContext, PublicContext};
use aztec::messages::delivery::MessageDelivery;
use aztec::protocol::address::AztecAddress;
use aztec::protocol::hash::poseidon2_hash_with_separator;
use aztec::protocol::traits::ToField;
use aztec::state_vars::{Owned, PublicMutable, StateVariable};
use balance_set::BalanceSet;
use std::ops::{Add, Sub};

use crate::modules::access_controlModule::{AccessControlModule, BURNER_ROLE, MINTER_ROLE};
use crate::modules::enforcementModule::{Freezable, FreezableFlag};
use crate::modules::hybridModule::{complete_commitment, initialize_commitment, PublicBalances};
use crate::modules::pauseModule::PauseModule;
use crate::modules::validationModule::{UserFlags, ValidationModule};

pub type PrivateBalances = Owned<BalanceSet<&mut PrivateContext>, &mut PrivateContext>;

global TEXT_FROZEN_SENDER: str<14> = "Frozen: Sender";
global TEXT_FROZEN_RECIPIENT: str<17> = "Frozen: Recipient";
global TEXT_PAUSED: str<31> = "Error: token contract is paused";
global TEXT_DEACTIVATED: str<36> = "Error: token contract is deactivated";

// ---- screening -----------------------------------------------------------------------------------

/// What a variant checks about the parties of an operation, before any note moves. Every variant
/// checks the freeze flag; the list check exists only where the variant carries a `ValidationModule`.
pub trait Screening {
    /// Both parties of a transfer: CMTAT Solidity `_canTransferStandardByModule` minus the spender.
    fn transfer(self, from: AztecAddress, to: AztecAddress);
    /// The recipient of a mint: `_canMintByModuleAndRevert(to)`.
    fn mint(self, to: AztecAddress);
    /// The account of a burn: `_canBurnByModuleAndRevert(from)`. Reported as the sender.
    fn burn(self, account: AztecAddress);
    /// One address as a sender only (a commitment payer).
    fn sender(self, from: AztecAddress);
    /// One address as a recipient only (a commitment owner, screened when the commitment opens).
    fn recipient(self, to: AztecAddress);
}

/// Freeze flags plus blacklist / whitelist: `CMTATAztec` and `CMTATAztecDebt`.
pub struct FreezeAndLists {
    pub enforcement: Freezable<FreezableFlag, &mut PrivateContext>,
    pub validation: ValidationModule<UserFlags, &mut PrivateContext>,
}

/// Freeze flags only: `CMTATAztecLight`.
pub struct FreezeOnly {
    pub enforcement: Freezable<FreezableFlag, &mut PrivateContext>,
}


impl Screening for FreezeAndLists {
    fn transfer(self, from: AztecAddress, to: AztecAddress) {
        assert(!self.enforcement.is_frozen(from), TEXT_FROZEN_SENDER);
        assert(!self.enforcement.is_frozen(to), TEXT_FROZEN_RECIPIENT);
        self.validation.operateOnTransfer(from, to);
    }
    fn mint(self, to: AztecAddress) {
        assert(!self.enforcement.is_frozen(to), TEXT_FROZEN_RECIPIENT);
        self.validation.operateOnMint(to);
    }
    fn burn(self, account: AztecAddress) {
        assert(!self.enforcement.is_frozen(account), TEXT_FROZEN_SENDER);
        self.validation.operateOnBurn(account);
    }
    fn sender(self, from: AztecAddress) {
        assert(!self.enforcement.is_frozen(from), TEXT_FROZEN_SENDER);
        self.validation.operateOnFrom(from);
    }
    fn recipient(self, to: AztecAddress) {
        assert(!self.enforcement.is_frozen(to), TEXT_FROZEN_RECIPIENT);
        self.validation.operateOnTo(to);
    }
}

impl Screening for FreezeOnly {
    fn transfer(self, from: AztecAddress, to: AztecAddress) {
        assert(!self.enforcement.is_frozen(from), TEXT_FROZEN_SENDER);
        assert(!self.enforcement.is_frozen(to), TEXT_FROZEN_RECIPIENT);
    }
    fn mint(self, to: AztecAddress) {
        assert(!self.enforcement.is_frozen(to), TEXT_FROZEN_RECIPIENT);
    }
    fn burn(self, account: AztecAddress) {
        assert(!self.enforcement.is_frozen(account), TEXT_FROZEN_SENDER);
    }
    fn sender(self, from: AztecAddress) {
        assert(!self.enforcement.is_frozen(from), TEXT_FROZEN_SENDER);
    }
    fn recipient(self, to: AztecAddress) {
        assert(!self.enforcement.is_frozen(to), TEXT_FROZEN_RECIPIENT);
    }
}

// ---- note movement -------------------------------------------------------------------------------

/// Spends `amount` of `from`'s notes. The change note goes to `from` constrained and, as every note,
/// to the issuer offchain.
pub fn debit_private(balances: PrivateBalances, from: AztecAddress, amount: u128, issuer: AztecAddress) {
    let change_message = balances.at(from).sub(amount);
    change_message.deliver(MessageDelivery::onchain_constrained());
    change_message.deliver_to(issuer, MessageDelivery::offchain());
}

/// Creates a note of `amount` for `to`, delivered to `to` constrained and to the issuer offchain.
pub fn credit_private(balances: PrivateBalances, to: AztecAddress, amount: u128, issuer: AztecAddress) {
    let note_message = balances.at(to).add(amount);
    note_message.deliver(MessageDelivery::onchain_constrained());
    note_message.deliver_to(issuer, MessageDelivery::offchain());
}

// ---- the three operations, private half ----------------------------------------------------------

pub fn mint_private<S>(balances: PrivateBalances, screening: S, to: AztecAddress, amount: u128, issuer: AztecAddress)
where
    S: Screening,
{
    screening.mint(to);
    credit_private(balances, to, amount, issuer);
}

pub fn transfer_private<S>(
    balances: PrivateBalances,
    screening: S,
    from: AztecAddress,
    to: AztecAddress,
    amount: u128,
    issuer: AztecAddress,
)
where
    S: Screening,
{
    screening.transfer(from, to);
    debit_private(balances, from, amount, issuer);
    credit_private(balances, to, amount, issuer);
}

pub fn burn_private<S>(balances: PrivateBalances, screening: S, account: AztecAddress, amount: u128, issuer: AztecAddress)
where
    S: Screening,
{
    screening.burn(account);
    debit_private(balances, account, amount, issuer);
}

// ---- the bridges, private half -------------------------------------------------------------------

/// `transfer_private_to_public`: both parties screened, `from`'s notes spent. The public credit is
/// the contract's enqueued half.
pub fn bridge_private_to_public<S>(
    balances: PrivateBalances,
    screening: S,
    from: AztecAddress,
    to: AztecAddress,
    amount: u128,
    issuer: AztecAddress,
)
where
    S: Screening,
{
    screening.transfer(from, to);
    debit_private(balances, from, amount, issuer);
}

/// `transfer_public_to_private`: both parties screened, `to` receives a note. The public debit is
/// the contract's enqueued half.
pub fn bridge_public_to_private<S>(
    balances: PrivateBalances,
    screening: S,
    from: AztecAddress,
    to: AztecAddress,
    amount: u128,
    issuer: AztecAddress,
)
where
    S: Screening,
{
    screening.transfer(from, to);
    credit_private(balances, to, amount, issuer);
}

/// Opens a partial note for `to` that only `completer` may fill. The recipient is screened HERE,
/// because at completion the contract holds only the commitment. Returns the commitment; the
/// contract emits its `CommitmentInitialized` event to the issuer with it.
pub fn open_commitment<S>(context: &mut PrivateContext, screening: S, to: AztecAddress, completer: AztecAddress) -> Field
where
    S: Screening,
{
    screening.recipient(to);
    initialize_commitment(context, to, completer).to_field()
}

/// Domain separator of the nullifier that marks a commitment as paid. It only has to differ from
/// every separator the protocol derives from a commitment (the partial-note validity commitment and
/// the completion log tag); checked against every `DOM_SEP__*` constant of protocol-circuits 5.2.0.
pub global DOM_SEP__CMTAT_COMMITMENT_PAID: u32 = 0x434d5441; // "CMTA" in ASCII

/// The nullifier that records a commitment as paid: `H(commitment, DOM_SEP__CMTAT_COMMITMENT_PAID)`.
/// Without the commitment it is unlinkable to the completion log tag, which is a different hash of
/// the same value.
pub fn commitment_paid_nullifier(commitment: Field) -> Field {
    poseidon2_hash_with_separator([commitment], DOM_SEP__CMTAT_COMMITMENT_PAID)
}

/// `transfer_private_to_commitment`: the sender is screened, its notes spent, the commitment
/// completed with `amount` by `completer` (the caller), and the commitment marked as paid.
///
/// The last step is this project's addition to the AIP-20 flow (K-6). `PartialUintNote::complete`
/// is not single-use: a second payment into the same commitment debits the sender again while the
/// recipient's PXE, having matched the first completion, never discovers the second (aztec-nr
/// documents it; aztec-packages #14364 leaves the single-completion guarantee to contract logic).
/// Pushing `commitment_paid_nullifier` makes a second payment an invalid transaction - a duplicate
/// nullifier - so the payer's funds never move. Cost: one nullifier per completion.
pub fn pay_commitment<S>(
    context: &mut PrivateContext,
    balances: PrivateBalances,
    screening: S,
    from: AztecAddress,
    commitment: Field,
    completer: AztecAddress,
    amount: u128,
    issuer: AztecAddress,
)
where
    S: Screening,
{
    screening.sender(from);
    debit_private(balances, from, amount, issuer);
    complete_commitment(context, commitment, completer, balances.get_storage_slot(), amount);
    // Safety: the value is a hash of a public argument under a fixed separator; there is nothing to
    // constrain beyond what the hash already binds, and a duplicate is rejected by the protocol.
    context.push_nullifier_unsafe(commitment_paid_nullifier(commitment));
}

// ---- public halves -------------------------------------------------------------------------------

/// `_mint`: MINTER_ROLE on the caller, not deactivated (a pause does not stop issuance), supply up.
pub fn mint_public(
    access_control: AccessControlModule<bool, PublicContext>,
    pause: PauseModule<PublicContext>,
    total_supply: PublicMutable<u128, PublicContext>,
    caller: AztecAddress,
    amount: u128,
) {
    access_control.only_role(MINTER_ROLE, caller);
    assert(!pause.is_deactivated(), TEXT_DEACTIVATED);
    total_supply.write(total_supply.read().add(amount));
}

/// `_burn`: BURNER_ROLE on the caller, not deactivated (a pause does not stop redemption), supply down.
pub fn burn_public(
    access_control: AccessControlModule<bool, PublicContext>,
    pause: PauseModule<PublicContext>,
    total_supply: PublicMutable<u128, PublicContext>,
    caller: AztecAddress,
    amount: u128,
) {
    access_control.only_role(BURNER_ROLE, caller);
    assert(!pause.is_deactivated(), TEXT_DEACTIVATED);
    total_supply.write(total_supply.read().sub(amount));
}

/// `_transfer`: the pause flag, and nothing else - the enqueued call that carries this check must
/// take no arguments, because every public argument is published.
pub fn require_transfer(pause: PauseModule<PublicContext>) {
    assert(!pause.is_paused(), TEXT_PAUSED);
}

/// `_credit_public`: a transfer's lifecycle rule, then the public credit.
pub fn credit_public(pause: PauseModule<PublicContext>, public_balances: PublicBalances<PublicContext>, to: AztecAddress, amount: u128) {
    require_transfer(pause);
    public_balances.increase(to, amount);
}

/// `_debit_public`: a transfer's lifecycle rule, then the public debit (refusing an overdraft).
pub fn debit_public(pause: PauseModule<PublicContext>, public_balances: PublicBalances<PublicContext>, from: AztecAddress, amount: u128) {
    require_transfer(pause);
    public_balances.decrease(from, amount);
}

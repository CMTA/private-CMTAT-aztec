mod test;
mod modules;

use aztec::macros::aztec;

#[aztec]
pub contract CMTAToken {
    // Libs
    use compressed_string::FieldCompressedString;
    use std::ops::{Add, Sub};

    use aztec::{
        authwit::auth::compute_authwit_nullifier,
        macros::{
            events::event,
            functions::{authorize_once, external, initializer, internal, only_self, view},
            storage::storage,
        },
        messages::delivery::MessageDelivery,
        protocol::address::AztecAddress,
        protocol::traits::ToField,
        state_vars::{DelayedPublicMutable, Owned, PublicImmutable, PublicMutable},
    };

    use balance_set::BalanceSet;

    use crate::modules::{
        access_controlModule::{
            AccessControlModule, BURNER_ROLE, DEFAULT_ADMIN_ROLE, MINTER_ROLE, VALIDATION_ROLE,
        },
        enforcementModule::{Freezable, FreezableFlag},
        extensions::{
            creditEventsModule::{CreditEvents, CreditEventsStruct},
            debtBaseModule::{DebtBase, DebtBaseStruct},
        },
        pauseModule::PauseModule,
        validationModule::{SetFlag, UserFlags, ValidationModule},
    };

    // Changing the issuer address takes effect only after this delay. Expressed in seconds: since
    // Aztec v3 a DelayedPublicMutable's delay is a duration, not a number of blocks.
    pub global CHANGE_ROLES_DELAY_SECONDS: u64 = 360;

    // This global is used when doing batching. The protocol allows MAX_PRIVATE_LOGS_PER_CALL (16)
    // private logs and MAX_PRIVATE_CALL_STACK_LENGTH_PER_CALL (8) nested private calls per call. A
    // transfer delivers 5 messages per address (change note and its issuer copy, recipient note and
    // its issuer copy, and the Transfer event), so the value could now be raised above 1 - it is kept
    // at 1 here so that this migration does not change the contract's ABI beyond what the framework
    // forced.
    global MAX_ADDR_PER_CALL: u32 = 1;

    // How every note created by this contract is additionally delivered to the issuer (see the
    // `deliver_to(issuer, ...)` calls below), which is what makes holder balances auditable.
    //
    // This is offchain rather than onchain because PXE cannot process an onchain note message addressed
    // to someone who is not the note's owner: note discovery computes the note's nullifier, and that
    // needs the owner's nullifier key, which the issuer does not have. Switching this to
    // `MessageDelivery::onchain_constrained()` is what the framework documents for an auditor, and it
    // compiles, but every note the issuer receives for another holder then fails discovery.
    //
    // The consequence of offchain delivery is that the issuer's copy has no onchain data availability:
    // the issuer must capture these messages as they are produced, and a sender who drops them is not
    // detectable onchain.

    #[event]
    struct Transfer {
        from: AztecAddress,
        to: AztecAddress,
        amount: u128,
    }

    #[event]
    struct NewRole {
        role: Field,
        account: AztecAddress,
    }

    #[storage]
    struct Storage<Context> {
        pause_module: PauseModule<Context>,
        validation_module: ValidationModule<UserFlags, Context>,
        enforcement_module: Freezable<FreezableFlag, Context>,
        access_control: AccessControlModule<bool, Context>,
        credit_event_module: CreditEvents<bool, Context>,
        debt_base_module: DebtBase<bool, Context>,

        issuer_address: DelayedPublicMutable<AztecAddress, CHANGE_ROLES_DELAY_SECONDS, Context>,

        private_balances: Owned<BalanceSet<Context>, Context>,

        total_supply: PublicMutable<u128, Context>,
        symbol: PublicImmutable<FieldCompressedString, Context>,
        name: PublicImmutable<FieldCompressedString, Context>,
        decimals: PublicImmutable<u8, Context>,
    }

    #[external("public")]
    #[initializer]
    fn constructor(admin: AztecAddress, name: str<31>, symbol: str<31>, decimals: u8) {
        assert(!admin.is_zero(), "invalid admin");
        self.storage.name.initialize(FieldCompressedString::from_string(name));
        self.storage.symbol.initialize(FieldCompressedString::from_string(symbol));
        self.storage.decimals.initialize(decimals);
        self.storage.access_control._grant_role(DEFAULT_ADMIN_ROLE, admin);
        self.storage.access_control._grant_role(VALIDATION_ROLE, admin);

        self.storage.issuer_address.schedule_value_change(admin);
    }

    /** ==========================================================
     * ===================== AUTHORIZATION MODULE ================
     * ======================================================== */

    #[external("public")]
    #[view]
    fn has_role(role: Field, account: AztecAddress) -> pub Field {
        self.storage.access_control.has_role(role, account).to_field()
    }

    #[external("public")]
    fn only_role(role: Field, caller: AztecAddress) {
        self.storage.access_control.only_role(role, caller);
    }

    #[external("public")]
    fn grant_role(role: Field, account: AztecAddress) {
        self.storage.access_control.grant_role(role, account, self.msg_sender());
        self.emit(NewRole { role, account });
    }

    /**
     * @roles: onlyAdmin
     * @notice: revoking a pause contract role when the contract is paused can cause the contract to be stuck in a paused state.
     */
    #[external("public")]
    fn revoke_role(role: Field, account: AztecAddress) {
        self.storage.access_control.revoke_role(role, account, self.msg_sender());
    }

    #[external("public")]
    fn renounce_role(role: Field, callerConfirmation: AztecAddress) {
        self.storage.access_control.renounce_role(role, self.msg_sender(), callerConfirmation);
    }

    /** ==========================================================
     * ===================== VALIDATION MODULE ===================
     * ======================================================== */

    #[external("public")]
    #[view]
    fn get_operations() -> pub Field {
        self.storage.validation_module.get_operations()
    }

    #[external("public")]
    fn set_operations(operations: SetFlag) {
        self.storage.validation_module.set_operations(
            self.msg_sender(),
            operations,
            self.storage.access_control,
        );
    }

    #[external("public")]
    fn add_to_list(newListAddress: AztecAddress, userFlag: UserFlags) {
        self.storage.validation_module.add_to_list(
            self.msg_sender(),
            newListAddress,
            userFlag,
            self.storage.access_control,
        );
    }

    #[external("public")]
    fn remove_from_list(removeListAddress: AztecAddress, userFlag: UserFlags) {
        self.storage.validation_module.remove_from_list(
            self.msg_sender(),
            removeListAddress,
            userFlag,
            self.storage.access_control,
        );
    }

    /** ==========================================================
     * ===================== PAUSE MODULE ========================
     * ======================================================== */

    #[external("public")]
    #[view]
    fn public_get_pause() -> pub Field {
        self.storage.pause_module.is_paused().to_field()
    }

    /**
     * @roles: onlyAdmin
     * @notice: The contract must not be paused.
     */
    #[external("public")]
    fn pause_contract() {
        let admin = self.msg_sender();
        self.storage.pause_module.pause(admin, self.storage.access_control);
    }

    #[external("public")]
    fn unpause_contract() {
        let admin = self.msg_sender();
        self.storage.pause_module.unpause(admin, self.storage.access_control);
    }

    /** ==========================================================
     * ===================== ENFORCEMENT MODULE ==================
     * ======================================================== */

    #[external("public")]
    #[view]
    fn get_frozen(user: AztecAddress) -> pub Field {
        self.storage.enforcement_module.is_frozen(user).to_field()
    }

    #[external("public")]
    fn freeze(user: AztecAddress, value: FreezableFlag) {
        self.storage.enforcement_module.freeze(
            self.msg_sender(),
            user,
            value,
            self.storage.access_control,
        );
    }

    #[external("public")]
    fn unfreeze(user: AztecAddress, value: FreezableFlag) {
        self.storage.enforcement_module.unfreeze(
            self.msg_sender(),
            user,
            value,
            self.storage.access_control,
        );
    }

    /** ==========================================================
     * ===================== CREDIT EVENTS MODULE ================
     * ======================================================== */

    #[external("public")]
    fn set_credit_events(credit_events: CreditEventsStruct) {
        self.storage.credit_event_module.setCreditEvents(
            credit_events,
            self.msg_sender(),
            self.storage.access_control,
        );
    }

    #[external("public")]
    fn get_credit_events() -> [Field; 3] {
        self.storage.credit_event_module.get_credit_events()
    }

    /** ==========================================================
     * ===================== DEBT BASE MODULE ====================
     * ======================================================== */

    #[external("public")]
    fn set_debt_base(debt_base_: DebtBaseStruct) {
        self.storage.debt_base_module.setDebt(
            debt_base_,
            self.msg_sender(),
            self.storage.access_control,
        );
    }

    #[external("public")]
    fn get_debt_base() -> [Field; 12] {
        self.storage.debt_base_module.get_debt_base()
    }

    /** ==========================================================
     * ===================== VIEW FUNCTIONS ======================
     * ======================================================== */

    #[external("public")]
    #[view]
    fn public_get_name() -> pub FieldCompressedString {
        self.storage.name.read()
    }

    #[external("private")]
    #[view]
    fn private_get_name() -> pub FieldCompressedString {
        self.storage.name.read()
    }

    #[external("public")]
    #[view]
    fn public_get_symbol() -> pub FieldCompressedString {
        self.storage.symbol.read()
    }

    #[external("private")]
    #[view]
    fn private_get_symbol() -> pub FieldCompressedString {
        self.storage.symbol.read()
    }

    #[external("public")]
    #[view]
    fn public_get_decimals() -> pub u8 {
        self.storage.decimals.read()
    }

    #[external("private")]
    #[view]
    fn private_get_decimals() -> pub u8 {
        self.storage.decimals.read()
    }

    #[external("public")]
    #[view]
    fn total_supply() -> u128 {
        self.storage.total_supply.read()
    }

    //TODO: we should be able to change the address of the issuer and put some ACL on it
    #[external("public")]
    #[view]
    fn public_get_issuer() -> pub AztecAddress {
        self.storage.issuer_address.get_current_value()
    }

    #[external("private")]
    #[view]
    fn private_get_issuer() -> pub AztecAddress {
        self.storage.issuer_address.get_current_value()
    }

    /** ==========================================================
     * ===================== MINT ================================
     * ======================================================== */

    /*
    @dev: We do not use authwits for minting, as the issuer is the only one allowed to mint.
    @info: the minting function is called by the issuer, who is the only one allowed to mint.
    */
    #[internal("private")]
    fn _mint_internal(to: AztecAddress, amount: u128) {
        assert(!self.storage.enforcement_module.is_frozen(to), "Frozen: Recipient");

        let issuer = self.storage.issuer_address.get_current_value();

        // The recipient's new note is delivered to the recipient, and a second copy of the same message
        // is delivered to the issuer so that it can audit the holder's balance. See the note
        // near MAX_ADDR_PER_CALL for why the issuer's copy is delivered offchain.
        let note_message = self.storage.private_balances.at(to).add(amount);
        note_message.deliver(MessageDelivery::onchain_constrained());
        note_message.deliver_to(issuer, MessageDelivery::offchain());
    }

    /**
    * @dev: Mints tokens to the specified address. Enqueues a public call to increase the total supply and to check for pause.
    *
    * @TODO: should we restrict the "to" address to not be the issuer, in order to prevent a "malicious" issuer from not
    * revealing the "real" supply of the token, ex: by minting 100% of tokens to himself, he can hide the supply held by users
    *
    * Requirements:
    * - The contract must not be paused.
    * - The recipient must not be frozen.
    * - The recipient must respect the allowlist constraints of the validation module.
    * - The caller must have the minter role.
    */
    #[external("private")]
    fn mint(to: AztecAddress, amount: u128) {
        self.internal._mint_internal(to, amount);
        self.enqueue_self._mint(self.msg_sender(), amount);
    }

    //everyone can call this function, but will revert in _mint if not minter role
    #[external("private")]
    fn mint_batch(accounts: [AztecAddress; MAX_ADDR_PER_CALL], amount: [u128; MAX_ADDR_PER_CALL]) {
        assert(accounts.len() != 0, "Mint module empty");
        assert(accounts.len() == amount.len(), "Accounts and values arrays mismatch");
        let mut acc: u128 = 0;

        for i in 0..MAX_ADDR_PER_CALL {
            self.internal._mint_internal(accounts[i], amount[i]);
            acc += amount[i];
        }

        self.enqueue_self._mint(self.msg_sender(), acc);
    }

    /** ==========================================================
     * ===================== TRANSFER ============================
     * ======================================================== */

    /**
    * @dev Spends notes, emits a new note (UintNote) with any remaining change, and sends a note to the recipient. Sends
    the 'change' encrypted note to the issuer.
    *
    * - If caller (self.msg_sender()) != from: the #[authorize_once] macro validates an authwit. In order to
    * not allow double spending of the authwit, the nonce is used to ensure that the authwit
    * can only be used once. Effectively, repeating the same nonce emits the same nullifier, which is not allowed at
    * protocol level.
    * - If caller == from: it's a usual transfer and `authwit_nonce` must be 0.
    *
    * Requirements:
    * - The contract must not be paused.
    * - The sender/recipient must not be frozen.
    * - The sender/recipient must respect the allowlist constraints of the validation module.
    * - The amount must be greater than 0.
    * - The sender must have enough balance to cover the transfer.
    * - The authwit must be valid if the caller is not the sender.
    */
    #[authorize_once("from", "authwit_nonce")]
    #[external("private")]
    fn transfer(from: AztecAddress, to: AztecAddress, amount: u128, authwit_nonce: Field) {
        self.internal._transfer_internal(from, to, amount);
        self.enqueue_self._transfer();
        self.emit(Transfer { from, to, amount }).deliver_to(
            to,
            MessageDelivery::onchain_unconstrained(),
        );
    }

    /*
    * Batched transfers from a single sender. See MAX_ADDR_PER_CALL for why the batch is limited to one
    * recipient today.
    */
    #[authorize_once("from", "authwit_nonce")]
    #[external("private")]
    fn transfer_batch(
        from: AztecAddress,
        accounts: [AztecAddress; MAX_ADDR_PER_CALL],
        amount: [u128; MAX_ADDR_PER_CALL],
        authwit_nonce: Field,
    ) {
        assert(accounts.len() != 0, "Mint module empty");
        assert(accounts.len() == amount.len(), "Accounts and values arrays mismatch");

        for i in 0..MAX_ADDR_PER_CALL {
            self.internal._transfer_internal(from, accounts[i], amount[i]);
        }
        self.enqueue_self._transfer();
    }

    #[internal("private")]
    fn _transfer_internal(from: AztecAddress, to: AztecAddress, amount: u128) {
        assert(!self.storage.enforcement_module.is_frozen(from), "Frozen: Sender");
        assert(!self.storage.enforcement_module.is_frozen(to), "Frozen: Recipient");
        self.storage.validation_module.operateOnTransfer(from, to);

        let issuer = self.storage.issuer_address.get_current_value();

        // Both the sender's change note and the recipient's new note are copied to the issuer.
        let change_message = self.storage.private_balances.at(from).sub(amount);
        change_message.deliver(MessageDelivery::onchain_constrained());
        change_message.deliver_to(issuer, MessageDelivery::offchain());

        let recipient_message = self.storage.private_balances.at(to).add(amount);
        recipient_message.deliver(MessageDelivery::onchain_constrained());
        recipient_message.deliver_to(issuer, MessageDelivery::offchain());
    }

    /**
     * Cancel a private authentication witness.
     * @param inner_hash The inner hash of the authwit to cancel.
     */
    #[external("private")]
    fn cancel_authwit(inner_hash: Field) {
        let on_behalf_of = self.msg_sender();
        let nullifier = compute_authwit_nullifier(on_behalf_of, inner_hash);
        self.context.push_nullifier_unsafe(nullifier);
    }

    /** ==========================================================
     * ===================== BURN ================================
     * ======================================================== */

    #[internal("private")]
    fn _burn_internal(from: AztecAddress, amount: u128) {
        assert(!self.storage.enforcement_module.is_frozen(from), "Frozen: Recipient");

        let issuer = self.storage.issuer_address.get_current_value();

        let change_message = self.storage.private_balances.at(from).sub(amount);
        change_message.deliver(MessageDelivery::onchain_constrained());
        change_message.deliver_to(issuer, MessageDelivery::offchain());
    }

    /**
    * @dev Burns tokens on behalf of the specified address. Enqueues a public call to decrease the total supply and to check for pause.
    *
    * An authwit from the 'from' address is required to burn tokens on their behalf.
    *
    * Requirements:
    * - The contract must not be paused.
    * - The sender must not be frozen.
    * - The caller must have the burner role.
    */
    #[authorize_once("from", "authwit_nonce")]
    #[external("private")]
    fn burn(from: AztecAddress, amount: u128, authwit_nonce: Field) {
        assert(!self.storage.enforcement_module.is_frozen(from), "Frozen: Sender");

        self.internal._burn_internal(from, amount);
        self.enqueue_self._burn(self.msg_sender(), amount);
    }

    /*
    * Batched burns from a single holder. The pre-v3 signature took one holder per entry and validated
    * one authwit per entry; the authwit check is now the #[authorize_once] macro, which authorizes a
    * single `from`, so the batch debits one holder.
    */
    #[authorize_once("from", "authwit_nonce")]
    #[external("private")]
    fn burn_batch(
        from: AztecAddress,
        amount: [u128; MAX_ADDR_PER_CALL],
        authwit_nonce: Field,
    ) {
        assert(amount.len() != 0, "Mint module empty");

        let mut acc: u128 = 0;

        for i in 0..MAX_ADDR_PER_CALL {
            self.internal._burn_internal(from, amount[i]);
            acc += amount[i];
        }

        self.enqueue_self._burn(self.msg_sender(), acc);
    }

    /** ==========================================================
     * ===================== INTERNAL ============================
     * ======================================================== */

    #[external("public")]
    #[only_self]
    fn _mint(caller: AztecAddress, amount: u128) {
        self.storage.access_control.only_role(MINTER_ROLE, caller);
        assert(!self.storage.pause_module.is_paused(), "Error: token contract is paused");
        let supply = self.storage.total_supply.read().add(amount);
        self.storage.total_supply.write(supply);
    }

    #[external("public")]
    #[only_self]
    fn _transfer() {
        assert(!self.storage.pause_module.is_paused(), "Error: token contract is paused");
    }

    #[external("public")]
    #[only_self]
    fn _burn(caller: AztecAddress, amount: u128) {
        self.storage.access_control.only_role(BURNER_ROLE, caller);
        assert(!self.storage.pause_module.is_paused(), "Error: token contract is paused");
        let new_supply = self.storage.total_supply.read().sub(amount);
        self.storage.total_supply.write(new_supply);
    }

    /** ==========================================================
     * ===================== UNCONSTRAINED =======================
     * ======================================================== */

    #[external("utility")]
    unconstrained fn balance_of_private(owner: AztecAddress) -> pub u128 {
        self.storage.private_balances.at(owner).balance_of()
    }
}

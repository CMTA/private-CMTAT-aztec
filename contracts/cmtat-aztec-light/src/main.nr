mod test;

use aztec::macros::aztec;

#[aztec]
pub contract CMTATAztecLight {
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

    use cmtat_aztec_lib::modules::{
        access_controlModule::{AccessControlModule, BURNER_ROLE, DEFAULT_ADMIN_ROLE, MINTER_ROLE},
        enforcementModule::{Freezable, FreezableFlag},
        extraInformationModule::{DocumentInfo, ExtraInformation},
        pauseModule::PauseModule,
    };

    // Changing the issuer address takes effect only after this delay. Expressed in seconds: since
    // Aztec v3 a DelayedPublicMutable's delay is a duration, not a number of blocks.
    pub global CHANGE_ROLES_DELAY_SECONDS: u64 = 360;

    // The version of this token implementation, following semantic versioning, exposed by `version()`.
    //
    // Deliberately a compile-time constant rather than a stored value: it therefore cannot be
    // desynchronised from the deployed code, which is the failure the CMTAT criteria warn about for
    // admin-writable version fields. It must be bumped in the same commit as any release.
    //
    // Padded to 31 characters because `FieldCompressedString::from_string` takes a `str<31>`;
    // consumers should trim the trailing spaces.
    pub global VERSION: str<31> = "0.3.0                          ";

    // How many addresses one batched call may act on.
    //
    // 4 is the measured ceiling, not a guess. `transfer` is the binding path: it creates two notes
    // and two constrained deliveries per recipient, so it saturates the per-call note-hash and log
    // budgets at roughly twice the rate of mint. Running the Noir suite at each value:
    //
    //   1, 2, 4 -> every test passes
    //   5       -> transfer passes, but batched mint and burn end with a wrong total supply
    //   6, 8    -> transfer aborts with "Assertion failed: push out of bounds"
    //
    // The private-call budget (MAX_PRIVATE_CALL_STACK_LENGTH_PER_CALL) does not enter into it: the
    // `_*_internal` helpers are `#[internal("private")]` and are inlined, so a batch makes no nested
    // private calls at all whatever this value is.
    //
    // Raising this further requires re-measuring, not re-reading the protocol constants - and note
    // that the per-recipient work is what grows, so the proof the *user's own device* must produce
    // grows with it (453k gates for a 4-recipient transfer against 119k for one).
    global MAX_ADDR_PER_CALL: u32 = 4;

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

    #[event]
    struct Deactivated {
        account: AztecAddress,
    }

    #[event]
    struct TokenId {
        tokenId: FieldCompressedString,
    }

    #[storage]
    struct Storage<Context> {
        pause_module: PauseModule<Context>,
        enforcement_module: Freezable<FreezableFlag, Context>,
        access_control: AccessControlModule<bool, Context>,
        extra_information_module: ExtraInformation<bool, Context>,

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

    #[external("public")]
    #[view]
    fn public_get_deactivated() -> pub Field {
        self.storage.pause_module.is_deactivated().to_field()
    }

    /**
     * @roles: onlyAdmin
     * @notice: Permanently deactivates the token. This cannot be undone.
     *
     * Requirements:
     * - The caller must have the admin role.
     * - The contract must already be paused.
     * - The contract must not already be deactivated.
     */
    #[external("public")]
    fn deactivate_contract() {
        let admin = self.msg_sender();
        self.storage.pause_module.deactivate(admin, self.storage.access_control);
        self.emit(Deactivated { account: admin });
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
     * ===================== EXTRA INFORMATION MODULE ============
     * ======================================================== */

    /**
     * @roles: onlyExtraInformationManager
     * @notice: Sets the reference to the legally required documentation.
     * @dev: Every field is replaced; a caller that wants to keep a value must re-supply it.
     * `lastModified` is stamped by the contract from the block timestamp.
     */
    #[external("public")]
    fn set_terms(terms_: DocumentInfo) {
        self.storage.extra_information_module.setTerms(
            terms_,
            self.context.timestamp(),
            self.msg_sender(),
            self.storage.access_control,
        );
    }

    #[external("public")]
    fn terms() -> [Field; 5] {
        self.storage.extra_information_module.get_terms()
    }


    /**
     * @roles: onlyExtraInformationManager
     * @notice: Sets the token identifier of the tokenized asset.
     * @dev: As in CMTAT Solidity, the value is written even when it equals the current one.
     */
    #[external("public")]
    fn set_token_id(tokenId_: FieldCompressedString) {
        self.storage.extra_information_module.setTokenId(
            tokenId_,
            self.msg_sender(),
            self.storage.access_control,
        );
        self.emit(TokenId { tokenId: tokenId_ });
    }

    #[external("public")]
    #[view]
    fn token_id() -> pub FieldCompressedString {
        self.storage.extra_information_module.get_token_id()
    }

    /** ==========================================================
     * ===================== VIEW FUNCTIONS ======================
     * ======================================================== */

    /**
     * @notice The version of this token implementation, e.g. "0.3.0".
     * @dev A compile-time constant, as in the CMTAT Solidity `VersionModule`: it identifies the
     * version of the code, not of the issued security and not of any assessment document. It changes
     * only through a new deployment. Aztec's contract class ID also identifies the deployed artifact,
     * but it is a hash and does not carry a semantic version, so the two are complementary.
     */
    #[external("public")]
    #[view]
    fn version() -> pub FieldCompressedString {
        FieldCompressedString::from_string(VERSION)
    }

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
    fn _mint_internal(to: AztecAddress, amount: u128, issuer: AztecAddress) {
        assert(!self.storage.enforcement_module.is_frozen(to), "Frozen: Recipient");

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
        let issuer = self.storage.issuer_address.get_current_value();
        self.internal._mint_internal(to, amount, issuer);
        self.enqueue_self._mint(self.msg_sender(), amount);
    }

    //everyone can call this function, but will revert in _mint if not minter role
    #[external("private")]
    fn mint_batch(accounts: [AztecAddress; MAX_ADDR_PER_CALL], amount: [u128; MAX_ADDR_PER_CALL]) {
        assert(accounts.len() != 0, "Mint module empty");
        assert(accounts.len() == amount.len(), "Accounts and values arrays mismatch");
        let mut acc: u128 = 0;

        // The issuer is the same for every entry, so it is read once here rather than once per
        // address inside the inlined helper.
        let issuer = self.storage.issuer_address.get_current_value();

        for i in 0..MAX_ADDR_PER_CALL {
            self.internal._mint_internal(accounts[i], amount[i], issuer);
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
        let issuer = self.storage.issuer_address.get_current_value();
        self.internal._transfer_internal(from, to, amount, issuer);
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

        // Loop-invariant: one issuer for the whole call, read once rather than per recipient.
        let issuer = self.storage.issuer_address.get_current_value();

        for i in 0..MAX_ADDR_PER_CALL {
            self.internal._transfer_internal(from, accounts[i], amount[i], issuer);
        }
        self.enqueue_self._transfer();
    }

    #[internal("private")]
    fn _transfer_internal(
        from: AztecAddress,
        to: AztecAddress,
        amount: u128,
        issuer: AztecAddress,
    ) {
        assert(!self.storage.enforcement_module.is_frozen(from), "Frozen: Sender");
        assert(!self.storage.enforcement_module.is_frozen(to), "Frozen: Recipient");

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
    fn _burn_internal(account: AztecAddress, amount: u128, issuer: AztecAddress) {
        // `account` is the address being debited, named as in the CMTAT Solidity burn module. Both
        // `burn` and `burn_batch` reach the freeze check here, so this message is the one an
        // operator sees on either path.
        assert(!self.storage.enforcement_module.is_frozen(account), "Frozen: Sender");

        let change_message = self.storage.private_balances.at(account).sub(amount);
        change_message.deliver(MessageDelivery::onchain_constrained());
        change_message.deliver_to(issuer, MessageDelivery::offchain());
    }

    /**
    * @dev Burns tokens on behalf of the specified address. Enqueues a public call to decrease the total supply and to check for pause.
    *
    * An authwit from the `account` address is required to burn tokens on their behalf.
    *
    * Requirements:
    * - The contract must not be paused.
    * - The sender must not be frozen.
    * - The caller must have the burner role.
    */
    #[authorize_once("account", "authwit_nonce")]
    #[external("private")]
    fn burn(account: AztecAddress, amount: u128, authwit_nonce: Field) {
        let issuer = self.storage.issuer_address.get_current_value();
        self.internal._burn_internal(account, amount, issuer);
        self.enqueue_self._burn(self.msg_sender(), amount);
    }

    /*
    * Batched burns from a single holder. The pre-v3 signature took one holder per entry and validated
    * one authwit per entry; the authwit check is now the #[authorize_once] macro, which authorizes a
    * single `from`, so the batch debits one holder.
    */
    #[authorize_once("account", "authwit_nonce")]
    #[external("private")]
    fn burn_batch(
        account: AztecAddress,
        amount: [u128; MAX_ADDR_PER_CALL],
        authwit_nonce: Field,
    ) {
        assert(amount.len() != 0, "Mint module empty");

        let mut acc: u128 = 0;

        // Loop-invariant: one issuer for the whole call, read once rather than per entry.
        let issuer = self.storage.issuer_address.get_current_value();

        for i in 0..MAX_ADDR_PER_CALL {
            self.internal._burn_internal(account, amount[i], issuer);
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

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
        state_vars::{DelayedPublicMutable, Owned, PublicImmutable, PublicMutable, StateVariable},
    };

    use balance_set::BalanceSet;

    use cmtat_aztec_lib::modules::{
        access_controlModule::{AccessControlModule, BURNER_ROLE, DEFAULT_ADMIN_ROLE, MINTER_ROLE},
        enforcementModule::{CHANGE_ROLES_DELAY_SECONDS as FREEZE_DELAY_SECONDS, Freezable, FreezableFlag},
        extraInformationModule::{DocumentInfo, ExtraInformation},
        hybridModule::{
            complete_commitment, initialize_commitment, PRIVATE_ADDRESS_MAGIC_VALUE, PublicBalances,
            require_public_side_enabled,
        },
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

    // `transfer_batch` has its own, lower cap. A transfer delivers four constrained messages per
    // recipient - the change note to the sender, the recipient's note, and the Transfer event to
    // both the recipient and the issuer - where a mint or burn delivers one or two. Measured under
    // that delivery: 2 recipients pass, 3 and 4 abort with "push out of bounds". A model consistent
    // with every observation is that each constrained delivery consumes two of the sixteen
    // key-validation requests a call may make (4 x 2 x 2 = 16 fitted before the issuer event was
    // constrained; 3 x 4 x 2 = 24 does not), but the number is the measurement, not the model.
    global MAX_TRANSFER_ADDR_PER_CALL: u32 = 2;

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

    // Hybrid: the issuer's record of a partial note opened for `to` (see initialize_transfer_commitment).
    #[event]
    struct CommitmentInitialized {
        to: AztecAddress,
        completer: AztecAddress,
        commitment: Field,
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

    // Mirrors the CMTAT Solidity `event Terms(CMTATTerms newTerm)`, which carries the whole stored
    // terms rather than just the caller: `_setTerms` emits `Terms($._terms)` after writing. The
    // fields are the flattened `CMTATTerms` — the document name, its URI, the 256-bit content hash
    // split into two 128-bit halves, and the `lastModified` the contract stamped.
    #[event]
    struct Terms {
        name: FieldCompressedString,
        uri: FieldCompressedString,
        documentHashHigh: u128,
        documentHashLow: u128,
        lastModified: u64,
    }


    // --- C-6: administrative operations now leave a trail ---------------------------------------
    // Names follow the reference where one exists: `Paused` / `Unpaused` and `RoleRevoked` are the
    // OpenZeppelin events CMTAT Solidity inherits (`NewRole` above corresponds to `RoleGranted`);
    // `AddressFrozen` is CMTAT's own. The freeze and list flags are DelayedPublicMutable, so those
    // events also carry `effective_at`: the timestamp from which the scheduled value is current.
    // It is computed as block timestamp + the module's delay, which is exactly what
    // DelayedPublicMutable::schedule_value_change records; it stays exact because neither module ever
    // reschedules its delay.

    #[event]
    struct Paused {
        account: AztecAddress,
    }

    #[event]
    struct Unpaused {
        account: AztecAddress,
    }

    #[event]
    struct RoleRevoked {
        role: Field,
        account: AztecAddress,
        sender: AztecAddress,
    }

    #[event]
    struct IssuerChanged {
        issuer: AztecAddress,
        operator: AztecAddress,
        effective_at: u64,
    }

    #[event]
    struct AddressFrozen {
        account: AztecAddress,
        is_frozen: bool,
        enforcer: AztecAddress,
        effective_at: u64,
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

        // Hybrid: the public balances and whether the bridges to them are open. Appended last so the
        // slots above are unchanged.
        public_balances: PublicBalances<Context>,
        public_side_enabled: PublicImmutable<bool, Context>,
    }

    #[external("public")]
    #[initializer]
    // `public_side_enabled` is the issuer's deployment-time choice: whether holders may move value
    // between their private notes and a public balance (the four AIP-20 bridges). Off reproduces the
    // fully private token; it cannot be changed after deployment.
    fn constructor(admin: AztecAddress, name: str<31>, symbol: str<31>, decimals: u8, public_side_enabled: bool) {
        assert(!admin.is_zero(), "invalid admin");
        self.storage.name.initialize(FieldCompressedString::from_string(name));
        self.storage.symbol.initialize(FieldCompressedString::from_string(symbol));
        self.storage.decimals.initialize(decimals);
        self.storage.public_side_enabled.initialize(public_side_enabled);
        self.internal._grant_role_internal(DEFAULT_ADMIN_ROLE, admin);

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
    #[view]
    fn only_role(role: Field, caller: AztecAddress) {
        self.storage.access_control.only_role(role, caller);
    }

    #[external("public")]
    fn grant_role(role: Field, account: AztecAddress) {
        self.storage.access_control.only_role_admin(role, self.msg_sender());
        self.internal._grant_role_internal(role, account);
    }

    /**
     * @roles: onlyAdmin
     * @notice: revoking a pause contract role when the contract is paused can cause the contract to be stuck in a paused state.
     */
    #[external("public")]
    fn revoke_role(role: Field, account: AztecAddress) {
        let sender = self.msg_sender();
        self.storage.access_control.revoke_role(role, account, sender);
        self.emit(RoleRevoked { role, account, sender });
    }

    #[external("public")]
    fn renounce_role(role: Field, callerConfirmation: AztecAddress) {
        let sender = self.msg_sender();
        self.storage.access_control.renounce_role(role, sender, callerConfirmation);
        self.emit(RoleRevoked { role, account: sender, sender });
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
        self.emit(Paused { account: admin });
    }

    #[external("public")]
    fn unpause_contract() {
        let admin = self.msg_sender();
        self.storage.pause_module.unpause(admin, self.storage.access_control);
        self.emit(Unpaused { account: admin });
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
        let enforcer = self.msg_sender();
        self.storage.enforcement_module.freeze(enforcer, user, value, self.storage.access_control);
        self.emit(AddressFrozen {
            account: user,
            is_frozen: value.is_freezed,
            enforcer,
            effective_at: self.context.timestamp() + FREEZE_DELAY_SECONDS,
        });
    }

    #[external("public")]
    fn unfreeze(user: AztecAddress, value: FreezableFlag) {
        let enforcer = self.msg_sender();
        self.storage.enforcement_module.unfreeze(enforcer, user, value, self.storage.access_control);
        self.emit(AddressFrozen {
            account: user,
            is_frozen: value.is_freezed,
            enforcer,
            effective_at: self.context.timestamp() + FREEZE_DELAY_SECONDS,
        });
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
        // Read the timestamp once so the event reports exactly the `lastModified` that was stored.
        let last_modified = self.context.timestamp();
        self.storage.extra_information_module.setTerms(
            terms_,
            last_modified,
            self.msg_sender(),
            self.storage.access_control,
        );
        self.emit(Terms {
            name: terms_.name,
            uri: terms_.uri,
            documentHashHigh: terms_.documentHashHigh,
            documentHashLow: terms_.documentHashLow,
            lastModified: last_modified,
        });
    }

    #[external("public")]
    #[view]
    fn terms() -> pub [Field; 5] {
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
    fn name() -> pub FieldCompressedString {
        self.storage.name.read()
    }

    #[external("private")]
    #[view]
    fn private_get_name() -> pub FieldCompressedString {
        self.storage.name.read()
    }

    #[external("public")]
    #[view]
    fn symbol() -> pub FieldCompressedString {
        self.storage.symbol.read()
    }

    #[external("private")]
    #[view]
    fn private_get_symbol() -> pub FieldCompressedString {
        self.storage.symbol.read()
    }

    #[external("public")]
    #[view]
    fn decimals() -> pub u8 {
        self.storage.decimals.read()
    }

    #[external("private")]
    #[view]
    fn private_get_decimals() -> pub u8 {
        self.storage.decimals.read()
    }

    #[external("public")]
    #[view]
    fn total_supply() -> pub u128 {
        self.storage.total_supply.read()
    }

    /**
     * @roles: onlyAdmin
     * @notice: Schedules a change of the issuer - the address that receives a copy of every note and
     * so can audit holder balances. Takes effect after CHANGE_ROLES_DELAY_SECONDS, like every other
     * DelayedPublicMutable here; until then mint, transfer and burn keep addressing the old issuer.
     * @dev: Copies already delivered to the previous issuer are not recalled - a delivered note cannot
     * be. Rotating the issuer therefore transfers *future* audit visibility only; the previous issuer
     * keeps what it has. Choose the new address with that in mind: it needs a PXE that can decrypt
     * and store the copies from the moment the change takes effect.
     *
     * Requirements:
     * - The caller must have the admin role.
     * - The new issuer must not be the zero address.
     */
    #[external("public")]
    fn set_issuer(new_issuer: AztecAddress) {
        assert(!new_issuer.is_zero(), "invalid issuer");
        let operator = self.msg_sender();
        self.storage.access_control.only_role(DEFAULT_ADMIN_ROLE, operator);
        self.storage.issuer_address.schedule_value_change(new_issuer);
        self.emit(IssuerChanged {
            issuer: new_issuer,
            operator,
            effective_at: self.context.timestamp() + CHANGE_ROLES_DELAY_SECONDS,
        });
    }

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
    * - The contract must not be deactivated. A pause does not stop a mint, as in CMTAT Solidity.
    * - The recipient must not be frozen.
    * - The caller must have the minter role.
    */
    #[external("private")]
    fn mint_to_private(to: AztecAddress, amount: u128) {
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
    fn transfer_private_to_private(from: AztecAddress, to: AztecAddress, amount: u128, authwit_nonce: Field) {
        let issuer = self.storage.issuer_address.get_current_value();
        self.internal._transfer_internal(from, to, amount, issuer);
        self.enqueue_self._transfer();
        // Delivered constrained to BOTH parties that need it, deliberately - see the event list in
        // doc/README.md for the reasoning. Constrained, because an unconstrained receipt lets the sender forge
        // `from`; to the issuer, because this is the only on-chain, data-available record it has of
        // who paid whom (its note copies are offchain by necessity, events are not). Measured at
        // ~20,200 gates per constrained delivery.
        let transfer_event = self.emit(Transfer { from, to, amount });
        transfer_event.deliver_to(to, MessageDelivery::onchain_constrained());
        transfer_event.deliver_to(issuer, MessageDelivery::onchain_constrained());
    }

    /*
    * Batched transfers from a single sender. See MAX_TRANSFER_ADDR_PER_CALL for the measured limit,
    * which is lower than the mint and burn cap because each recipient costs four constrained deliveries.
    *
    * Emits one Transfer event per recipient, in the same mode as `transfer`, so that the batched and
    * the single path leave the same trail. Anything built on the event — an issuer reconciliation, an
    * explorer, a compliance feed — would otherwise miss every batched transfer.
    */
    #[authorize_once("from", "authwit_nonce")]
    #[external("private")]
    fn transfer_batch(
        from: AztecAddress,
        accounts: [AztecAddress; MAX_TRANSFER_ADDR_PER_CALL],
        amount: [u128; MAX_TRANSFER_ADDR_PER_CALL],
        authwit_nonce: Field,
    ) {
        assert(accounts.len() != 0, "Mint module empty");
        assert(accounts.len() == amount.len(), "Accounts and values arrays mismatch");

        // Loop-invariant: one issuer for the whole call, read once rather than per recipient.
        let issuer = self.storage.issuer_address.get_current_value();

        for i in 0..MAX_TRANSFER_ADDR_PER_CALL {
            self.internal._transfer_internal(from, accounts[i], amount[i], issuer);
            let transfer_event = self.emit(Transfer { from, to: accounts[i], amount: amount[i] });
            transfer_event.deliver_to(accounts[i], MessageDelivery::onchain_constrained());
            transfer_event.deliver_to(issuer, MessageDelivery::onchain_constrained());
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
    * - The contract must not be deactivated. A pause does not stop a burn, as in CMTAT Solidity.
    * - The account must not be frozen.
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

    /**
     * @dev Writes a role and emits `NewRole`. Every path that grants a role goes through here, so
     * the event cannot be attached to one path and forgotten on another — which is exactly how the
     * constructor's grants came to be silent while `grant_role` was observable.
     *
     * Authorisation deliberately stays with the caller rather than moving in here: `grant_role`
     * checks that the sender administers the role, and the constructor cannot, because at
     * construction time no account holds `DEFAULT_ADMIN_ROLE` yet.
     *
     * `#[internal("public")]` is inlined at compile time, so this adds no call and no gas.
     */
    #[internal("public")]
    fn _grant_role_internal(role: Field, account: AztecAddress) {
        self.storage.access_control._grant_role(role, account);
        self.emit(NewRole { role, account });
    }

    #[external("public")]
    // PRIVACY: `caller` and `amount` are published - every public argument is. The amount is
    // inferable from the total_supply delta anyway, and `caller` always holds MINTER_ROLE, which is
    // public state. Do NOT add `to`: the recipient is the one thing a mint keeps private.
    #[only_self]
    fn _mint(caller: AztecAddress, amount: u128) {
        self.storage.access_control.only_role(MINTER_ROLE, caller);
        // As in CMTAT Solidity, a pause does not stop issuance; only deactivation does.
        assert(!self.storage.pause_module.is_deactivated(), "Error: token contract is deactivated");
        let supply = self.storage.total_supply.read().add(amount);
        self.storage.total_supply.write(supply);
    }

    #[external("public")]
    // PRIVACY: this function MUST take no arguments. It exists only to read the pause flag, which is
    // PublicMutable and so unreadable from private execution. Anything passed here is published;
    // `from`, `to` and `amount` never cross, and that is the single most important property of a
    // transfer in this contract.
    #[only_self]
    fn _transfer() {
        assert(!self.storage.pause_module.is_paused(), "Error: token contract is paused");
    }

    #[external("public")]
    // PRIVACY: `caller` and `amount` are published, as for `_mint`. The debited `account` is not -
    // but only because the burner and the holder are different parties. A holder granted
    // BURNER_ROLE who redeems its own tokens publishes itself. Keep BURNER_ROLE an issuer role.
    #[only_self]
    fn _burn(caller: AztecAddress, amount: u128) {
        self.storage.access_control.only_role(BURNER_ROLE, caller);
        // As in CMTAT Solidity, a pause does not stop redemption; only deactivation does.
        assert(!self.storage.pause_module.is_deactivated(), "Error: token contract is deactivated");
        let new_supply = self.storage.total_supply.read().sub(amount);
        self.storage.total_supply.write(new_supply);
    }

    /** ==========================================================
     * ===================== HYBRID: PRIVATE/PUBLIC BRIDGES ======
     * ======================================================== */
    // The four AIP-20 paths that move value between the private notes and a public balance, offered
    // as the holder's own choice and only when the token was deployed with `public_side_enabled`.
    // Same names, parameter types and selectors as AIP-20. What each publishes is stated in
    // doc/README.md, "Private/public bridges"; the helpers and the licence of the derived parts are in
    // lib/src/modules/hybridModule.nr. The CMTAT compliance chain runs in the private half exactly as
    // for transfer_private_to_private; the enqueued public halves add the pause check and the public
    // balance move, whose arguments (the public party and the amount) are published by design.

    #[external("public")]
    #[view]
    fn balance_of_public(owner: AztecAddress) -> pub u128 {
        self.storage.public_balances.balance_of(owner)
    }

    #[external("public")]
    #[view]
    fn public_get_public_side_enabled() -> pub Field {
        self.storage.public_side_enabled.read().to_field()
    }

    /**
     * @dev: Spends `from`'s notes in private and credits `to`'s PUBLIC balance. `to` and `amount` become
     * public; `from` stays private. Both parties are screened as for a private transfer.
     *
     * Requirements:
     * - The public side must be enabled.
     * - The contract must not be paused.
     * - Neither party may be frozen; both must pass the enabled list.
     */
    #[authorize_once("from", "authwit_nonce")]
    #[external("private")]
    fn transfer_private_to_public(from: AztecAddress, to: AztecAddress, amount: u128, authwit_nonce: Field) {
        require_public_side_enabled(self.storage.public_side_enabled.read());
        let issuer = self.storage.issuer_address.get_current_value();
        self.internal._screen_transfer(from, to);
        self.internal._debit_private(from, amount, issuer);
        self.enqueue_self._credit_public(to, amount);
    }

    /**
     * @dev: Debits `from`'s PUBLIC balance and creates a note for `to`. `from` and `amount` become
     * public; `to` stays private. Both parties are screened as for a private transfer.
     *
     * Requirements: as transfer_private_to_public, plus a sufficient public balance.
     */
    #[authorize_once("from", "authwit_nonce")]
    #[external("private")]
    fn transfer_public_to_private(from: AztecAddress, to: AztecAddress, amount: u128, authwit_nonce: Field) {
        require_public_side_enabled(self.storage.public_side_enabled.read());
        let issuer = self.storage.issuer_address.get_current_value();
        self.internal._screen_transfer(from, to);
        self.internal._credit_private(to, amount, issuer);
        self.enqueue_self._debit_public(from, amount);
    }

    /**
     * @dev: Opens a partial note for `to` that only `completer` can later fill with an amount
     * (transfer_private_to_commitment). The recipient is screened HERE, because at completion the
     * contract holds only the commitment; the issuer is told which address the commitment belongs
     * to through a constrained event, since the library delivers the partial note to `to` alone.
     *
     * Requirements:
     * - The public side must be enabled.
     * - `to` must not be frozen and must pass the enabled list.
     */
    #[external("private")]
    fn initialize_transfer_commitment(to: AztecAddress, completer: AztecAddress) -> pub Field {
        require_public_side_enabled(self.storage.public_side_enabled.read());
        let issuer = self.storage.issuer_address.get_current_value();
        self.internal._open_commitment(to, completer, issuer)
    }

    /**
     * @dev: Spends `from`'s notes and completes `commitment` with `amount`. The parties stay private;
     * the completion log carries the amount unencrypted, tagged by the commitment. The recipient was
     * screened when the commitment was opened; the sender is screened here.
     *
     * Requirements:
     * - The public side must be enabled.
     * - The contract must not be paused.
     * - `from` must not be frozen and must pass the enabled list.
     * - The caller must be the completer the commitment was opened for.
     */
    #[authorize_once("from", "authwit_nonce")]
    #[external("private")]
    fn transfer_private_to_commitment(from: AztecAddress, commitment: Field, amount: u128, authwit_nonce: Field) {
        require_public_side_enabled(self.storage.public_side_enabled.read());
        let issuer = self.storage.issuer_address.get_current_value();
        assert(!self.storage.enforcement_module.is_frozen(from), "Frozen: Sender");
        self.internal._debit_private(from, amount, issuer);
        complete_commitment(
            self.context,
            commitment,
            self.msg_sender(),
            self.storage.private_balances.get_storage_slot(),
            amount,
        );
        self.enqueue_self._transfer();
    }

    /**
     * @dev: transfer_private_to_public plus a partial note for `to` that the SENDER may later
     * complete - the AIP-20 "deposit now, receive the private output later" pattern.
     */
    #[authorize_once("from", "authwit_nonce")]
    #[external("private")]
    fn transfer_private_to_public_with_commitment(from: AztecAddress, to: AztecAddress, amount: u128, authwit_nonce: Field) -> pub Field {
        require_public_side_enabled(self.storage.public_side_enabled.read());
        let issuer = self.storage.issuer_address.get_current_value();
        self.internal._screen_transfer(from, to);
        self.internal._debit_private(from, amount, issuer);
        self.enqueue_self._credit_public(to, amount);
        self.internal._open_commitment(to, self.msg_sender(), issuer)
    }

    // ---- hybrid: private helpers ----

    #[internal("private")]
    fn _screen_transfer(from: AztecAddress, to: AztecAddress) {
        assert(!self.storage.enforcement_module.is_frozen(from), "Frozen: Sender");
        assert(!self.storage.enforcement_module.is_frozen(to), "Frozen: Recipient");
    }

    /// Spends `amount` of `from`'s notes; the change note goes to `from` and, as every note, to the issuer.
    #[internal("private")]
    fn _debit_private(from: AztecAddress, amount: u128, issuer: AztecAddress) {
        let change_message = self.storage.private_balances.at(from).sub(amount);
        change_message.deliver(MessageDelivery::onchain_constrained());
        change_message.deliver_to(issuer, MessageDelivery::offchain());
    }

    #[internal("private")]
    fn _credit_private(to: AztecAddress, amount: u128, issuer: AztecAddress) {
        let note_message = self.storage.private_balances.at(to).add(amount);
        note_message.deliver(MessageDelivery::onchain_constrained());
        note_message.deliver_to(issuer, MessageDelivery::offchain());
    }

    #[internal("private")]
    fn _open_commitment(to: AztecAddress, completer: AztecAddress, issuer: AztecAddress) -> Field {
        assert(!self.storage.enforcement_module.is_frozen(to), "Frozen: Recipient");
        let commitment = initialize_commitment(self.context, to, completer).to_field();
        // The issuer's record of the partial note: who it belongs to and its tag, so the issuer can
        // later match the (unencrypted, commitment-tagged) completion log to a holder.
        self.emit(CommitmentInitialized { to, completer, commitment }).deliver_to(
            issuer,
            MessageDelivery::onchain_constrained(),
        );
        commitment
    }

    // ---- hybrid: public halves ----

    #[external("public")]
    #[only_self]
    // PRIVACY: `to` and `amount` are published - that is the nature of a public credit, chosen by the
    // sender. `from` never reaches this half.
    fn _credit_public(to: AztecAddress, amount: u128) {
        assert(!self.storage.pause_module.is_paused(), "Error: token contract is paused");
        self.storage.public_balances.increase(to, amount);
        self.emit(Transfer { from: PRIVATE_ADDRESS_MAGIC_VALUE, to, amount });
    }

    #[external("public")]
    #[only_self]
    // PRIVACY: `from` and `amount` are published - the debited balance is public state anyway. `to`
    // never reaches this half.
    fn _debit_public(from: AztecAddress, amount: u128) {
        assert(!self.storage.pause_module.is_paused(), "Error: token contract is paused");
        self.storage.public_balances.decrease(from, amount);
        self.emit(Transfer { from, to: PRIVATE_ADDRESS_MAGIC_VALUE, amount });
    }

    /** ==========================================================
     * ===================== UNCONSTRAINED =======================
     * ======================================================== */

    #[external("utility")]
    unconstrained fn balance_of_private(owner: AztecAddress) -> pub u128 {
        self.storage.private_balances.at(owner).balance_of()
    }
}

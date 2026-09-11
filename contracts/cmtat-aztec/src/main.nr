mod test;

use aztec::macros::aztec;

#[aztec]
pub contract CMTATAztec {
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
        access_controlModule::{
            AccessControlModule, BURNER_ROLE, DEFAULT_ADMIN_ROLE, MINTER_ROLE, VALIDATION_ROLE,
        },
        enforcementModule::{CHANGE_ROLES_DELAY_SECONDS as FREEZE_DELAY_SECONDS, Freezable, FreezableFlag},
        extraInformationModule::{DocumentInfo, ExtraInformation},
        pauseModule::PauseModule,
        validationModule::{
            CHANGE_ROLES_DELAY_SECONDS as LIST_DELAY_SECONDS, SetFlag, UserFlags, ValidationModule,
        },
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
    struct AddressFrozen {
        account: AztecAddress,
        is_frozen: bool,
        enforcer: AztecAddress,
        effective_at: u64,
    }

    #[event]
    struct AddressListed {
        account: AztecAddress,
        is_blacklisted: bool,
        is_whitelisted: bool,
        operator: AztecAddress,
        effective_at: u64,
    }

    #[event]
    struct OperationsSet {
        operate_blacklist: bool,
        operate_whitelist: bool,
        operator: AztecAddress,
        effective_at: u64,
    }

    #[storage]
    struct Storage<Context> {
        pause_module: PauseModule<Context>,
        validation_module: ValidationModule<UserFlags, Context>,
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
        self.internal._grant_role_internal(DEFAULT_ADMIN_ROLE, admin);
        self.internal._grant_role_internal(VALIDATION_ROLE, admin);

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
     * ===================== VALIDATION MODULE ===================
     * ======================================================== */

    #[external("public")]
    #[view]
    fn get_operations() -> pub Field {
        self.storage.validation_module.get_operations()
    }

    #[external("public")]
    fn set_operations(operations: SetFlag) {
        let operator = self.msg_sender();
        self.storage.validation_module.set_operations(operator, operations, self.storage.access_control);
        self.emit(OperationsSet {
            operate_blacklist: operations.operate_blacklist,
            operate_whitelist: operations.operate_whitelist,
            operator,
            effective_at: self.context.timestamp() + LIST_DELAY_SECONDS,
        });
    }

    #[external("public")]
    fn add_to_list(newListAddress: AztecAddress, userFlag: UserFlags) {
        let operator = self.msg_sender();
        self.storage.validation_module.add_to_list(
            operator,
            newListAddress,
            userFlag,
            self.storage.access_control,
        );
        self.internal._emit_listed(newListAddress, userFlag, operator);
    }

    #[external("public")]
    fn remove_from_list(removeListAddress: AztecAddress, userFlag: UserFlags) {
        let operator = self.msg_sender();
        self.storage.validation_module.remove_from_list(
            operator,
            removeListAddress,
            userFlag,
            self.storage.access_control,
        );
        self.internal._emit_listed(removeListAddress, userFlag, operator);
    }

    /// `add_to_list` and `remove_from_list` both schedule the same kind of change - a new flag set for
    /// an address - so they share one event, emitted here so its shape lives in one place.
    #[internal("public")]
    fn _emit_listed(account: AztecAddress, flags: UserFlags, operator: AztecAddress) {
        self.emit(AddressListed {
            account,
            is_blacklisted: flags.is_blacklisted,
            is_whitelisted: flags.is_whitelisted,
            operator,
            effective_at: self.context.timestamp() + LIST_DELAY_SECONDS,
        });
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
    fn total_supply() -> pub u128 {
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
        self.storage.validation_module.operateOnMint(to);

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
    * - The recipient must pass the validation module's list check (blacklist or whitelist).
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
    * Batched transfers from a single sender. See MAX_ADDR_PER_CALL for the measured batch limit.
    *
    * Emits one Transfer event per recipient, in the same mode as `transfer`, so that the batched and
    * the single path leave the same trail. Anything built on the event — an issuer reconciliation, an
    * explorer, a compliance feed — would otherwise miss every batched transfer.
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
            self.emit(Transfer { from, to: accounts[i], amount: amount[i] }).deliver_to(
                accounts[i],
                MessageDelivery::onchain_unconstrained(),
            );
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
        self.storage.validation_module.operateOnTransfer(from, to);

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
        self.storage.validation_module.operateOnBurn(account);

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
    * - The account must pass the validation module's list check (blacklist or whitelist).
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
    #[only_self]
    fn _mint(caller: AztecAddress, amount: u128) {
        self.storage.access_control.only_role(MINTER_ROLE, caller);
        // As in CMTAT Solidity, a pause does not stop issuance; only deactivation does.
        assert(!self.storage.pause_module.is_deactivated(), "Error: token contract is deactivated");
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
        // As in CMTAT Solidity, a pause does not stop redemption; only deactivation does.
        assert(!self.storage.pause_module.is_deactivated(), "Error: token contract is deactivated");
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

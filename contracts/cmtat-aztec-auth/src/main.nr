mod test;

use aztec::macros::aztec;

/// CMTATAztecAuth - an ARC-403 authorization contract that applies CMTAT's pause, deactivation and
/// freeze rules to a stock AIP-20 token from `aztec-standards`.
///
/// The token is deployed with this contract's address as its `auth_contract`; it then calls
/// `authorize_private` from every private transfer and burn and `authorize_public` from every
/// public one, passing `(from, amount, selector)`. This contract holds no balances and moves no
/// value: it only refuses. What it can and cannot enforce, and how it differs from the CMTAT token
/// contracts in this repository, is described in `doc/auth/README.md`.
///
/// The three modules are the same `cmtat_aztec_lib` modules the CMTAT token contracts use, with the
/// same roles, events and delays, so an operator runs them the same way.
#[aztec]
pub contract CMTATAztecAuth {
    use compressed_string::FieldCompressedString;

    use aztec::{
        macros::{
            events::event,
            functions::{external, initializer, internal, only_self, view},
            storage::storage,
        },
        protocol::address::AztecAddress,
        protocol::traits::ToField,
    };

    use cmtat_aztec_lib::modules::{
        access_controlModule::{AccessControlModule, DEFAULT_ADMIN_ROLE},
        authorizationHookModule::{
            AIP20_BURN_PRIVATE_SELECTOR, AIP20_BURN_PUBLIC_SELECTOR, is_burn_selector,
            require_from_not_frozen_private, require_from_not_frozen_public,
            require_lifecycle_allows,
        },
        enforcementModule::{CHANGE_ROLES_DELAY_SECONDS as FREEZE_DELAY_SECONDS, Freezable, FreezableFlag},
        pauseModule::PauseModule,
    };

    // Kept equal to the `VERSION` of the CMTAT token contracts (`contracts/cmtat-aztec*/src/main.nr`)
    // for now: the authorization contract ships with the token release it is built and tested
    // against. Bump the four together. Padded to 31 characters for `FieldCompressedString`.
    pub global VERSION: str<31> = "0.3.0                          ";

    // The two selectors the hook treats as a burn; every other selector is a transfer.
    global BURN_SELECTORS: [Field; 2] = [AIP20_BURN_PRIVATE_SELECTOR, AIP20_BURN_PUBLIC_SELECTOR];

    #[storage]
    struct Storage<Context> {
        access_control: AccessControlModule<bool, Context>,
        pause_module: PauseModule<Context>,
        enforcement_module: Freezable<FreezableFlag, Context>,
    }

    // Same events as the CMTAT token contracts, so one indexer serves both.
    #[event]
    struct NewRole {
        role: Field,
        account: AztecAddress,
    }

    #[event]
    struct RoleRevoked {
        role: Field,
        account: AztecAddress,
        sender: AztecAddress,
    }

    #[event]
    struct Paused {
        account: AztecAddress,
    }

    #[event]
    struct Unpaused {
        account: AztecAddress,
    }

    #[event]
    struct Deactivated {
        account: AztecAddress,
    }

    #[event]
    struct AddressFrozen {
        account: AztecAddress,
        is_frozen: bool,
        enforcer: AztecAddress,
        effective_at: u64,
    }

    #[external("public")]
    #[initializer]
    fn constructor(admin: AztecAddress) {
        assert(!admin.is_zero(), "invalid admin");
        self.internal._grant_role_internal(DEFAULT_ADMIN_ROLE, admin);
    }

    /** ==========================================================
     * ===================== ARC-403 HOOK ========================
     * ======================================================== */

    /**
     * @notice: Called by the token from its private transfers and burns.
     * @dev: The freeze flag is a DelayedPublicMutable and is checked here, in private. The pause and
     * deactivation flags are PublicMutable - immediate, as an emergency lever must be - so they are
     * checked by the enqueued public half. `is_burn` is the only thing that half publishes; a burn is
     * already public through the token's own enqueued supply update, and a transfer publishes only
     * that a transfer of a CMTAT-restricted token occurred - the same disclosure the CMTAT token
     * contracts make through their `_transfer()`.
     *
     * PRIVACY: never pass `from` or `amount` to the public half; every public argument is published.
     */
    #[external("private")]
    fn authorize_private(from: AztecAddress, amount: u128, selector: Field) {
        let _ = amount;
        require_from_not_frozen_private(self.storage.enforcement_module, from);
        let is_burn = is_burn_selector(selector, BURN_SELECTORS);
        self.enqueue_self._require_lifecycle_allows(is_burn);
    }

    /**
     * @notice: Called by the token from its public transfers and burns.
     */
    #[external("public")]
    fn authorize_public(from: AztecAddress, amount: u128, selector: Field) {
        let _ = amount;
        require_from_not_frozen_public(self.storage.enforcement_module, from);
        let is_burn = is_burn_selector(selector, BURN_SELECTORS);
        require_lifecycle_allows(self.storage.pause_module, is_burn);
    }

    #[external("public")]
    #[only_self]
    fn _require_lifecycle_allows(is_burn: bool) {
        require_lifecycle_allows(self.storage.pause_module, is_burn);
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
     * @notice: revoking a pause role while the contract is paused can leave it paused for good.
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
     * @roles: onlyPauser
     * @notice: Stops every transfer of every token wired to this contract. Burns continue.
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
     * @notice: Permanently stops transfers and burns of every token wired to this contract.
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

    /**
     * @roles: onlyEnforcer
     * @notice: Takes effect after FREEZE_DELAY_SECONDS; until then the address can still send.
     */
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
     * ===================== VERSION =============================
     * ======================================================== */

    #[external("public")]
    #[view]
    fn version() -> pub FieldCompressedString {
        FieldCompressedString::from_string(VERSION)
    }

    /** ==========================================================
     * ===================== INTERNAL ============================
     * ======================================================== */

    #[internal("public")]
    fn _grant_role_internal(role: Field, account: AztecAddress) {
        self.storage.access_control._grant_role(role, account);
        self.emit(NewRole { role, account });
    }
}

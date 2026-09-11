use aztec::context::{PrivateContext, PublicContext};
use aztec::protocol::address::AztecAddress;
use aztec::protocol::traits::{Deserialize, Packable, Serialize};
use aztec::state_vars::{DelayedPublicMutable, Map, StateVariable};
use crate::modules::access_controlModule::{AccessControlModule, ENFORCEMENT_ROLE};

// Freezing an address takes effect only after this delay. Expressed in seconds: since Aztec v3 a
// DelayedPublicMutable's delay is a duration, not a number of blocks.
pub global CHANGE_ROLES_DELAY_SECONDS: u64 = 360;

#[derive(Deserialize, Packable, Eq, Serialize)]
pub struct FreezableFlag {
    pub is_freezed: bool,
}

trait FreezableFlagTrait {
    fn get_is_frozen(self) -> bool;
}

pub struct Freezable<T, Context> {
    pub map: Map<AztecAddress, DelayedPublicMutable<T, CHANGE_ROLES_DELAY_SECONDS, Context>, Context>,
}

// TODO(#13824): remove this impl once we allow structs to hold state variables.
impl<T, Context> StateVariable<1, Context> for Freezable<T, Context> {
    fn new(context: Context, storage_slot: Field) -> Self {
        assert(storage_slot != 0, "Storage slot 0 not allowed. Storage slots must start from 1.");
        Self { map: Map::new(context, storage_slot) }
    }

    fn get_storage_slot(self) -> Field {
        self.map.get_storage_slot()
    }
}

impl<T> Freezable<T, PublicContext>
where
    T: Eq + FreezableFlagTrait + Packable,
{

    pub fn is_frozen(self: Self, address: AztecAddress) -> bool {
        self.map.at(address).get_current_value().get_is_frozen()
    }

    /**
     * @dev Freezes an account. An account can be unfrozen
     *
     * Requirements:
     *
     * - The account must not be already frozen
     */
    pub fn freeze(
        self: Self,
        caller: AztecAddress,
        address: AztecAddress,
        val: T,
        ac: AccessControlModule<bool, PublicContext>,
    ) {
        ac.only_role(ENFORCEMENT_ROLE, caller);
        self._require_not_freezed(address);
        self.map.at(address).schedule_value_change(val);
    }

    pub fn unfreeze(
        self: Self,
        caller: AztecAddress,
        address: AztecAddress,
        val: T,
        ac: AccessControlModule<bool, PublicContext>,
    ) {
        ac.only_role(ENFORCEMENT_ROLE, caller);
        self._require_freezed(address);
        self.map.at(address).schedule_value_change(val);
    }

    // Internal functions
    fn _require_not_freezed(self: Self, address: AztecAddress) {
        assert(
            self.map.at(address).get_current_value().get_is_frozen() == false,
            "error: address already freezed",
        );
    }

    fn _require_freezed(self: Self, address: AztecAddress) {
        assert(
            self.map.at(address).get_current_value().get_is_frozen() == true,
            "error: address already unfreezed",
        );
    }
}

impl<T> Freezable<T, &mut PrivateContext>
where
    T: Eq + FreezableFlagTrait + Packable,
{

    pub fn is_frozen(self: Self, user: AztecAddress) -> bool {
        let user_roles: T = self.map.at(user).get_current_value();
        user_roles.get_is_frozen()
    }
}

impl FreezableFlagTrait for FreezableFlag {
    fn get_is_frozen(self) -> bool {
        self.is_freezed
    }
}

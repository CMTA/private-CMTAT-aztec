use aztec::context::PublicContext;
use aztec::protocol::address::AztecAddress;
use aztec::protocol::traits::{Deserialize, Packable, Serialize};
use aztec::state_vars::{PublicMutable, StateVariable};
use compressed_string::FieldCompressedString;
use crate::modules::access_controlModule::{AccessControlModule, DEBT_CREDIT_EVENT_ROLE};

pub global FLAG_DEFAULT_FLAG: Field = 1;
pub global FLAG_REDEEMED_FLAG: Field = 2;

global T_SERIALIZED_LEN: u32 = 3;

#[derive(Deserialize, Eq, Packable, Serialize)]
pub struct CreditEventsStruct {
    pub flagDefault: bool,
    pub flagRedeemed: bool,
    pub rating: FieldCompressedString,
}

pub struct CreditEvents<T, Context> {
    pub credit_event: PublicMutable<CreditEventsStruct, Context>,
}

// TODO(#13824): remove this impl once we allow structs to hold state variables.
impl<T, Context> StateVariable<T_SERIALIZED_LEN, Context> for CreditEvents<T, Context> {
    fn new(context: Context, storage_slot: Field) -> Self {
        assert(storage_slot != 0, "Storage slot 0 not allowed. Storage slots must start from 1.");
        Self { credit_event: PublicMutable::new(context, storage_slot) }
    }

    fn get_storage_slot(self) -> Field {
        self.credit_event.get_storage_slot()
    }
}

impl<T> CreditEvents<T, PublicContext> {
    /**
    * @notice Set all attributes of creditEvents
    * The values of all attributes will be changed even if the new values are the same as the current ones
    */
    pub fn setCreditEvents(
        self: Self,
        credit_events: CreditEventsStruct,
        caller: AztecAddress,
        ac: AccessControlModule<bool, PublicContext>,
    ) {
        ac.only_role(DEBT_CREDIT_EVENT_ROLE, caller);
        let creditEvents = CreditEventsStruct {
            flagDefault: credit_events.flagDefault,
            flagRedeemed: credit_events.flagRedeemed,
            rating: credit_events.rating,
        };
        self.credit_event.write(creditEvents);
    }

    pub fn get_credit_events(self: Self) -> [Field; T_SERIALIZED_LEN] {
        self.credit_event.read().serialize()
    }
}

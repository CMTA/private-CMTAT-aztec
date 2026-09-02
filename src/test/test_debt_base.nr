use crate::test::utils;
use crate::modules::access_controlModule::DEBT_ROLE;
use crate::modules::extensions::debtBaseModule::DebtBaseStruct;
use crate::CMTAToken as Token;
use aztec::protocol::traits::Serialize;
use compressed_string::FieldCompressedString;

#[test]
unconstrained fn set_and_get_debt_test() {
    let (env, token_contract_address, issuer, _) = utils::setup(/* with_account_contracts */ false);

    env.call_public(issuer, Token::at(token_contract_address).grant_role(DEBT_ROLE, issuer));

    let text = FieldCompressedString::from_string("abc0000000000000000000000000000");
    let debt_events = DebtBaseStruct {
        interestRate: 3 as Field,
        parValue: 1 as Field,
        guarantor: text,
        bondHolder: text,
        maturityDate: text,
        interestScheduleFormat: text,
        interestPaymentDate: text,
        dayCountConvention: text,
        businessDayConvention: text,
        publicHolidaysCalendar: text,
        issuanceDate: text,
        couponFrequency: text,
    };

    env.call_public(issuer, Token::at(token_contract_address).set_debt_base(debt_events));

    let ret: [Field; 12] =
        env.call_public(issuer, Token::at(token_contract_address).get_debt_base());

    let string_val = text.serialize()[0];
    assert(ret[0] == 3);
    assert(ret[1] == 1);
    for i in 2..12 {
        assert(ret[i] == string_val);
    }
}

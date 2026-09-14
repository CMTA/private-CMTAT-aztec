//! The CMTAT additions: roles, terms, token ID, version.
use crate::test::utils;
use crate::CMTATAztecAIP20 as Token;
use cmtat_aztec_lib::modules::access_controlModule::{DEFAULT_ADMIN_ROLE, EXTRA_INFORMATION_ROLE};
use cmtat_aztec_lib::modules::extraInformationModule::DocumentInfo;
use compressed_string::FieldCompressedString;

unconstrained fn sample_terms() -> DocumentInfo {
    DocumentInfo {
        name: FieldCompressedString::from_string("Bond terms 2026 000000000000000"),
        uri: FieldCompressedString::from_string("https://example.com/terms.pdf00"),
        documentHashHigh: 0xdeadbeef as u128,
        documentHashLow: 0xcafe as u128,
    }
}

#[test]
unconstrained fn constructor_grants_admin_and_extra_information_roles() {
    let (env, token, admin, user) = utils::setup();
    assert(env.view_public(Token::at(token).has_role(DEFAULT_ADMIN_ROLE, admin)) == 1);
    assert(env.view_public(Token::at(token).has_role(EXTRA_INFORMATION_ROLE, admin)) == 1);
    assert(env.view_public(Token::at(token).has_role(DEFAULT_ADMIN_ROLE, user)) == 0);
}

#[test]
unconstrained fn terms_empty_by_default_then_set_and_replaced() {
    let (env, token, admin, _) = utils::setup();
    let empty: [Field; 5] = env.view_public(Token::at(token).terms());
    assert(empty[2] == 0);
    env.call_public(admin, Token::at(token).set_terms(sample_terms()));
    let ret: [Field; 5] = env.view_public(Token::at(token).terms());
    assert(ret[2] == 0xdeadbeef);
    assert(ret[3] == 0xcafe);
    assert(ret[4] != 0); // lastModified stamped by the contract
    let updated = DocumentInfo {
        name: FieldCompressedString::from_string("Updated terms 00000000000000000"),
        uri: FieldCompressedString::from_string("https://example.com/terms000000"),
        documentHashHigh: 1 as u128,
        documentHashLow: 2 as u128,
    };
    env.call_public(admin, Token::at(token).set_terms(updated));
    let ret: [Field; 5] = env.view_public(Token::at(token).terms());
    assert(ret[2] == 1);
    assert(ret[3] == 2);
}

#[test(should_fail_with = "AccessControlUnauthorizedAccount")]
unconstrained fn set_terms_requires_the_role() {
    let (env, token, _, user) = utils::setup();
    env.call_public(user, Token::at(token).set_terms(sample_terms()));
}

#[test]
unconstrained fn token_id_set_and_read() {
    let (env, token, admin, _) = utils::setup();
    let id = FieldCompressedString::from_string("ISIN CH0000000000 0000000000000");
    env.call_public(admin, Token::at(token).set_token_id(id));
    assert(env.view_public(Token::at(token).token_id()) == id);
}

#[test(should_fail_with = "AccessControlUnauthorizedAccount")]
unconstrained fn set_token_id_requires_the_role() {
    let (env, token, _, user) = utils::setup();
    env.call_public(user, Token::at(token).set_token_id(FieldCompressedString::from_string("X000000000000000000000000000000")));
}

#[test]
unconstrained fn admin_can_delegate_the_extra_information_role() {
    let (env, token, admin, user) = utils::setup();
    env.call_public(admin, Token::at(token).grant_role(EXTRA_INFORMATION_ROLE, user));
    env.call_public(user, Token::at(token).set_terms(sample_terms()));
}

#[test]
unconstrained fn version_matches_the_other_cmtat_contracts() {
    let (env, token, _, _) = utils::setup();
    let v = env.view_public(Token::at(token).version());
    assert(v == FieldCompressedString::from_string(crate::CMTATAztecAIP20::VERSION));
    assert(v == FieldCompressedString::from_string("0.3.0                          "));
}

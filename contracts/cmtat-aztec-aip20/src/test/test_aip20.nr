//! The AIP-20 surface, exercised enough to show the copied token still behaves as the standard one
//! and that the hook wiring to CMTATAztecAuth works end to end inside this workspace.
use crate::test::utils::{self, MINT_AMOUNT};
use crate::CMTATAztecAIP20 as Token;
use aztec::protocol::traits::ToField;
use arc403_interface::AuthorizationContract as Auth;
use cmtat_aztec_lib::modules::access_controlModule::{ENFORCEMENT_ROLE, PAUSE_ROLE};
use cmtat_aztec_lib::modules::authorizationHookModule::{AIP20_BURN_PRIVATE_SELECTOR, AIP20_BURN_PUBLIC_SELECTOR};
use cmtat_aztec_lib::modules::enforcementModule::{CHANGE_ROLES_DELAY_SECONDS, FreezableFlag};

#[test]
unconstrained fn mint_and_private_transfer() {
    let (env, token, admin, user) = utils::setup();
    utils::mint_to_private(env, token, admin, MINT_AMOUNT, admin);
    utils::check_private_balance(env, token, admin, MINT_AMOUNT);
    env.call_private(admin, Token::at(token).transfer_private_to_private(admin, user, 1000, 0));
    utils::check_private_balance(env, token, admin, MINT_AMOUNT - 1000);
    utils::check_private_balance(env, token, user, 1000);
    assert_eq(env.view_public(Token::at(token).total_supply()), MINT_AMOUNT);
}

#[test]
unconstrained fn public_balances_and_burn() {
    let (env, token, admin, user) = utils::setup();
    env.call_public(admin, Token::at(token).mint_to_public(user, 500));
    assert_eq(env.view_public(Token::at(token).balance_of_public(user)), 500);
    env.call_public(user, Token::at(token).burn_public(user, 200, 0));
    assert_eq(env.view_public(Token::at(token).balance_of_public(user)), 300);
    assert_eq(env.view_public(Token::at(token).total_supply()), 300);
}

/// The selectors are those of the standard: the copy changed no entry-point name or type.
#[test]
unconstrained fn aip20_selectors_are_unchanged() {
    let (_, token, admin, user) = utils::setup();
    assert_eq(Token::at(token).transfer_private_to_private(admin, user, 1, 0).selector.to_field(), 0xedc09d49);
    assert_eq(Token::at(token).burn_private(admin, 1, 0).selector.to_field(), AIP20_BURN_PRIVATE_SELECTOR);
    assert_eq(Token::at(token).burn_public(admin, 1, 0).selector.to_field(), AIP20_BURN_PUBLIC_SELECTOR);
    assert_eq(Token::at(token).balance_of_private(admin).selector.to_field(), 0x4375727c);
    assert_eq(Token::at(token).total_supply().selector.to_field(), 0x8dd382ec);
}

// --- the hook, end to end, with CMTATAztecAuth deployed in the same workspace -------------------

#[test]
unconstrained fn wired_token_reports_its_auth_contract_and_transfers_by_default() {
    let (env, token, auth, admin, user) = utils::setup_with_auth();
    assert_eq(env.view_public(Token::at(token).get_auth_contract()), auth);
    utils::mint_to_private(env, token, admin, MINT_AMOUNT, admin);
    env.call_private(admin, Token::at(token).transfer_private_to_private(admin, user, 1000, 0));
    utils::check_private_balance(env, token, user, 1000);
}

#[test(should_fail_with = "Error: contract is paused")]
unconstrained fn pause_on_the_auth_contract_stops_a_private_transfer() {
    let (env, token, auth, admin, user) = utils::setup_with_auth();
    utils::mint_to_private(env, token, admin, MINT_AMOUNT, admin);
    env.call_public(admin, Auth::at(auth).grant_role(PAUSE_ROLE, admin));
    env.call_public(admin, Auth::at(auth).pause_contract());
    env.call_private(admin, Token::at(token).transfer_private_to_private(admin, user, 1000, 0));
}

#[test]
unconstrained fn pause_on_the_auth_contract_does_not_stop_a_burn() {
    let (env, token, auth, admin, _) = utils::setup_with_auth();
    utils::mint_to_private(env, token, admin, MINT_AMOUNT, admin);
    env.call_public(admin, Auth::at(auth).grant_role(PAUSE_ROLE, admin));
    env.call_public(admin, Auth::at(auth).pause_contract());
    env.call_private(admin, Token::at(token).burn_private(admin, 500, 0));
    utils::check_private_balance(env, token, admin, MINT_AMOUNT - 500);
}

#[test(should_fail_with = "Error: contract is deactivated")]
unconstrained fn deactivation_on_the_auth_contract_stops_a_burn() {
    let (env, token, auth, admin, _) = utils::setup_with_auth();
    utils::mint_to_private(env, token, admin, MINT_AMOUNT, admin);
    env.call_public(admin, Auth::at(auth).grant_role(PAUSE_ROLE, admin));
    env.call_public(admin, Auth::at(auth).pause_contract());
    env.call_public(admin, Auth::at(auth).deactivate_contract());
    env.call_private(admin, Token::at(token).burn_private(admin, 500, 0));
}

#[test(should_fail_with = "Frozen: from address")]
unconstrained fn freeze_on_the_auth_contract_stops_the_frozen_sender() {
    let (env, token, auth, admin, user) = utils::setup_with_auth();
    utils::mint_to_private(env, token, admin, MINT_AMOUNT, admin);
    env.call_public(admin, Auth::at(auth).grant_role(ENFORCEMENT_ROLE, admin));
    env.call_public(admin, Auth::at(auth).freeze(admin, FreezableFlag { is_freezed: true }));
    utils::advance_past_delay(env, CHANGE_ROLES_DELAY_SECONDS);
    env.call_private(admin, Token::at(token).transfer_private_to_private(admin, user, 1000, 0));
}

#[test(should_fail_with = "Error: contract is paused")]
unconstrained fn pause_on_the_auth_contract_stops_a_public_transfer() {
    let (env, token, auth, admin, user) = utils::setup_with_auth();
    env.call_public(admin, Token::at(token).mint_to_public(admin, 500));
    env.call_public(admin, Auth::at(auth).grant_role(PAUSE_ROLE, admin));
    env.call_public(admin, Auth::at(auth).pause_contract());
    env.call_public(admin, Token::at(token).transfer_public_to_public(admin, user, 100, 0));
}

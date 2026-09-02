use crate::test::utils;
use crate::modules::access_controlModule::{MINTER_ROLE, PAUSE_ROLE};
use crate::CMTAToken as Token;

#[test]
unconstrained fn get_paused() {
    let (env, token_contract_address, _, _) = utils::setup(/* with_account_contracts */ false);

    let ret = env.view_public(Token::at(token_contract_address).public_get_pause());
    assert(ret == 0);
}

#[test]
unconstrained fn pause_test() {
    let (env, token_contract_address, issuer, _) = utils::setup(/* with_account_contracts */ false);

    //check if issuer has pause role
    let ret = env.view_public(Token::at(token_contract_address).has_role(PAUSE_ROLE, issuer));

    //issuer does not have pause role
    assert(ret == 0);

    //give pause role to issuer
    env.call_public(issuer, Token::at(token_contract_address).grant_role(PAUSE_ROLE, issuer));

    //checks that issuer has pause role
    let ret = env.view_public(Token::at(token_contract_address).has_role(PAUSE_ROLE, issuer));
    assert(ret == 1);

    //checks if contract is paused
    let ret = env.view_public(Token::at(token_contract_address).public_get_pause());
    assert(ret == 0);

    //issuer pauses the contract
    env.call_public(issuer, Token::at(token_contract_address).pause_contract());

    //checks if contract is indeed paused
    let ret = env.view_public(Token::at(token_contract_address).public_get_pause());
    assert(ret == 1);

    //issuer unpauses the contract
    env.call_public(issuer, Token::at(token_contract_address).unpause_contract());

    //checks that the contract has been unpaused correctly
    let ret = env.view_public(Token::at(token_contract_address).public_get_pause());
    assert(ret == 0);
}

#[test(should_fail_with = "Error: token contract is paused")]
unconstrained fn mint_when_paused_fails() {
    let (env, token_contract_address, issuer, _) = utils::setup(/* with_account_contracts */ false);

    let mint_amount = 10000 as u128;

    env.call_public(issuer, Token::at(token_contract_address).grant_role(PAUSE_ROLE, issuer));
    env.call_public(issuer, Token::at(token_contract_address).grant_role(MINTER_ROLE, issuer));
    env.call_public(issuer, Token::at(token_contract_address).pause_contract());

    let ret = env.view_public(Token::at(token_contract_address).public_get_pause());
    assert(ret == 1);

    env.call_private(issuer, Token::at(token_contract_address).mint(issuer, mint_amount));
}

#[test(should_fail_with = "Error: token contract is paused")]
unconstrained fn transfer_when_paused_fails() {
    let (env, token_contract_address, issuer, user1, _) =
        utils::setup_and_mint(/* with_account_contracts */ false);

    let transfer_amount = 100 as u128;

    env.call_public(issuer, Token::at(token_contract_address).grant_role(PAUSE_ROLE, issuer));
    env.call_public(issuer, Token::at(token_contract_address).grant_role(MINTER_ROLE, issuer));
    env.call_public(issuer, Token::at(token_contract_address).pause_contract());

    let ret = env.view_public(Token::at(token_contract_address).public_get_pause());
    assert(ret == 1);

    env.call_private(
        issuer,
        Token::at(token_contract_address).transfer(issuer, user1, transfer_amount, 0),
    );
}

#[test(should_fail_with = "error: contract already paused")]
unconstrained fn pause_twice_throws() {
    let (env, token_contract_address, issuer, _) = utils::setup(/* with_account_contracts */ false);

    env.call_public(issuer, Token::at(token_contract_address).grant_role(PAUSE_ROLE, issuer));
    env.call_public(issuer, Token::at(token_contract_address).pause_contract());
    env.call_public(issuer, Token::at(token_contract_address).pause_contract());
}

//pause fails when caller does not have pause role
#[test(should_fail_with = "AccessControlUnauthorizedAccount")]
unconstrained fn test_pause_roles() {
    let (env, token_contract_address, _, user1) = utils::setup(/* with_account_contracts */ false);

    env.call_public(user1, Token::at(token_contract_address).pause_contract());
}

//owner has role when pause but not the role when unpause
#[test(should_fail_with = "AccessControlUnauthorizedAccount")]
unconstrained fn test_pause_role_2() {
    let (env, token_contract_address, issuer, user) =
        utils::setup(/* with_account_contracts */ false);

    env.call_public(issuer, Token::at(token_contract_address).grant_role(PAUSE_ROLE, user));

    env.call_public(user, Token::at(token_contract_address).pause_contract());

    //checks if contract is indeed paused
    let ret = env.view_public(Token::at(token_contract_address).public_get_pause());
    assert(ret == 1);

    env.call_public(issuer, Token::at(token_contract_address).revoke_role(PAUSE_ROLE, user));

    env.call_public(user, Token::at(token_contract_address).unpause_contract());
}

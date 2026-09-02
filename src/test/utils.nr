use aztec::context::calls::PrivateCall;
use aztec::protocol::address::AztecAddress;
use aztec::protocol::traits::Deserialize;
use aztec::test::helpers::test_environment::{CallPrivateOptions, TestEnvironment};

use crate::modules::access_controlModule::MINTER_ROLE;
use crate::CMTAToken as Token;
use crate::CMTAToken::CHANGE_ROLES_DELAY_SECONDS;

pub unconstrained fn setup(
    with_account_contracts: bool,
) -> (TestEnvironment, AztecAddress, AztecAddress, AztecAddress) {
    // Setup env, generate keys
    let mut env = TestEnvironment::new();
    let (issuer, user1) = if with_account_contracts {
        let issuer = env.create_contract_account();
        let user1 = env.create_contract_account();
        (issuer, user1)
    } else {
        let issuer = env.create_light_account();
        let user1 = env.create_light_account();
        (issuer, user1)
    };

    // Deploy token contract
    let initializer_call = Token::interface().constructor(
        issuer,
        "TestToken0000000000000000000000",
        "TT00000000000000000000000000000",
        18,
    );
    let token_contract_address =
        env.deploy("CMTAToken").with_public_initializer(issuer, initializer_call);

    // The constructor only *schedules* the issuer address, because issuer_address is a
    // DelayedPublicMutable. Nothing that reads the issuer (every mint, transfer and burn does) works
    // until that delay has elapsed.
    advance_past_delay(env, CHANGE_ROLES_DELAY_SECONDS);

    (env, token_contract_address, issuer, user1)
}

pub unconstrained fn setup_and_more_addresses(
    with_account_contracts: bool,
) -> (TestEnvironment, AztecAddress, AztecAddress, AztecAddress, AztecAddress, AztecAddress) {
    // Setup
    let (mut env, token_contract_address, issuer, user1) = setup(with_account_contracts);

    let user2 = env.create_light_account();
    let user3 = env.create_light_account();

    (env, token_contract_address, issuer, user1, user2, user3)
}

pub unconstrained fn setup_and_mint(
    with_account_contracts: bool,
) -> (TestEnvironment, AztecAddress, AztecAddress, AztecAddress, u128) {
    // Setup
    let (env, token_contract_address, issuer, user1) = setup(with_account_contracts);
    let mint_amount = 10000 as u128;

    env.call_public(issuer, Token::at(token_contract_address).grant_role(MINTER_ROLE, issuer));
    env.call_private(issuer, Token::at(token_contract_address).mint(issuer, mint_amount));

    (env, token_contract_address, issuer, user1, mint_amount)
}

/// Calls a private function as `caller` while granting the transaction access to `owner`'s secrets.
///
/// While an authwit authorizes a contract to perform an action, spending private notes still requires
/// knowledge of the note secrets, so the owner's scope must be available to the transaction. Making
/// `caller` the sender is what makes `msg_sender` differ from `from`, which is the condition that
/// triggers authwit validation.
pub unconstrained fn call_private_on_behalf_of<let M: u32, let N: u32, T>(
    env: TestEnvironment,
    caller: AztecAddress,
    owner: AztecAddress,
    call: PrivateCall<M, N, T>,
) -> T
where
    T: Deserialize,
{
    env.call_private_opts(
        caller,
        CallPrivateOptions::new().with_additional_scopes([owner]),
        call,
    )
}

pub unconstrained fn check_private_balance(
    env: TestEnvironment,
    token_contract_address: AztecAddress,
    address: AztecAddress,
    address_amount: u128,
) {
    assert_eq(
        env.execute_utility(Token::at(token_contract_address).balance_of_private(address)),
        address_amount,
    );
}

/// Advances the chain past a DelayedPublicMutable delay so that a scheduled value change (the issuer
/// address, a freeze, a blacklist entry, an operations flag) has become the current value.
pub unconstrained fn advance_past_delay(env: TestEnvironment, delay: u64) {
    env.advance_next_block_timestamp_by(delay + 1);
    env.mine_block();
}

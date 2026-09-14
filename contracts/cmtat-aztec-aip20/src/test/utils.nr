use aztec::oracle::random::random;
use aztec::protocol::address::AztecAddress;
use aztec::test::helpers::test_environment::TestEnvironment;
use std::test::OracleMock;

pub use cmtat_aztec_test_helpers::{advance_past_delay, call_private_on_behalf_of};
use crate::CMTATAztecAIP20 as Token;

pub global MINT_AMOUNT: u128 = 10_000 as u128;

/// Deploys the token with `admin` as CMTAT admin and minter, no authorization contract.
pub unconstrained fn setup() -> (TestEnvironment, AztecAddress, AztecAddress, AztecAddress) {
    let mut env = TestEnvironment::new();
    let admin = env.create_light_account();
    let user = env.create_light_account();
    let token = deploy(&mut env, admin, admin, AztecAddress::zero());
    (env, token, admin, user)
}

/// Deploys the token wired to a `CMTATAztecAuth` administered by `admin`.
pub unconstrained fn setup_with_auth() -> (TestEnvironment, AztecAddress, AztecAddress, AztecAddress, AztecAddress) {
    let mut env = TestEnvironment::new();
    let admin = env.create_light_account();
    let user = env.create_light_account();
    let auth = env.deploy("@cmtat_aztec_auth/CMTATAztecAuth").with_public_initializer(
        admin,
        arc403_interface::AuthorizationContract::interface().constructor(admin),
    );
    let token = deploy(&mut env, admin, admin, auth);
    (env, token, auth, admin, user)
}

pub unconstrained fn deploy(
    env: &mut TestEnvironment,
    admin: AztecAddress,
    minter: AztecAddress,
    auth_contract: AztecAddress,
) -> AztecAddress {
    let initializer = Token::interface().constructor_with_minter(
        "TestToken0000000000000000000000",
        "TT00000000000000000000000000000",
        18,
        minter,
        auth_contract,
        admin,
    );
    env.deploy("CMTATAztecAIP20").with_public_initializer(admin, initializer)
}

pub unconstrained fn mint_to_private(
    env: TestEnvironment,
    token: AztecAddress,
    recipient: AztecAddress,
    amount: u128,
    minter: AztecAddress,
) {
    // The AIP-20 mint path takes note randomness from an oracle; mock it as the fork's tests do.
    let note_randomness = random();
    let _ = OracleMock::mock("getRandomField").returns(note_randomness);
    env.call_private(minter, Token::at(token).mint_to_private(recipient, amount));
}

pub unconstrained fn check_private_balance(
    env: TestEnvironment,
    token: AztecAddress,
    address: AztecAddress,
    expected: u128,
) {
    assert_eq(env.execute_utility(Token::at(token).balance_of_private(address)), expected);
}

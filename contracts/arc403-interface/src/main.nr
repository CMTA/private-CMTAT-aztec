use aztec::macros::aztec;

/// Interface-only stand-in for `CMTATAztecAuth`, the ARC-403 authorization contract with the AIP-20
/// hook signature.
///
/// A contract that calls another needs that contract's generated interface, and Noir has no way to
/// declare an interface without a contract body. Depending on `cmtat_aztec_auth` itself is not an
/// option for a token: the `#[event]` macro keeps a global selector registry across the crate
/// graph, and the token's `NewRole` / `RoleRevoked` events would collide with the authorization
/// contract's identical ones. So this crate carries the signatures and nothing else - empty bodies,
/// no events, no storage. It is not a workspace member (no artifact) and must never be deployed.
///
/// Selectors depend only on names and parameter types, so a call through this interface reaches
/// the real `CMTATAztecAuth`. Keep the signatures in step with `contracts/cmtat-aztec-auth`:
/// the hook pair is what the token needs; the administration entry points are what its tests need.
#[aztec]
pub contract AuthorizationContract {
    use aztec::macros::functions::{external, initializer};
    use aztec::protocol::address::AztecAddress;
    use cmtat_aztec_lib::modules::enforcementModule::FreezableFlag;
    use cmtat_aztec_lib::modules::validationModule::{SetFlag, UserFlags};

    // ---- ARC-403 hook ----
    #[external("private")]
    fn authorize_private(from: AztecAddress, amount: u128, selector: Field) {
        let _ = (from, amount, selector);
    }

    #[external("public")]
    fn authorize_public(from: AztecAddress, amount: u128, selector: Field) {
        let _ = (from, amount, selector);
    }

    // ---- CMTATAztecAuth administration, as the tests use it ----
    #[external("public")]
    #[initializer]
    fn constructor(admin: AztecAddress) {
        let _ = admin;
    }

    #[external("public")]
    fn grant_role(role: Field, account: AztecAddress) {
        let _ = (role, account);
    }

    #[external("public")]
    fn pause_contract() {}

    #[external("public")]
    fn unpause_contract() {}

    #[external("public")]
    fn deactivate_contract() {}

    #[external("public")]
    fn freeze(user: AztecAddress, value: FreezableFlag) {
        let _ = (user, value);
    }

    #[external("public")]
    fn set_operations(operations: SetFlag) {
        let _ = operations;
    }

    #[external("public")]
    fn add_to_list(newListAddress: AztecAddress, userFlag: UserFlags) {
        let _ = (newListAddress, userFlag);
    }
}

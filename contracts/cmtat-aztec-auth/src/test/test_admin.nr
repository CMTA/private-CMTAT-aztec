use crate::test::utils;
use crate::CMTATAztecAuth as Auth;
use cmtat_aztec_lib::modules::access_controlModule::{DEFAULT_ADMIN_ROLE, PAUSE_ROLE};
use compressed_string::FieldCompressedString;

#[test]
unconstrained fn constructor_grants_the_admin_role() {
    let (env, auth, admin, user) = utils::setup();
    assert(env.view_public(Auth::at(auth).has_role(DEFAULT_ADMIN_ROLE, admin)) == 1);
    assert(env.view_public(Auth::at(auth).has_role(DEFAULT_ADMIN_ROLE, user)) == 0);
}

#[test(should_fail_with = "AccessControlUnauthorizedAccount")]
unconstrained fn non_admin_cannot_grant_roles() {
    let (env, auth, _, user) = utils::setup();
    env.call_public(user, Auth::at(auth).grant_role(PAUSE_ROLE, user));
}

#[test(should_fail_with = "AccessControlUnauthorizedAccount")]
unconstrained fn pause_requires_the_pause_role() {
    let (env, auth, admin, _) = utils::setup();
    env.call_public(admin, Auth::at(auth).pause_contract());
}

#[test]
unconstrained fn pause_and_deactivation_flags_are_readable() {
    let (env, auth, admin, _) = utils::setup();
    assert(env.view_public(Auth::at(auth).public_get_pause()) == 0);
    assert(env.view_public(Auth::at(auth).public_get_deactivated()) == 0);
    utils::deactivate(env, auth, admin);
    assert(env.view_public(Auth::at(auth).public_get_pause()) == 1);
    assert(env.view_public(Auth::at(auth).public_get_deactivated()) == 1);
}

/// The version is the CMTAT token contracts' `VERSION` for now; see the constant's comment.
#[test]
unconstrained fn version_matches_the_constant() {
    let (env, auth, _, _) = utils::setup();
    let result = env.view_public(Auth::at(auth).version());
    assert(result == FieldCompressedString::from_string(crate::CMTATAztecAuth::VERSION));
    assert(result == FieldCompressedString::from_string("0.3.0                          "));
}

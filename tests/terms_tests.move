// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Tests for `haneul_ip::terms`: registration, the two flavors, and
/// the internal-consistency rules (meaningless flag combinations are
/// rejected at registration, not discovered at use).
#[test_only]
module haneul_ip::terms_tests;

use haneul::haneul::HANEUL;
use haneul::test_scenario::{Self as ts, Scenario};
use haneul_ip::protocol::ProtocolCap;
use haneul_ip::terms::{Self, TermsRegistry};
use haneul_ip::test_helpers::{str, setup};
use std::type_name;

const ADMIN: address = @0xAD;

fun register_custom(
    s: &mut Scenario,
    commercial_use: bool,
    commercial_attribution: bool,
    rev_share_bps: u64,
    derivatives_allowed: bool,
    derivatives_attribution: bool,
    derivatives_approval: bool,
    derivatives_reciprocal: bool,
    fee: u64,
): u64 {
    s.next_tx(ADMIN);
    let mut reg = s.take_shared<TermsRegistry>();
    let id = terms::register<HANEUL>(
        &mut reg,
        true,
        0,
        commercial_use,
        commercial_attribution,
        rev_share_bps,
        derivatives_allowed,
        derivatives_attribution,
        derivatives_approval,
        derivatives_reciprocal,
        fee,
        str(b""),
    );
    ts::return_shared(reg);
    id
}

#[test]
fun ids_are_sequential_from_one() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let first = register_custom(&mut s, true, false, 100, true, false, false, true, 0);
    let second = register_custom(&mut s, false, false, 0, true, false, false, true, 0);
    assert!(first == 1);
    assert!(second == 2);
    s.end();
}

#[test]
fun commercial_remix_flavor_fields() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    s.next_tx(ADMIN);
    let mut reg = s.take_shared<TermsRegistry>();
    let id = terms::register_commercial_remix<HANEUL>(&mut reg, 1_500, 777, str(b"ipfs://legal"));
    let t = terms::get(&reg, id);
    assert!(terms::commercial_use(t));
    assert!(terms::commercial_rev_share_bps(t) == 1_500);
    assert!(terms::default_minting_fee(t) == 777);
    assert!(terms::derivatives_allowed(t));
    assert!(terms::derivatives_reciprocal(t));
    assert!(!terms::derivatives_approval(t));
    assert!(terms::transferable(t));
    assert!(terms::currency(t) == type_name::with_defining_ids<HANEUL>());
    assert!(terms::uri(t) == str(b"ipfs://legal"));
    ts::return_shared(reg);
    s.end();
}

#[test]
fun non_commercial_remix_flavor_fields() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    s.next_tx(ADMIN);
    let mut reg = s.take_shared<TermsRegistry>();
    let id = terms::register_non_commercial_remix<HANEUL>(&mut reg, str(b""));
    let t = terms::get(&reg, id);
    assert!(!terms::commercial_use(t));
    assert!(terms::commercial_rev_share_bps(t) == 0);
    assert!(terms::default_minting_fee(t) == 0);
    assert!(terms::derivatives_allowed(t));
    assert!(terms::derivatives_reciprocal(t));
    ts::return_shared(reg);
    s.end();
}

#[test]
#[expected_failure(abort_code = haneul_ip::terms::EInvalidRevShare)]
fun rev_share_above_100_percent_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    register_custom(&mut s, true, false, 10_001, true, false, false, true, 0);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::terms::ENonCommercialRevShare)]
fun non_commercial_with_rev_share_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    register_custom(&mut s, false, false, 100, true, false, false, true, 0);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::terms::ENonCommercialAttribution)]
fun non_commercial_with_commercial_attribution_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    register_custom(&mut s, false, true, 0, true, false, false, true, 0);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::terms::ENonCommercialMintingFee)]
fun non_commercial_with_minting_fee_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    register_custom(&mut s, false, false, 0, true, false, false, true, 55);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::terms::ENoDerivativesButAttribution)]
fun no_derivatives_with_attribution_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    register_custom(&mut s, true, false, 0, false, true, false, false, 0);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::terms::ENoDerivativesButApproval)]
fun no_derivatives_with_approval_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    register_custom(&mut s, true, false, 0, false, false, true, false, 0);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::terms::ENoDerivativesButReciprocal)]
fun no_derivatives_with_reciprocal_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    register_custom(&mut s, true, false, 0, false, false, false, true, 0);
    abort 99
}

/// The approval allowlist names a specific party; a license that can
/// change hands afterwards would carry the consent to someone it was
/// never given to. Contradictory, so rejected at registration.
#[test]
#[expected_failure(abort_code = haneul_ip::terms::EApprovalRequiresNonTransferable)]
fun transferable_approval_terms_abort() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    // register_custom registers with transferable = true.
    register_custom(&mut s, true, false, 0, true, false, true, true, 0);
    abort 99
}

/// The registry gates its own mutations on the package version.
#[test]
#[expected_failure(abort_code = haneul_ip::terms::EWrongVersion)]
fun stale_registry_version_blocks_register() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    s.next_tx(ADMIN);
    let mut reg = s.take_shared<TermsRegistry>();
    terms::set_version_for_testing(&mut reg, 0);
    ts::return_shared(reg);
    register_custom(&mut s, true, false, 100, true, false, false, true, 0);
    abort 99
}

#[test]
fun migrate_bumps_stale_registry() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    s.next_tx(ADMIN);
    let mut reg = s.take_shared<TermsRegistry>();
    let cap = s.take_from_sender<ProtocolCap>();
    terms::set_version_for_testing(&mut reg, 0);
    terms::migrate(&mut reg, &cap);
    assert!(terms::version(&reg) == 1);
    s.return_to_sender(cap);
    ts::return_shared(reg);
    s.end();
}

#[test]
#[expected_failure(abort_code = haneul_ip::terms::ENotUpgrade)]
fun migrate_at_current_version_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    s.next_tx(ADMIN);
    let mut reg = s.take_shared<TermsRegistry>();
    let cap = s.take_from_sender<ProtocolCap>();
    terms::migrate(&mut reg, &cap);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::terms::ETermsNotFound)]
fun get_unknown_terms_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    s.next_tx(ADMIN);
    let reg = s.take_shared<TermsRegistry>();
    terms::get(&reg, 42);
    abort 99
}

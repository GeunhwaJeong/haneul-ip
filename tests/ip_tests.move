// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Tests for `haneul_ip::ip`: root registration, terms attachment
/// rules, and the per-IP licensing-config override layer.
#[test_only]
module haneul_ip::ip_tests;

use haneul::test_scenario::{Self as ts};
use haneul_ip::ip::{Self, IPAsset, IPOwnerCap};
use haneul_ip::terms::{Self, TermsRegistry};
use haneul_ip::test_helpers::{
    str,
    hash,
    new_clock,
    setup,
    std_terms,
    root,
    root_with_terms,
    make_child,
};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

#[test]
fun register_root_basics() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let (ip_id, _) = root(&mut s, ALICE, 7, &clock);

    s.next_tx(ALICE);
    let asset = s.take_shared_by_id<IPAsset>(ip_id);
    assert!(ip::creator(&asset) == ALICE);
    assert!(!ip::is_derivative(&asset));
    assert!(ip::royalty_stack_bps(&asset) == 0);
    assert!(ip::expires_at_ms(&asset) == 0);
    assert!(!ip::is_tagged(&asset));
    assert!(ip::content_hash(&asset) == hash(7));
    assert!(ip::licenses_minted(&asset) == 0);
    ts::return_shared(asset);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = haneul_ip::ip::EBadContentHash)]
fun content_hash_31_bytes_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    s.next_tx(ALICE);
    let mut short_hash = hash(1);
    short_hash.pop_back();
    let cap = ip::register(str(b"x"), short_hash, str(b""), &clock, s.ctx());
    transfer::public_transfer(cap, ALICE);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::ip::EBadContentHash)]
fun content_hash_33_bytes_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    s.next_tx(ALICE);
    let mut long_hash = hash(1);
    long_hash.push_back(1);
    let cap = ip::register(str(b"x"), long_hash, str(b""), &clock, s.ctx());
    transfer::public_transfer(cap, ALICE);
    abort 99
}

#[test]
fun attach_terms_marks_ip() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);

    s.next_tx(ALICE);
    let asset = s.take_shared_by_id<IPAsset>(ip_id);
    assert!(ip::has_terms(&asset, terms_id));
    assert!(!ip::has_terms(&asset, terms_id + 1));
    ts::return_shared(asset);
    clock.destroy_for_testing();
    s.end();
}

/// A cap for a different IP is not this IP's cap.
#[test]
#[expected_failure(abort_code = haneul_ip::ip::ENotOwner)]
fun attach_with_wrong_cap_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (alice_ip, _) = root(&mut s, ALICE, 1, &clock);
    let (_, bob_cap_id) = root(&mut s, BOB, 2, &clock);

    s.next_tx(BOB);
    let mut asset = s.take_shared_by_id<IPAsset>(alice_ip);
    let bob_cap = s.take_from_sender_by_id<IPOwnerCap>(bob_cap_id);
    let reg = s.take_shared<TermsRegistry>();
    ip::attach_terms(&mut asset, &bob_cap, &reg, terms_id);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::ip::ETermsAlreadyAttached)]
fun attach_same_terms_twice_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, cap_id) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);

    s.next_tx(ALICE);
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    let cap = s.take_from_sender_by_id<IPOwnerCap>(cap_id);
    let reg = s.take_shared<TermsRegistry>();
    ip::attach_terms(&mut asset, &cap, &reg, terms_id);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::ip::ETermsNotFound)]
fun attach_unknown_terms_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let (ip_id, cap_id) = root(&mut s, ALICE, 1, &clock);

    s.next_tx(ALICE);
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    let cap = s.take_from_sender_by_id<IPOwnerCap>(cap_id);
    let reg = s.take_shared<TermsRegistry>();
    ip::attach_terms(&mut asset, &cap, &reg, 42);
    abort 99
}

/// Derivatives carry the terms they were born under and cannot add
/// more (Story's rule; prevents rewriting the deal after the fact).
#[test]
#[expected_failure(abort_code = haneul_ip::ip::ENotRoot)]
fun attach_on_derivative_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let other_terms = std_terms(&mut s, 2_000, 0);
    let (parent_ip, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (child_ip, child_cap_id) = make_child(&mut s, BOB, parent_ip, terms_id, 0, 2, &clock);

    s.next_tx(BOB);
    let mut child = s.take_shared_by_id<IPAsset>(child_ip);
    let cap = s.take_from_sender_by_id<IPOwnerCap>(child_cap_id);
    let reg = s.take_shared<TermsRegistry>();
    ip::attach_terms(&mut child, &cap, &reg, other_terms);
    abort 99
}

/// The override layer: config changes the effective fee and revenue
/// share without touching the global terms.
#[test]
fun licensing_config_overrides_effective_values() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 100);
    let (ip_id, cap_id) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);

    s.next_tx(ALICE);
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    let cap = s.take_from_sender_by_id<IPOwnerCap>(cap_id);
    let reg = s.take_shared<TermsRegistry>();
    let t = terms::get(&reg, terms_id);
    assert!(ip::effective_minting_fee(&asset, terms_id, t) == 100);
    assert!(ip::effective_rev_share_bps(&asset, terms_id, t) == 1_000);

    ip::set_licensing_config(
        &mut asset,
        &cap,
        terms_id,
        false,
        option::some(250),
        option::some(2_500),
    );
    assert!(ip::effective_minting_fee(&asset, terms_id, t) == 250);
    assert!(ip::effective_rev_share_bps(&asset, terms_id, t) == 2_500);

    // Overwriting with empty overrides falls back to the terms.
    ip::set_licensing_config(&mut asset, &cap, terms_id, false, option::none(), option::none());
    assert!(ip::effective_minting_fee(&asset, terms_id, t) == 100);
    assert!(ip::effective_rev_share_bps(&asset, terms_id, t) == 1_000);

    ts::return_shared(reg);
    ts::return_shared(asset);
    s.return_to_sender(cap);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = haneul_ip::ip::EInvalidRevShare)]
fun config_rev_share_above_100_percent_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, cap_id) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);

    s.next_tx(ALICE);
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    let cap = s.take_from_sender_by_id<IPOwnerCap>(cap_id);
    ip::set_licensing_config(&mut asset, &cap, terms_id, false, option::none(), option::some(10_001));
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::ip::ETermsNotAttached)]
fun config_on_unattached_terms_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, cap_id) = root(&mut s, ALICE, 1, &clock);

    s.next_tx(ALICE);
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    let cap = s.take_from_sender_by_id<IPOwnerCap>(cap_id);
    ip::set_licensing_config(&mut asset, &cap, terms_id, false, option::none(), option::none());
    abort 99
}

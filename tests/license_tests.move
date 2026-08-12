// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Tests for `haneul_ip::license`: minting economics (fee routing,
/// slippage guard, currency binding), the mint-time snapshot, the
/// non-transferable enforcement, and the dispute/reciprocal gates.
#[test_only]
module haneul_ip::license_tests;

use haneul::haneul::HANEUL;
use haneul::test_scenario::{Self as ts};
use haneul_ip::ip::{Self, IPAsset, IPOwnerCap};
use haneul_ip::license::{Self, License};
use haneul_ip::protocol::ProtocolConfig;
use haneul_ip::terms::TermsRegistry;
use haneul_ip::test_helpers::{
    USDX,
    new_clock,
    setup,
    setup_tag,
    tag_ip,
    std_terms,
    free_terms,
    custom_terms,
    root_with_terms,
    mint_license_to,
    mint_haneul,
    make_child,
};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CAROL: address = @0xCA401;

/// The minting fee lands in the licensor's revenue pool (owner
/// claimable, since a root has no ancestors).
#[test]
fun mint_routes_fee_into_licensor_pool() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 100);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);

    mint_license_to(&mut s, BOB, ip_id, terms_id, BOB, 100, &clock);

    s.next_tx(BOB);
    let asset = s.take_shared_by_id<IPAsset>(ip_id);
    assert!(ip::claimable_by_owner<HANEUL>(&asset) == 100);
    assert!(ip::licenses_minted(&asset) == 1);
    ts::return_shared(asset);
    let license = s.take_from_sender<License>();
    assert!(license::licensor(&license) == ip_id);
    assert!(license::rev_share_bps(&license) == 1_000);
    assert!(license::is_transferable(&license));
    s.return_to_sender(license);
    clock.destroy_for_testing();
    s.end();
}

/// Slippage guard: the owner raises the fee to 200 via config; a
/// buyer who agreed to at most 150 aborts instead of overpaying.
#[test]
#[expected_failure(abort_code = haneul_ip::license::EFeeAboveMax)]
fun mint_fee_above_max_fee_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 100);
    let (ip_id, cap_id) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);

    s.next_tx(ALICE);
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    let cap = s.take_from_sender_by_id<IPOwnerCap>(cap_id);
    ip::set_licensing_config(&mut asset, &cap, terms_id, false, option::some(200), option::none());
    ts::return_shared(asset);
    s.return_to_sender(cap);

    s.next_tx(BOB);
    let cfg = s.take_shared<ProtocolConfig>();
    let reg = s.take_shared<TermsRegistry>();
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    let mut payment = mint_haneul(&mut s, 500);
    license::mint<HANEUL>(&cfg, &mut asset, &reg, terms_id, BOB, &mut payment, 150, &clock, s.ctx());
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::license::EInsufficientPayment)]
fun mint_with_short_payment_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 100);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    mint_license_to(&mut s, BOB, ip_id, terms_id, BOB, 99, &clock);
    abort 99
}

/// The minting fee must be paid in the terms' currency.
#[test]
#[expected_failure(abort_code = haneul_ip::license::EWrongCurrency)]
fun mint_in_wrong_currency_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 100);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);

    s.next_tx(BOB);
    let cfg = s.take_shared<ProtocolConfig>();
    let reg = s.take_shared<TermsRegistry>();
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    let mut payment = haneul::coin::mint_for_testing<USDX>(100, s.ctx());
    license::mint<USDX>(&cfg, &mut asset, &reg, terms_id, BOB, &mut payment, 0, &clock, s.ctx());
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::license::ETermsNotAttached)]
fun mint_on_unattached_terms_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 100);
    let other_terms = std_terms(&mut s, 2_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    mint_license_to(&mut s, BOB, ip_id, other_terms, BOB, 100, &clock);
    abort 99
}

/// The owner's kill switch for one terms id.
#[test]
#[expected_failure(abort_code = haneul_ip::ip::EConfigDisabled)]
fun mint_on_disabled_config_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 100);
    let (ip_id, cap_id) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);

    s.next_tx(ALICE);
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    let cap = s.take_from_sender_by_id<IPOwnerCap>(cap_id);
    ip::set_licensing_config(&mut asset, &cap, terms_id, true, option::none(), option::none());
    ts::return_shared(asset);
    s.return_to_sender(cap);

    mint_license_to(&mut s, BOB, ip_id, terms_id, BOB, 100, &clock);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::license::EFeeRequired)]
fun mint_free_on_paid_terms_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 100);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);

    s.next_tx(BOB);
    let cfg = s.take_shared<ProtocolConfig>();
    let reg = s.take_shared<TermsRegistry>();
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    license::mint_free(&cfg, &mut asset, &reg, terms_id, BOB, &clock, s.ctx());
    abort 99
}

#[test]
fun mint_free_works_on_free_terms() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = free_terms(&mut s);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);

    s.next_tx(BOB);
    let cfg = s.take_shared<ProtocolConfig>();
    let reg = s.take_shared<TermsRegistry>();
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    license::mint_free(&cfg, &mut asset, &reg, terms_id, BOB, &clock, s.ctx());
    ts::return_shared(cfg);
    ts::return_shared(reg);
    ts::return_shared(asset);

    s.next_tx(BOB);
    let license = s.take_from_sender<License>();
    assert!(license::rev_share_bps(&license) == 0);
    s.return_to_sender(license);
    clock.destroy_for_testing();
    s.end();
}

/// An upheld dispute freezes licensing.
#[test]
#[expected_failure(abort_code = haneul_ip::ip::ETagged)]
fun mint_on_tagged_ip_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    tag_ip(&mut s, ip_id, 9, &clock);
    mint_license_to(&mut s, BOB, ip_id, terms_id, BOB, 0, &clock);
    abort 99
}

/// The mint-time snapshot: config changes after mint do not rewrite
/// an already-sold license.
#[test]
fun license_snapshot_survives_config_change() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, cap_id) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);

    mint_license_to(&mut s, BOB, ip_id, terms_id, BOB, 0, &clock);

    s.next_tx(ALICE);
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    let cap = s.take_from_sender_by_id<IPOwnerCap>(cap_id);
    ip::set_licensing_config(&mut asset, &cap, terms_id, false, option::none(), option::some(9_000));
    ts::return_shared(asset);
    s.return_to_sender(cap);

    s.next_tx(BOB);
    let license = s.take_from_sender<License>();
    assert!(license::rev_share_bps(&license) == 1_000);
    s.return_to_sender(license);
    clock.destroy_for_testing();
    s.end();
}

#[test]
fun transferable_license_changes_hands() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    mint_license_to(&mut s, BOB, ip_id, terms_id, BOB, 0, &clock);

    s.next_tx(BOB);
    let license = s.take_from_sender<License>();
    license::transfer_license(license, CAROL);

    s.next_tx(CAROL);
    let license = s.take_from_sender<License>();
    assert!(license::licensor(&license) == ip_id);
    s.return_to_sender(license);
    clock.destroy_for_testing();
    s.end();
}

/// `key`-only + a checked transfer function = Story's transfer hook.
#[test]
#[expected_failure(abort_code = haneul_ip::license::ENotTransferable)]
fun non_transferable_license_cannot_move() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = custom_terms(&mut s, false, 0, true, 1_000, true, false, true, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    mint_license_to(&mut s, BOB, ip_id, terms_id, BOB, 0, &clock);

    s.next_tx(BOB);
    let license = s.take_from_sender<License>();
    license::transfer_license(license, CAROL);
    abort 99
}

/// A derivative may only re-license reciprocal terms.
#[test]
#[expected_failure(abort_code = haneul_ip::license::ENotReciprocal)]
fun derivative_minting_non_reciprocal_terms_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    // reciprocal = false: deriving from the root is fine, deriving
    // further (or re-licensing) is not.
    let terms_id = custom_terms(&mut s, true, 0, true, 1_000, true, false, false, 0);
    let (root_ip, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (child_ip, _) = make_child(&mut s, BOB, root_ip, terms_id, 0, 2, &clock);

    mint_license_to(&mut s, CAROL, child_ip, terms_id, CAROL, 0, &clock);
    abort 99
}

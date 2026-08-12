// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Tests for `haneul_ip::royalty`: the absolute-share split math,
/// both claim paths, the freeze rules, and multi-currency pools.
#[test_only]
module haneul_ip::royalty_tests;

use haneul::haneul::HANEUL;
use haneul::test_scenario::{Self as ts, Scenario};
use haneul_ip::ip::{Self, IPAsset, IPOwnerCap};
use haneul_ip::protocol::ProtocolConfig;
use haneul_ip::royalty;
use haneul_ip::test_helpers::{
    USDX,
    new_clock,
    setup,
    setup_tag,
    tag_ip,
    std_terms,
    root_with_terms,
    root,
    pay_royalty,
    make_child,
};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CAROL: address = @0xCA401;

/// Claims owner revenue from `ip_id` using cap `cap_id`, transfers it
/// to the claimer, and returns the amount.
fun claim_owner(s: &mut Scenario, claimer: address, ip_id: ID, cap_id: ID): u64 {
    s.next_tx(claimer);
    let cfg = s.take_shared<ProtocolConfig>();
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    let cap = s.take_from_sender_by_id<IPOwnerCap>(cap_id);
    let claimed = royalty::claim_owner<HANEUL>(&cfg, &mut asset, &cap, s.ctx());
    let amount = claimed.value();
    transfer::public_transfer(claimed, claimer);
    s.return_to_sender(cap);
    ts::return_shared(cfg);
    ts::return_shared(asset);
    amount
}

/// Claims `claimer`'s ancestor share out of `descendant_ip` using the
/// ancestor's cap; returns the amount.
fun claim_ancestor(s: &mut Scenario, claimer: address, descendant_ip: ID, cap_id: ID): u64 {
    s.next_tx(claimer);
    let cfg = s.take_shared<ProtocolConfig>();
    let mut asset = s.take_shared_by_id<IPAsset>(descendant_ip);
    let cap = s.take_from_sender_by_id<IPOwnerCap>(cap_id);
    let claimed = royalty::claim_ancestor<HANEUL>(&cfg, &mut asset, &cap, s.ctx());
    let amount = claimed.value();
    transfer::public_transfer(claimed, claimer);
    s.return_to_sender(cap);
    ts::return_shared(cfg);
    ts::return_shared(asset);
    amount
}

#[test]
fun root_owner_claims_full_payment() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, cap_id) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);

    pay_royalty(&mut s, CAROL, ip_id, 1_000, &clock);
    assert!(claim_owner(&mut s, ALICE, ip_id, cap_id) == 1_000);
    clock.destroy_for_testing();
    s.end();
}

/// The core split flow: root licenses at 10%; a fan pays the child
/// 1000; the root's owner pulls 100 out of the CHILD's pool with the
/// ROOT's cap, the child's owner gets 900.
#[test]
fun child_payment_splits_to_ancestor_and_owner() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (root_ip, root_cap_id) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (child_ip, child_cap_id) = make_child(&mut s, BOB, root_ip, terms_id, 0, 2, &clock);

    pay_royalty(&mut s, CAROL, child_ip, 1_000, &clock);

    s.next_tx(ALICE);
    let child = s.take_shared_by_id<IPAsset>(child_ip);
    assert!(ip::claimable_by_ancestor<HANEUL>(&child, root_ip) == 100);
    assert!(ip::claimable_by_owner<HANEUL>(&child) == 900);
    ts::return_shared(child);

    assert!(claim_ancestor(&mut s, ALICE, child_ip, root_cap_id) == 100);
    assert!(claim_owner(&mut s, BOB, child_ip, child_cap_id) == 900);
    clock.destroy_for_testing();
    s.end();
}

/// Three generations: root 10% + child 10% both accrue on a payment
/// to the grandchild.
#[test]
fun grandchild_payment_pays_both_ancestors() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (root_ip, root_cap_id) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (child_ip, child_cap_id) = make_child(&mut s, BOB, root_ip, terms_id, 0, 2, &clock);
    let (grandchild_ip, grandchild_cap_id) =
        make_child(&mut s, CAROL, child_ip, terms_id, 0, 3, &clock);

    pay_royalty(&mut s, ADMIN, grandchild_ip, 1_000, &clock);

    assert!(claim_ancestor(&mut s, ALICE, grandchild_ip, root_cap_id) == 100);
    assert!(claim_ancestor(&mut s, BOB, grandchild_ip, child_cap_id) == 100);
    assert!(claim_owner(&mut s, CAROL, grandchild_ip, grandchild_cap_id) == 800);
    clock.destroy_for_testing();
    s.end();
}

/// Accruals stack across payments and clear on claim.
#[test]
fun accrual_accumulates_across_payments() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (root_ip, root_cap_id) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (child_ip, _) = make_child(&mut s, BOB, root_ip, terms_id, 0, 2, &clock);

    pay_royalty(&mut s, CAROL, child_ip, 1_000, &clock);
    pay_royalty(&mut s, CAROL, child_ip, 500, &clock);
    pay_royalty(&mut s, CAROL, child_ip, 300, &clock);

    // 10% of 1800, accrued across three payments.
    assert!(claim_ancestor(&mut s, ALICE, child_ip, root_cap_id) == 180);
    clock.destroy_for_testing();
    s.end();
}

/// bps flooring dust goes to the owner, never lost, never to the
/// ancestor: 10% of 999 = 99 (floored), owner gets 900.
#[test]
fun rounding_dust_goes_to_owner() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (root_ip, root_cap_id) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (child_ip, child_cap_id) = make_child(&mut s, BOB, root_ip, terms_id, 0, 2, &clock);

    pay_royalty(&mut s, CAROL, child_ip, 999, &clock);
    assert!(claim_ancestor(&mut s, ALICE, child_ip, root_cap_id) == 99);
    assert!(claim_owner(&mut s, BOB, child_ip, child_cap_id) == 900);
    clock.destroy_for_testing();
    s.end();
}

/// Pools are per coin type and independent. The child accepted
/// HANEUL by inheritance; USDX has to be opted into by its owner.
#[test]
fun multi_currency_pools_are_independent() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (root_ip, root_cap_id) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (child_ip, child_cap_id) = make_child(&mut s, BOB, root_ip, terms_id, 0, 2, &clock);

    s.next_tx(BOB);
    let mut child = s.take_shared_by_id<IPAsset>(child_ip);
    let child_cap = s.take_from_sender_by_id<IPOwnerCap>(child_cap_id);
    ip::accept_currency<USDX>(&mut child, &child_cap);
    ts::return_shared(child);
    s.return_to_sender(child_cap);

    pay_royalty(&mut s, CAROL, child_ip, 1_000, &clock);
    s.next_tx(CAROL);
    let cfg = s.take_shared<ProtocolConfig>();
    let mut child = s.take_shared_by_id<IPAsset>(child_ip);
    let usdx = haneul::coin::mint_for_testing<USDX>(2_000, s.ctx());
    royalty::pay<USDX>(&cfg, &mut child, usdx, &clock, s.ctx());
    assert!(ip::claimable_by_ancestor<HANEUL>(&child, root_ip) == 100);
    assert!(ip::claimable_by_ancestor<USDX>(&child, root_ip) == 200);
    assert!(ip::claimable_by_owner<HANEUL>(&child) == 900);
    assert!(ip::claimable_by_owner<USDX>(&child) == 1_800);

    // Claim the USDX side with the root's cap.
    ts::return_shared(cfg);
    ts::return_shared(child);
    s.next_tx(ALICE);
    let cfg = s.take_shared<ProtocolConfig>();
    let mut child = s.take_shared_by_id<IPAsset>(child_ip);
    let cap = s.take_from_sender_by_id<IPOwnerCap>(root_cap_id);
    let claimed = royalty::claim_ancestor<USDX>(&cfg, &mut child, &cap, s.ctx());
    assert!(claimed.value() == 200);
    transfer::public_transfer(claimed, ALICE);
    s.return_to_sender(cap);
    ts::return_shared(cfg);
    ts::return_shared(child);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = haneul_ip::ip::ENothingToClaim)]
fun second_ancestor_claim_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (root_ip, root_cap_id) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (child_ip, _) = make_child(&mut s, BOB, root_ip, terms_id, 0, 2, &clock);
    pay_royalty(&mut s, CAROL, child_ip, 1_000, &clock);
    claim_ancestor(&mut s, ALICE, child_ip, root_cap_id);
    claim_ancestor(&mut s, ALICE, child_ip, root_cap_id);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::ip::ENothingToClaim)]
fun owner_claim_with_empty_pool_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, cap_id) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    claim_owner(&mut s, ALICE, ip_id, cap_id);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::ip::ENotOwner)]
fun owner_claim_with_wrong_cap_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (alice_ip, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (_, bob_cap_id) = root(&mut s, BOB, 2, &clock);
    pay_royalty(&mut s, CAROL, alice_ip, 1_000, &clock);
    claim_owner(&mut s, BOB, alice_ip, bob_cap_id);
    abort 99
}

/// A stranger's cap is not an ancestor's cap.
#[test]
#[expected_failure(abort_code = haneul_ip::royalty::ENotAncestor)]
fun ancestor_claim_by_non_ancestor_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (root_ip, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (child_ip, _) = make_child(&mut s, BOB, root_ip, terms_id, 0, 2, &clock);
    let (_, stranger_cap_id) = root(&mut s, CAROL, 3, &clock);
    pay_royalty(&mut s, ADMIN, child_ip, 1_000, &clock);
    claim_ancestor(&mut s, CAROL, child_ip, stranger_cap_id);
    abort 99
}

/// The anti-junk gate: a coin type the IP never opted into cannot
/// create a pool on it.
#[test]
#[expected_failure(abort_code = haneul_ip::ip::ECurrencyNotAccepted)]
fun payment_in_unaccepted_currency_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);

    s.next_tx(CAROL);
    let cfg = s.take_shared<ProtocolConfig>();
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    let junk = haneul::coin::mint_for_testing<USDX>(1, s.ctx());
    royalty::pay<USDX>(&cfg, &mut asset, junk, &clock, s.ctx());
    abort 99
}

/// Stopping a currency blocks new deposits but never claims: funds
/// already in the pool stay withdrawable.
#[test]
fun stopped_currency_stays_claimable() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, cap_id) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    pay_royalty(&mut s, CAROL, ip_id, 1_000, &clock);

    s.next_tx(ALICE);
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    let cap = s.take_from_sender_by_id<IPOwnerCap>(cap_id);
    ip::stop_accepting_currency<HANEUL>(&mut asset, &cap);
    assert!(!ip::is_currency_accepted<HANEUL>(&asset));
    ts::return_shared(asset);
    s.return_to_sender(cap);

    assert!(claim_owner(&mut s, ALICE, ip_id, cap_id) == 1_000);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = haneul_ip::royalty::EZeroPayment)]
fun zero_payment_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    pay_royalty(&mut s, CAROL, ip_id, 0, &clock);
    abort 99
}

/// Tag freezes inflows...
#[test]
#[expected_failure(abort_code = haneul_ip::ip::ETagged)]
fun payment_to_tagged_ip_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    tag_ip(&mut s, ip_id, 9, &clock);
    pay_royalty(&mut s, CAROL, ip_id, 1_000, &clock);
    abort 99
}

/// ...and claims.
#[test]
#[expected_failure(abort_code = haneul_ip::ip::ETagged)]
fun claim_from_tagged_ip_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, cap_id) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    pay_royalty(&mut s, CAROL, ip_id, 1_000, &clock);
    tag_ip(&mut s, ip_id, 9, &clock);
    claim_owner(&mut s, ALICE, ip_id, cap_id);
    abort 99
}

// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Tests for `haneul_ip::derivative`: the hot-potato builder, the
/// royalty-graph merge, the reciprocal and approval rules, and the
/// product bounds.
#[test_only]
module haneul_ip::derivative_tests;

use haneul::clock::Clock;
use haneul::haneul::HANEUL;
use haneul::test_scenario::{Self as ts, Scenario};
use haneul_ip::derivative;
use haneul_ip::ip::{Self, IPAsset, IPOwnerCap};
use haneul_ip::license::{Self, License};
use haneul_ip::protocol::ProtocolConfig;
use haneul_ip::terms::TermsRegistry;
use haneul_ip::test_helpers::{
    str,
    hash,
    new_clock,
    setup,
    stale_config,
    std_terms,
    free_terms,
    custom_terms,
    root_with_terms,
    mint_license_to,
    mint_haneul,
    make_child,
    approve,
};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CAROL: address = @0xCA401;

/// Builds a linear chain of `depth` IPs under `terms_id` (a root plus
/// depth - 1 generations of derivatives), consuming content-hash
/// seeds sequentially from `seed`. Returns the tip's ip id. A tip at
/// depth d carries d - 1 ancestor entries.
fun chain(s: &mut Scenario, terms_id: u64, depth: u8, seed: u8, clock: &Clock): ID {
    let (mut tip, _) = root_with_terms(s, ALICE, seed, terms_id, clock);
    let mut i: u8 = 1;
    while (i < depth) {
        let (child, _) = make_child(s, ALICE, tip, terms_id, 0, seed + i, clock);
        tip = child;
        i = i + 1;
    };
    tip
}

/// Direct-path link helper: builder with one parent via
/// `add_parent_direct`, finished immediately.
fun make_child_direct(
    s: &mut Scenario,
    creator: address,
    parent_ip: ID,
    terms_id: u64,
    pay_amount: u64,
    max_fee: u64,
    max_stack: u64,
    seed: u8,
    clock: &Clock,
): (ID, ID) {
    s.next_tx(creator);
    let cfg = s.take_shared<ProtocolConfig>();
    let reg = s.take_shared<TermsRegistry>();
    let mut parent = s.take_shared_by_id<IPAsset>(parent_ip);
    let mut payment = mint_haneul(s, pay_amount);
    let mut builder = derivative::begin(str(b"child"), hash(seed), str(b""));
    derivative::add_parent_direct<HANEUL>(
        &mut builder,
        &mut parent,
        &reg,
        &cfg,
        terms_id,
        &mut payment,
        max_fee,
        clock,
        s.ctx(),
    );
    let cap = derivative::finish(builder, &cfg, max_stack, clock, s.ctx());
    let child_ip = ip::cap_ip(&cap);
    let cap_id = object::id(&cap);
    transfer::public_transfer(cap, creator);
    transfer::public_transfer(payment, creator);
    ts::return_shared(cfg);
    ts::return_shared(reg);
    ts::return_shared(parent);
    (child_ip, cap_id)
}

#[test]
fun license_path_links_parent_and_merges_royalty() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (root_ip, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (child_ip, _) = make_child(&mut s, BOB, root_ip, terms_id, 0, 2, &clock);

    s.next_tx(BOB);
    let child = s.take_shared_by_id<IPAsset>(child_ip);
    assert!(child.is_derivative());
    assert!(child.parents().length() == 1);
    assert!(child.is_ancestor_of(root_ip));
    assert!(child.ancestor_share_bps(root_ip) == 1_000);
    assert!(child.royalty_stack_bps() == 1_000);
    // The reciprocal rule: the child carries the terms it was born under.
    assert!(child.has_terms(terms_id));
    ts::return_shared(child);

    let parent = s.take_shared_by_id<IPAsset>(root_ip);
    assert!(parent.derivatives_registered() == 1);
    ts::return_shared(parent);
    clock.destroy_for_testing();
    s.end();
}

/// Direct path: minting fee flows into the parent pool during link.
#[test]
fun direct_path_pays_fee_and_links() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 100);
    let (root_ip, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (child_ip, _) =
        make_child_direct(&mut s, BOB, root_ip, terms_id, 100, 0, 0, 2, &clock);

    s.next_tx(BOB);
    let child = s.take_shared_by_id<IPAsset>(child_ip);
    assert!(child.ancestor_share_bps(root_ip) == 1_000);
    ts::return_shared(child);
    let parent = s.take_shared_by_id<IPAsset>(root_ip);
    assert!(ip::claimable_by_owner<HANEUL>(&parent) == 100);
    ts::return_shared(parent);
    clock.destroy_for_testing();
    s.end();
}

/// The ancestor merge, exercised over three generations: a payment
/// obligation to the root must carry through the child into the
/// grandchild, absolute and unchanged.
#[test]
fun grandchild_inherits_absolute_ancestor_shares() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let root_terms = std_terms(&mut s, 1_000, 0);
    let (root_ip, _) = root_with_terms(&mut s, ALICE, 1, root_terms, &clock);
    let (child_ip, _) = make_child(&mut s, BOB, root_ip, root_terms, 0, 2, &clock);
    // Reciprocity fixes the chain's terms: the grandchild registers
    // under the same terms the child was born with.
    let (grandchild_ip, _) = make_child(&mut s, CAROL, child_ip, root_terms, 0, 3, &clock);

    s.next_tx(CAROL);
    let grandchild = s.take_shared_by_id<IPAsset>(grandchild_ip);
    // Direct parent edge at 10%, plus the root's 10% share in the
    // child carried through unchanged.
    assert!(grandchild.ancestor_share_bps(child_ip) == 1_000);
    assert!(grandchild.ancestor_share_bps(root_ip) == 1_000);
    assert!(grandchild.royalty_stack_bps() == 2_000);
    assert!(grandchild.parents().length() == 1);
    ts::return_shared(grandchild);
    clock.destroy_for_testing();
    s.end();
}

/// A license minted from IP A cannot link IP B as a parent.
#[test]
#[expected_failure(abort_code = haneul_ip::derivative::EWrongLicense)]
fun license_from_other_ip_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_a, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (ip_b, _) = root_with_terms(&mut s, ALICE, 2, terms_id, &clock);
    mint_license_to(&mut s, BOB, ip_a, terms_id, 0, &clock);

    s.next_tx(BOB);
    let reg = s.take_shared<TermsRegistry>();
    let mut wrong_parent = s.take_shared_by_id<IPAsset>(ip_b);
    let license = s.take_from_sender<License>();
    let mut builder = derivative::begin(str(b"x"), hash(9), str(b""));
    derivative::add_parent(&mut builder, &mut wrong_parent, &reg, license, &clock);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::derivative::EDuplicateParent)]
fun same_parent_twice_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (root_ip, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    mint_license_to(&mut s, BOB, root_ip, terms_id, 0, &clock);
    mint_license_to(&mut s, BOB, root_ip, terms_id, 0, &clock);

    s.next_tx(BOB);
    let reg = s.take_shared<TermsRegistry>();
    let mut parent = s.take_shared_by_id<IPAsset>(root_ip);
    let first = s.take_from_sender<License>();
    let second = s.take_from_sender<License>();
    let mut builder = derivative::begin(str(b"x"), hash(9), str(b""));
    derivative::add_parent(&mut builder, &mut parent, &reg, first, &clock);
    derivative::add_parent(&mut builder, &mut parent, &reg, second, &clock);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::derivative::ENoParents)]
fun finish_without_parents_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    s.next_tx(BOB);
    let cfg = s.take_shared<ProtocolConfig>();
    let builder = derivative::begin(str(b"x"), hash(9), str(b""));
    let cap = derivative::finish(builder, &cfg, 0, &clock, s.ctx());
    transfer::public_transfer(cap, BOB);
    abort 99
}

/// Two parents at 60% each: a 120% royalty burden cannot exist.
#[test]
#[expected_failure(abort_code = haneul_ip::derivative::EStackTooHigh)]
fun combined_stack_above_100_percent_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let heavy_terms = std_terms(&mut s, 6_000, 0);
    let (ip_a, _) = root_with_terms(&mut s, ALICE, 1, heavy_terms, &clock);
    let (ip_b, _) = root_with_terms(&mut s, ALICE, 2, heavy_terms, &clock);
    mint_license_to(&mut s, BOB, ip_a, heavy_terms, 0, &clock);
    mint_license_to(&mut s, BOB, ip_b, heavy_terms, 0, &clock);

    s.next_tx(BOB);
    let cfg = s.take_shared<ProtocolConfig>();
    let reg = s.take_shared<TermsRegistry>();
    let mut parent_a = s.take_shared_by_id<IPAsset>(ip_a);
    let mut parent_b = s.take_shared_by_id<IPAsset>(ip_b);
    // take_from_sender is LIFO; pair each license with its licensor.
    let la = s.take_from_sender<License>();
    let lb = s.take_from_sender<License>();
    let (first, second) = if (license::licensor(&la) == ip_a) (la, lb) else (lb, la);
    let mut builder = derivative::begin(str(b"x"), hash(9), str(b""));
    derivative::add_parent(&mut builder, &mut parent_a, &reg, first, &clock);
    derivative::add_parent(&mut builder, &mut parent_b, &reg, second, &clock);
    let cap = derivative::finish(builder, &cfg, 0, &clock, s.ctx());
    transfer::public_transfer(cap, BOB);
    abort 99
}

/// Slippage guard on the total burden: registrant agreed to at most
/// 5%, the terms turned out to cost 10%.
#[test]
#[expected_failure(abort_code = haneul_ip::derivative::EStackAboveMax)]
fun stack_above_registrant_max_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (root_ip, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    mint_license_to(&mut s, BOB, root_ip, terms_id, 0, &clock);

    s.next_tx(BOB);
    let cfg = s.take_shared<ProtocolConfig>();
    let reg = s.take_shared<TermsRegistry>();
    let mut parent = s.take_shared_by_id<IPAsset>(root_ip);
    let license = s.take_from_sender<License>();
    let mut builder = derivative::begin(str(b"x"), hash(9), str(b""));
    derivative::add_parent(&mut builder, &mut parent, &reg, license, &clock);
    let cap = derivative::finish(builder, &cfg, 500, &clock, s.ctx());
    transfer::public_transfer(cap, BOB);
    abort 99
}

/// A license can exist for usage terms; using it to LINK requires
/// derivatives_allowed.
#[test]
#[expected_failure(abort_code = haneul_ip::derivative::EDerivativesNotAllowed)]
fun linking_no_derivatives_terms_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let usage_only = custom_terms(&mut s, true, 0, true, 0, false, false, false, 0);
    let (root_ip, _) = root_with_terms(&mut s, ALICE, 1, usage_only, &clock);
    mint_license_to(&mut s, BOB, root_ip, usage_only, 0, &clock);

    s.next_tx(BOB);
    let reg = s.take_shared<TermsRegistry>();
    let mut parent = s.take_shared_by_id<IPAsset>(root_ip);
    let license = s.take_from_sender<License>();
    let mut builder = derivative::begin(str(b"x"), hash(9), str(b""));
    derivative::add_parent(&mut builder, &mut parent, &reg, license, &clock);
    abort 99
}

/// Approval-gated terms block the direct (no-license) path for an
/// unapproved registrant, before any money moves.
#[test]
#[expected_failure(abort_code = haneul_ip::derivative::ENotApprovedLicensee)]
fun approval_terms_block_unapproved_direct_link() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let approval_terms = custom_terms(&mut s, false, 0, true, 1_000, true, true, true, 0);
    let (root_ip, _) = root_with_terms(&mut s, ALICE, 1, approval_terms, &clock);
    make_child_direct(&mut s, BOB, root_ip, approval_terms, 0, 0, 0, 9, &clock);
    abort 99
}

/// The approval flow, two single-signer transactions: the owner puts
/// the licensee on the allowlist first, then the licensee buys and
/// registers in one transaction of their own.
#[test]
fun approved_licensee_buys_and_links_in_one_tx() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let approval_terms = custom_terms(&mut s, false, 0, true, 1_000, true, true, true, 0);
    let (root_ip, root_cap_id) = root_with_terms(&mut s, ALICE, 1, approval_terms, &clock);

    approve(&mut s, ALICE, root_ip, root_cap_id, BOB);
    // make_child is mint -> add_parent -> finish in one transaction.
    let (child_ip, _) = make_child(&mut s, BOB, root_ip, approval_terms, 0, 9, &clock);

    s.next_tx(BOB);
    let child = s.take_shared_by_id<IPAsset>(child_ip);
    assert!(child.is_ancestor_of(root_ip));
    ts::return_shared(child);
    clock.destroy_for_testing();
    s.end();
}

/// The child inherits its terms' currency as an accepted revenue
/// currency; everything else stays locked out.
#[test]
fun child_inherits_terms_currency() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (root_ip, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (child_ip, _) = make_child(&mut s, BOB, root_ip, terms_id, 0, 2, &clock);

    s.next_tx(BOB);
    let child = s.take_shared_by_id<IPAsset>(child_ip);
    assert!(ip::is_currency_accepted<HANEUL>(&child));
    assert!(!ip::is_currency_accepted<haneul_ip::test_helpers::USDX>(&child));
    ts::return_shared(child);
    clock.destroy_for_testing();
    s.end();
}

/// Non-reciprocal terms: root -> child is fine, child -> grandchild
/// is not (the direct path fails inside `link`).
#[test]
#[expected_failure(abort_code = haneul_ip::derivative::ENotReciprocal)]
fun grandchild_of_non_reciprocal_terms_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let one_shot = custom_terms(&mut s, true, 0, true, 1_000, true, false, false, 0);
    let (root_ip, _) = root_with_terms(&mut s, ALICE, 1, one_shot, &clock);
    let (child_ip, _) = make_child(&mut s, BOB, root_ip, one_shot, 0, 2, &clock);
    make_child_direct(&mut s, CAROL, child_ip, one_shot, 0, 0, 0, 3, &clock);
    abort 99
}

/// Terms with a lifetime: the child expires, and an expired IP can no
/// longer be linked as a parent.
#[test]
#[expected_failure(abort_code = haneul_ip::ip::EExpired)]
fun linking_expired_parent_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let mut clock = new_clock(&mut s);
    let timed_terms = custom_terms(&mut s, true, 1_000_000, true, 1_000, true, false, true, 0);
    let (root_ip, _) = root_with_terms(&mut s, ALICE, 1, timed_terms, &clock);
    let (child_ip, _) = make_child(&mut s, BOB, root_ip, timed_terms, 0, 2, &clock);

    s.next_tx(BOB);
    let child = s.take_shared_by_id<IPAsset>(child_ip);
    assert!(child.expires_at_ms() == 1_000_000);
    ts::return_shared(child);

    clock.increment_for_testing(1_000_001);
    make_child_direct(&mut s, CAROL, child_ip, timed_terms, 0, 0, 0, 3, &clock);
    abort 99
}

/// The merge stays sound all the way to the bound: a chain of depth
/// 33 gives its tip exactly MAX_ANCESTORS (32) entries. Free terms
/// keep the royalty stack at zero so only the ancestor count is
/// exercised.
#[test]
fun ancestor_chain_reaches_the_bound() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = free_terms(&mut s);
    let tip = chain(&mut s, terms_id, 33, 1, &clock);

    s.next_tx(ALICE);
    let asset = s.take_shared_by_id<IPAsset>(tip);
    assert!(ip::ancestors(&asset).length() == derivative::max_ancestors());
    ts::return_shared(asset);
    clock.destroy_for_testing();
    s.end();
}

/// One generation past the bound: linking a tip that already carries
/// 32 ancestors would give the child 33 entries.
#[test]
#[expected_failure(abort_code = haneul_ip::derivative::ETooManyAncestors)]
fun thirty_third_ancestor_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = free_terms(&mut s);
    let tip = chain(&mut s, terms_id, 33, 1, &clock);
    make_child(&mut s, BOB, tip, terms_id, 0, 100, &clock);
    abort 99
}

/// The hot potato commits through `finish`, so the version gate there
/// covers the whole builder sequence: a license minted before the
/// upgrade cannot slip a registration past the gate.
#[test]
#[expected_failure(abort_code = haneul_ip::protocol::EWrongVersion)]
fun stale_version_blocks_finish() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = free_terms(&mut s);
    let (root_ip, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    mint_license_to(&mut s, BOB, root_ip, terms_id, 0, &clock);
    stale_config(&mut s);

    s.next_tx(BOB);
    let cfg = s.take_shared<ProtocolConfig>();
    let reg = s.take_shared<TermsRegistry>();
    let mut parent = s.take_shared_by_id<IPAsset>(root_ip);
    let license = s.take_from_sender<License>();
    let mut builder = derivative::begin(str(b"x"), hash(9), str(b""));
    derivative::add_parent(&mut builder, &mut parent, &reg, license, &clock);
    let cap = derivative::finish(builder, &cfg, 0, &clock, s.ctx());
    transfer::public_transfer(cap, BOB);
    abort 99
}

/// MAX_PARENTS is enforced on the builder: the 9th add aborts.
#[test]
#[expected_failure(abort_code = haneul_ip::derivative::ETooManyParents)]
fun ninth_parent_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = free_terms(&mut s);

    let mut parent_ids = vector<ID>[];
    let mut seed: u8 = 1;
    while (seed <= 9) {
        let (parent_ip, _) = root_with_terms(&mut s, ALICE, seed, terms_id, &clock);
        parent_ids.push_back(parent_ip);
        seed = seed + 1;
    };

    s.next_tx(BOB);
    let cfg = s.take_shared<ProtocolConfig>();
    let reg = s.take_shared<TermsRegistry>();
    let mut payment = mint_haneul(&mut s, 0);
    let mut builder = derivative::begin(str(b"crowded"), hash(99), str(b""));
    let mut i = 0;
    while (i < 9) {
        let mut parent = s.take_shared_by_id<IPAsset>(parent_ids[i]);
        derivative::add_parent_direct<HANEUL>(
            &mut builder,
            &mut parent,
            &reg,
            &cfg,
            terms_id,
            &mut payment,
            0,
            &clock,
            s.ctx(),
        );
        ts::return_shared(parent);
        i = i + 1;
    };
    abort 99
}

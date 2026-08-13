// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Tests for `haneul_ip::dispute`: the raise/judge/resolve lifecycle,
/// evidence rules, propagation down the derivative tree, and the
/// money-freeze integration (covered from the money side in
/// royalty/license tests; covered from the dispute side here).
#[test_only]
module haneul_ip::dispute_tests;

use haneul::clock::Clock;
use haneul::test_scenario::{Self as ts, Scenario};
use haneul_ip::dispute::{Self, DisputeRegistry};
use haneul_ip::ip::{Self, IPAsset};
use haneul_ip::protocol::ProtocolCap;
use haneul_ip::test_helpers::{
    str,
    hash,
    new_clock,
    setup,
    setup_tag,
    tag_ip,
    std_terms,
    root_with_terms,
    make_child,
    pay_royalty,
};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CAROL: address = @0xCA401;


fun raise_as(
    s: &mut Scenario,
    initiator: address,
    ip_id: ID,
    evidence_seed: u8,
    clock: &Clock,
): u64 {
    s.next_tx(initiator);
    let mut reg = s.take_shared<DisputeRegistry>();
    let asset = s.take_shared_by_id<IPAsset>(ip_id);
    let dispute_id =
        dispute::raise(&mut reg, &asset, hash(evidence_seed), str(b"PLAGIARISM"), clock, s.ctx());
    ts::return_shared(asset);
    ts::return_shared(reg);
    dispute_id
}

fun judge_as(s: &mut Scenario, judge: address, ip_id: ID, dispute_id: u64, uphold: bool) {
    s.next_tx(judge);
    let mut reg = s.take_shared<DisputeRegistry>();
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    dispute::judge(&mut reg, &mut asset, dispute_id, uphold, s.ctx());
    ts::return_shared(asset);
    ts::return_shared(reg);
}

fun resolve_as(s: &mut Scenario, resolver: address, ip_id: ID, dispute_id: u64) {
    s.next_tx(resolver);
    let mut reg = s.take_shared<DisputeRegistry>();
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    dispute::resolve(&mut reg, &mut asset, dispute_id, s.ctx());
    ts::return_shared(asset);
    ts::return_shared(reg);
}

fun propagate_as(
    s: &mut Scenario,
    caller: address,
    child_ip: ID,
    source_id: u64,
    clock: &Clock,
): u64 {
    s.next_tx(caller);
    let mut reg = s.take_shared<DisputeRegistry>();
    let mut child = s.take_shared_by_id<IPAsset>(child_ip);
    let id = dispute::propagate(&mut reg, &mut child, source_id, clock, s.ctx());
    ts::return_shared(child);
    ts::return_shared(reg);
    id
}

fun assert_tagged(s: &mut Scenario, ip_id: ID, expected: bool) {
    s.next_tx(ADMIN);
    let asset = s.take_shared_by_id<IPAsset>(ip_id);
    assert!(ip::is_tagged(&asset) == expected);
    ts::return_shared(asset);
}

#[test]
fun uphold_tags_and_resolve_untags() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);

    let dispute_id = raise_as(&mut s, CAROL, ip_id, 9, &clock);
    assert_tagged(&mut s, ip_id, false);
    judge_as(&mut s, ADMIN, ip_id, dispute_id, true);
    assert_tagged(&mut s, ip_id, true);

    resolve_as(&mut s, CAROL, ip_id, dispute_id);
    assert_tagged(&mut s, ip_id, false);
    // The freeze lifts with the tag: payments flow again.
    pay_royalty(&mut s, BOB, ip_id, 1_000, &clock);

    s.next_tx(ADMIN);
    let reg = s.take_shared<DisputeRegistry>();
    assert!(dispute::state(&reg, dispute_id) == dispute::resolved());
    ts::return_shared(reg);
    clock.destroy_for_testing();
    s.end();
}

#[test]
fun dismissal_leaves_ip_untagged() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);

    let dispute_id = raise_as(&mut s, CAROL, ip_id, 9, &clock);
    judge_as(&mut s, ADMIN, ip_id, dispute_id, false);
    assert_tagged(&mut s, ip_id, false);

    s.next_tx(ADMIN);
    let reg = s.take_shared<DisputeRegistry>();
    assert!(dispute::state(&reg, dispute_id) == dispute::dismissed());
    ts::return_shared(reg);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = haneul_ip::dispute::ENotArbiter)]
fun non_arbiter_judging_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let dispute_id = raise_as(&mut s, CAROL, ip_id, 9, &clock);
    judge_as(&mut s, BOB, ip_id, dispute_id, true);
    abort 99
}

#[test]
fun new_arbiter_can_judge() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);

    s.next_tx(ADMIN);
    let mut reg = s.take_shared<DisputeRegistry>();
    let cap = s.take_from_sender<ProtocolCap>();
    dispute::set_arbiter(&mut reg, &cap, BOB);
    s.return_to_sender(cap);
    ts::return_shared(reg);

    let dispute_id = raise_as(&mut s, CAROL, ip_id, 9, &clock);
    judge_as(&mut s, BOB, ip_id, dispute_id, true);
    assert_tagged(&mut s, ip_id, true);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = haneul_ip::dispute::ETagNotAllowed)]
fun unallowed_tag_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    // no setup_tag: the whitelist is empty
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    raise_as(&mut s, CAROL, ip_id, 9, &clock);
    abort 99
}

/// One piece of evidence backs at most one dispute per target
/// (anti-spam): re-filing the same evidence against the same IP is
/// blocked even after the first dispute is dismissed.
#[test]
#[expected_failure(abort_code = haneul_ip::dispute::EEvidenceUsed)]
fun reused_evidence_same_target_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let dispute_id = raise_as(&mut s, CAROL, ip_id, 9, &clock);
    judge_as(&mut s, ADMIN, ip_id, dispute_id, false);
    raise_as(&mut s, CAROL, ip_id, 9, &clock);
    abort 99
}

/// Uniqueness is scoped per target: one work plagiarized by two
/// parties is two targets, each disputable with the same evidence.
#[test]
fun same_evidence_different_targets_allowed() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_a, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (ip_b, _) = root_with_terms(&mut s, BOB, 2, terms_id, &clock);
    let dispute_a = raise_as(&mut s, CAROL, ip_a, 9, &clock);
    let dispute_b = raise_as(&mut s, CAROL, ip_b, 9, &clock);

    s.next_tx(ADMIN);
    let reg = s.take_shared<DisputeRegistry>();
    assert!(dispute::state(&reg, dispute_a) == dispute::in_dispute());
    assert!(dispute::state(&reg, dispute_b) == dispute::in_dispute());
    ts::return_shared(reg);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = haneul_ip::dispute::EBadEvidence)]
fun short_evidence_hash_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);

    s.next_tx(CAROL);
    let mut reg = s.take_shared<DisputeRegistry>();
    let asset = s.take_shared_by_id<IPAsset>(ip_id);
    let mut short_evidence = hash(9);
    short_evidence.pop_back();
    dispute::raise(&mut reg, &asset, short_evidence, str(b"PLAGIARISM"), &clock, s.ctx());
    abort 99
}

#[test]
fun initiator_can_cancel_before_judgement() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let dispute_id = raise_as(&mut s, CAROL, ip_id, 9, &clock);

    s.next_tx(CAROL);
    let mut reg = s.take_shared<DisputeRegistry>();
    dispute::cancel(&mut reg, dispute_id, s.ctx());
    assert!(dispute::state(&reg, dispute_id) == dispute::cancelled());
    ts::return_shared(reg);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = haneul_ip::dispute::ENotInitiator)]
fun cancel_by_stranger_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let dispute_id = raise_as(&mut s, CAROL, ip_id, 9, &clock);

    s.next_tx(BOB);
    let mut reg = s.take_shared<DisputeRegistry>();
    dispute::cancel(&mut reg, dispute_id, s.ctx());
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::dispute::ENotInDispute)]
fun cancel_after_judgement_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let dispute_id = raise_as(&mut s, CAROL, ip_id, 9, &clock);
    judge_as(&mut s, ADMIN, ip_id, dispute_id, true);

    s.next_tx(CAROL);
    let mut reg = s.take_shared<DisputeRegistry>();
    dispute::cancel(&mut reg, dispute_id, s.ctx());
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::dispute::ENotInitiator)]
fun resolve_by_stranger_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let dispute_id = tag_ip(&mut s, ip_id, 9, &clock);
    resolve_as(&mut s, BOB, ip_id, dispute_id);
    abort 99
}

/// The arbiter can lift a tag it upheld: a settled target must not
/// stay frozen because the initiator lost their key or refuses to
/// act, and the judging authority must be able to reverse itself.
#[test]
fun arbiter_can_resolve_original_dispute() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let dispute_id = raise_as(&mut s, CAROL, ip_id, 9, &clock);
    judge_as(&mut s, ADMIN, ip_id, dispute_id, true);
    assert_tagged(&mut s, ip_id, true);

    // ADMIN is the arbiter, not the initiator (CAROL raised it).
    resolve_as(&mut s, ADMIN, ip_id, dispute_id);
    assert_tagged(&mut s, ip_id, false);

    s.next_tx(ADMIN);
    let reg = s.take_shared<DisputeRegistry>();
    assert!(dispute::state(&reg, dispute_id) == dispute::resolved());
    ts::return_shared(reg);
    clock.destroy_for_testing();
    s.end();
}

/// Propagation: an upheld tag on the root extends to a derivative,
/// permissionlessly, and freezes it.
#[test]
fun propagation_tags_descendant() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let mut clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (root_ip, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (child_ip, _) = make_child(&mut s, BOB, root_ip, terms_id, 0, 2, &clock);
    let source_id = tag_ip(&mut s, root_ip, 9, &clock);

    // Anyone (CAROL) can propagate; the propagation moment is
    // recorded as the new dispute's raise time.
    clock.set_for_testing(7_000);
    let propagated_id = propagate_as(&mut s, CAROL, child_ip, source_id, &clock);
    assert_tagged(&mut s, child_ip, true);

    s.next_tx(ADMIN);
    let reg = s.take_shared<DisputeRegistry>();
    assert!(dispute::state(&reg, propagated_id) == dispute::upheld());
    assert!(dispute::raised_at_ms(&reg, propagated_id) == 7_000);
    ts::return_shared(reg);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = haneul_ip::dispute::ENotDescendant)]
fun propagation_to_unrelated_ip_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (root_ip, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (stranger_ip, _) = root_with_terms(&mut s, BOB, 2, terms_id, &clock);
    let source_id = tag_ip(&mut s, root_ip, 9, &clock);
    propagate_as(&mut s, CAROL, stranger_ip, source_id, &clock);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::dispute::EAlreadyPropagated)]
fun double_propagation_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (root_ip, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (child_ip, _) = make_child(&mut s, BOB, root_ip, terms_id, 0, 2, &clock);
    let source_id = tag_ip(&mut s, root_ip, 9, &clock);
    propagate_as(&mut s, CAROL, child_ip, source_id, &clock);
    propagate_as(&mut s, CAROL, child_ip, source_id, &clock);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::dispute::ENotUpheld)]
fun propagation_from_dismissed_dispute_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (root_ip, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (child_ip, _) = make_child(&mut s, BOB, root_ip, terms_id, 0, 2, &clock);
    let dispute_id = raise_as(&mut s, CAROL, root_ip, 9, &clock);
    judge_as(&mut s, ADMIN, root_ip, dispute_id, false);
    propagate_as(&mut s, CAROL, child_ip, dispute_id, &clock);
    abort 99
}

/// A propagated tag cannot be lifted while the source stays upheld.
#[test]
#[expected_failure(abort_code = haneul_ip::dispute::ESourceNotClosed)]
fun resolving_propagated_before_source_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (root_ip, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (child_ip, _) = make_child(&mut s, BOB, root_ip, terms_id, 0, 2, &clock);
    let source_id = tag_ip(&mut s, root_ip, 9, &clock);
    let propagated_id = propagate_as(&mut s, CAROL, child_ip, source_id, &clock);
    resolve_as(&mut s, BOB, child_ip, propagated_id);
    abort 99
}

/// Once the source resolves, the propagated tag lifts permissionlessly.
#[test]
fun resolving_propagated_after_source_closes() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (root_ip, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let (child_ip, _) = make_child(&mut s, BOB, root_ip, terms_id, 0, 2, &clock);
    let source_id = tag_ip(&mut s, root_ip, 9, &clock);
    let propagated_id = propagate_as(&mut s, CAROL, child_ip, source_id, &clock);

    // ADMIN raised the source dispute in tag_ip, so ADMIN resolves it.
    resolve_as(&mut s, ADMIN, root_ip, source_id);
    // Now anyone can lift the child's tag.
    resolve_as(&mut s, BOB, child_ip, propagated_id);
    assert_tagged(&mut s, child_ip, false);
    assert_tagged(&mut s, root_ip, false);
    clock.destroy_for_testing();
    s.end();
}

/// The registry gates its lifecycle entry points on the package
/// version.
#[test]
#[expected_failure(abort_code = haneul_ip::dispute::EWrongVersion)]
fun stale_registry_version_blocks_raise() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);

    s.next_tx(ADMIN);
    let mut reg = s.take_shared<DisputeRegistry>();
    dispute::set_version_for_testing(&mut reg, 0);
    ts::return_shared(reg);

    raise_as(&mut s, CAROL, ip_id, 9, &clock);
    abort 99
}

#[test]
fun migrate_bumps_stale_registry() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    s.next_tx(ADMIN);
    let mut reg = s.take_shared<DisputeRegistry>();
    let cap = s.take_from_sender<ProtocolCap>();
    dispute::set_version_for_testing(&mut reg, 0);
    dispute::migrate(&mut reg, &cap);
    assert!(dispute::version(&reg) == 1);
    s.return_to_sender(cap);
    ts::return_shared(reg);
    s.end();
}

#[test]
#[expected_failure(abort_code = haneul_ip::dispute::ENotUpgrade)]
fun migrate_at_current_version_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    s.next_tx(ADMIN);
    let mut reg = s.take_shared<DisputeRegistry>();
    let cap = s.take_from_sender<ProtocolCap>();
    dispute::migrate(&mut reg, &cap);
    abort 99
}

/// Belt-and-suspenders: state constants in this file match the
/// module's lifecycle (a raise starts IN_DISPUTE).
#[test]
fun raise_starts_in_dispute_state() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    setup_tag(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    let dispute_id = raise_as(&mut s, CAROL, ip_id, 9, &clock);

    s.next_tx(ADMIN);
    let reg = s.take_shared<DisputeRegistry>();
    assert!(dispute::state(&reg, dispute_id) == dispute::in_dispute());
    ts::return_shared(reg);
    clock.destroy_for_testing();
    s.end();
}

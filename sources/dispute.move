// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Disputes: the enforcement layer. Registration is self-attested,
/// so this module is what makes a false attestation expensive.
///
/// A dispute never touches content (content is off-chain by design);
/// an upheld dispute tags the target IP, and the tag freezes the
/// money: licensing, linking, payments and claims all check it.
/// Rights are data, enforcement is a money switch.
///
/// Behaviors:
///  - whitelisted tags, evidence-hash uniqueness (anti-spam),
///  - propagation: once an IP is tagged, ANYONE may extend the tag to
///    its descendants (the derivative tree monetizes the infringing
///    work, so it freezes with it),
///  - propagated tags resolve permissionlessly once the source
///    dispute is closed; original tags resolve by their initiator.
///
/// v1 simplification: judgement is a single arbiter address. Bonded,
/// optimistic arbitration is the known upgrade path; it slots in
/// behind `judge` without changing state.
module haneul_ip::dispute;

use haneul::clock::Clock;
use haneul::event;
use haneul::table::{Self, Table};
use haneul::vec_set::{Self, VecSet};
use haneul_ip::ip::{Self, IPAsset};
use haneul_ip::protocol::ProtocolCap;
use std::bcs;
use std::string::String;

const ENotArbiter: u64 = 0;
const ETagNotAllowed: u64 = 1;
const EBadEvidence: u64 = 2;
const EEvidenceUsed: u64 = 3;
const ENotInDispute: u64 = 4;
const EWrongTarget: u64 = 5;
const ENotInitiator: u64 = 6;
const ENotUpheld: u64 = 7;
const ENotDescendant: u64 = 8;
const EAlreadyPropagated: u64 = 9;
const ESourceNotClosed: u64 = 10;
const EDisputeNotFound: u64 = 11;

const STATE_IN_DISPUTE: u8 = 0;
const STATE_UPHELD: u8 = 1;
const STATE_DISMISSED: u8 = 2;
const STATE_CANCELLED: u8 = 3;
const STATE_RESOLVED: u8 = 4;

const EVIDENCE_HASH_LENGTH: u64 = 32;

public struct DisputeRegistry has key {
    id: UID,
    version: u64,
    /// Sole judgement authority for v1.
    arbiter: address,
    /// Whitelisted dispute tags (e.g. "PLAGIARISM").
    tags: VecSet<String>,
    disputes: Table<u64, Dispute>,
    /// Evidence may back at most one dispute (anti-spam).
    used_evidence: Table<vector<u8>, bool>,
    /// bcs(child, source_dispute) -> already propagated.
    propagated: Table<vector<u8>, bool>,
    /// Ids start at 1.
    count: u64,
}

public struct Dispute has store {
    target: ID,
    initiator: address,
    /// 32-byte hash of off-chain evidence.
    evidence_hash: vector<u8>,
    tag: String,
    state: u8,
    /// 0 for an original dispute; the source dispute id when this tag
    /// was propagated down the derivative tree.
    source: u64,
    raised_at_ms: u64,
}

public struct DisputeRaised has copy, drop {
    dispute_id: u64,
    target: ID,
    initiator: address,
    tag: String,
}

public struct DisputeJudged has copy, drop {
    dispute_id: u64,
    upheld: bool,
}

public struct DisputeCancelled has copy, drop { dispute_id: u64 }

public struct DisputePropagated has copy, drop {
    dispute_id: u64,
    source_dispute_id: u64,
    target: ID,
}

public struct DisputeResolved has copy, drop { dispute_id: u64 }

public struct ArbiterSet has copy, drop { arbiter: address }

public struct TagAllowed has copy, drop { tag: String, allowed: bool }

fun init(ctx: &mut TxContext) {
    transfer::share_object(DisputeRegistry {
        id: object::new(ctx),
        version: 1,
        arbiter: ctx.sender(),
        tags: vec_set::empty(),
        disputes: table::new(ctx),
        used_evidence: table::new(ctx),
        propagated: table::new(ctx),
        count: 0,
    });
}

// === Governance (ProtocolCap) ===

public fun set_arbiter(reg: &mut DisputeRegistry, _cap: &ProtocolCap, arbiter: address) {
    reg.arbiter = arbiter;
    event::emit(ArbiterSet { arbiter });
}

public fun allow_tag(reg: &mut DisputeRegistry, _cap: &ProtocolCap, tag: String) {
    reg.tags.insert(tag);
    event::emit(TagAllowed { tag, allowed: true });
}

public fun disallow_tag(reg: &mut DisputeRegistry, _cap: &ProtocolCap, tag: String) {
    reg.tags.remove(&tag);
    event::emit(TagAllowed { tag, allowed: false });
}

// === Lifecycle ===

/// Anyone may raise a dispute against a registered IP.
public fun raise(
    reg: &mut DisputeRegistry,
    target: &IPAsset,
    evidence_hash: vector<u8>,
    tag: String,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    assert!(reg.tags.contains(&tag), ETagNotAllowed);
    assert!(evidence_hash.length() == EVIDENCE_HASH_LENGTH, EBadEvidence);
    assert!(!reg.used_evidence.contains(evidence_hash), EEvidenceUsed);
    reg.used_evidence.add(evidence_hash, true);

    let dispute_id = reg.count + 1;
    reg.count = dispute_id;
    reg.disputes.add(dispute_id, Dispute {
        target: object::id(target),
        initiator: ctx.sender(),
        evidence_hash,
        tag,
        state: STATE_IN_DISPUTE,
        source: 0,
        raised_at_ms: clock.timestamp_ms(),
    });
    event::emit(DisputeRaised {
        dispute_id,
        target: object::id(target),
        initiator: ctx.sender(),
        tag,
    });
    dispute_id
}

/// Arbiter-only. Upholding tags the target, which freezes its money
/// paths until `resolve`.
public fun judge(
    reg: &mut DisputeRegistry,
    target: &mut IPAsset,
    dispute_id: u64,
    uphold: bool,
    ctx: &TxContext,
) {
    assert!(ctx.sender() == reg.arbiter, ENotArbiter);
    assert!(reg.disputes.contains(dispute_id), EDisputeNotFound);
    let dispute = reg.disputes.borrow_mut(dispute_id);
    assert!(dispute.state == STATE_IN_DISPUTE, ENotInDispute);
    assert!(dispute.target == object::id(target), EWrongTarget);
    if (uphold) {
        dispute.state = STATE_UPHELD;
        ip::add_tag(target);
    } else {
        dispute.state = STATE_DISMISSED;
    };
    event::emit(DisputeJudged { dispute_id, upheld: uphold });
}

/// The initiator may withdraw a dispute that has not been judged.
public fun cancel(reg: &mut DisputeRegistry, dispute_id: u64, ctx: &TxContext) {
    assert!(reg.disputes.contains(dispute_id), EDisputeNotFound);
    let dispute = reg.disputes.borrow_mut(dispute_id);
    assert!(dispute.state == STATE_IN_DISPUTE, ENotInDispute);
    assert!(ctx.sender() == dispute.initiator, ENotInitiator);
    dispute.state = STATE_CANCELLED;
    event::emit(DisputeCancelled { dispute_id });
}

/// Once a dispute is upheld, ANYONE may extend the tag to a
/// descendant of the tagged IP: the derivative monetizes the
/// infringing work, so it freezes with it. Creates a new (already
/// upheld) dispute recording the propagation.
public fun propagate(
    reg: &mut DisputeRegistry,
    child: &mut IPAsset,
    source_dispute_id: u64,
    ctx: &TxContext,
): u64 {
    assert!(reg.disputes.contains(source_dispute_id), EDisputeNotFound);
    let (source_target, source_tag, source_evidence, source_state) = {
        let source = reg.disputes.borrow(source_dispute_id);
        (source.target, source.tag, source.evidence_hash, source.state)
    };
    assert!(source_state == STATE_UPHELD, ENotUpheld);
    assert!(child.is_ancestor_of(source_target), ENotDescendant);

    let key = propagation_key(object::id(child), source_dispute_id);
    assert!(!reg.propagated.contains(key), EAlreadyPropagated);
    reg.propagated.add(key, true);

    let dispute_id = reg.count + 1;
    reg.count = dispute_id;
    reg.disputes.add(dispute_id, Dispute {
        target: object::id(child),
        initiator: ctx.sender(),
        evidence_hash: source_evidence,
        tag: source_tag,
        state: STATE_UPHELD,
        source: source_dispute_id,
        raised_at_ms: 0,
    });
    ip::add_tag(child);
    event::emit(DisputePropagated {
        dispute_id,
        source_dispute_id,
        target: object::id(child),
    });
    dispute_id
}

/// Lifts an upheld tag. Original disputes resolve by their initiator;
/// propagated ones resolve permissionlessly once the source dispute
/// is closed (dismissed, cancelled or resolved).
public fun resolve(
    reg: &mut DisputeRegistry,
    target: &mut IPAsset,
    dispute_id: u64,
    ctx: &TxContext,
) {
    assert!(reg.disputes.contains(dispute_id), EDisputeNotFound);
    let source_id = reg.disputes.borrow(dispute_id).source;
    if (source_id > 0) {
        let source_state = reg.disputes.borrow(source_id).state;
        assert!(
            source_state == STATE_DISMISSED ||
            source_state == STATE_CANCELLED ||
            source_state == STATE_RESOLVED,
            ESourceNotClosed,
        );
    };
    let dispute = reg.disputes.borrow_mut(dispute_id);
    assert!(dispute.state == STATE_UPHELD, ENotUpheld);
    assert!(dispute.target == object::id(target), EWrongTarget);
    if (source_id == 0) {
        assert!(ctx.sender() == dispute.initiator, ENotInitiator);
    };
    dispute.state = STATE_RESOLVED;
    ip::remove_tag(target);
    event::emit(DisputeResolved { dispute_id });
}

fun propagation_key(child: ID, source_dispute_id: u64): vector<u8> {
    let mut key = bcs::to_bytes(&child);
    key.append(bcs::to_bytes(&source_dispute_id));
    key
}

// === Views ===

public fun state(reg: &DisputeRegistry, dispute_id: u64): u8 {
    assert!(reg.disputes.contains(dispute_id), EDisputeNotFound);
    reg.disputes.borrow(dispute_id).state
}

public fun tag(reg: &DisputeRegistry, dispute_id: u64): String {
    assert!(reg.disputes.contains(dispute_id), EDisputeNotFound);
    reg.disputes.borrow(dispute_id).tag
}

public fun arbiter(reg: &DisputeRegistry): address { reg.arbiter }

public fun count(reg: &DisputeRegistry): u64 { reg.count }

public fun is_tag_allowed(reg: &DisputeRegistry, tag: &String): bool {
    reg.tags.contains(tag)
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

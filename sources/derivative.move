// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Derivative registration as a hot-potato builder.
///
/// A transaction cannot pass an arbitrary number of shared objects to
/// one call, so registration is shaped for the transaction builder:
///
///   begin -> add_parent(parent, ...) x N -> finish
///
/// `DerivativeBuilder` has no abilities, so a transaction that begins
/// one MUST finish it; parents can never be half-linked.
///
/// Each add_parent folds the parent's ancestor royalty map into the
/// child's: a grandparent's absolute share carries through unchanged,
/// and shares from multiple paths to the same ancestor add up. This
/// one-time merge is what lets every later payment split in a single
/// bounded loop, and it is sound because the graph is append-only: a
/// registered IP's parents never change.
module haneul_ip::derivative;

use haneul::clock::Clock;
use haneul::coin::Coin;
use haneul::event;
use haneul::vec_map::{Self, VecMap};
use haneul::vec_set::{Self, VecSet};
use haneul_ip::ip::{Self, IPAsset, IPOwnerCap};
use haneul_ip::license::{Self, License};
use haneul_ip::protocol::{Self, ProtocolConfig};
use haneul_ip::terms::{Self, Terms, TermsRegistry};
use std::string::String;
use std::type_name::{Self, TypeName};

#[error(code = 0)]
const EWrongLicense: vector<u8> = b"The license was not minted by this parent IP.";
#[error(code = 1)]
const EDerivativesNotAllowed: vector<u8> = b"These terms do not allow derivatives.";
#[error(code = 2)]
const ENotApprovedLicensee: vector<u8> = b"The registrant is not on the parent's approval allowlist.";
#[error(code = 3)]
const ENotReciprocal: vector<u8> = b"Deriving from a derivative needs terms marked reciprocal.";
#[error(code = 4)]
const EDuplicateParent: vector<u8> = b"This parent is already linked.";
#[error(code = 5)]
const ETooManyParents: vector<u8> = b"The parent limit has been reached.";
#[error(code = 6)]
const ETooManyAncestors: vector<u8> = b"The ancestor limit has been reached.";
#[error(code = 7)]
const ENoParents: vector<u8> = b"A derivative needs at least one parent.";
#[error(code = 8)]
const EStackTooHigh: vector<u8> = b"The combined royalty stack exceeds 100% (10000 bps).";
#[error(code = 9)]
const EStackAboveMax: vector<u8> = b"The royalty stack exceeds the registrant's stated maximum.";
#[error(code = 10)]
const ETermsNotAttached: vector<u8> = b"These terms are not attached to the parent IP.";
#[error(code = 11)]
const EWrongCurrency: vector<u8> = b"The payment coin type does not match the terms' currency.";
#[error(code = 12)]
const EFeeAboveMax: vector<u8> = b"The minting fee exceeds the registrant's stated maximum.";
#[error(code = 13)]
const EInsufficientPayment: vector<u8> = b"The payment does not cover the minting fee.";

const BPS_DENOM: u64 = 10_000;
/// Product bounds, not gas bounds (a Move loop over a VecMap is
/// cheap). Chosen conservative for a first version; raising them
/// later is a compatible package upgrade because they are only
/// checked at registration time.
const MAX_PARENTS: u64 = 8;
const MAX_ANCESTORS: u64 = 32;

public struct DerivativeBuilder {
    name: String,
    content_hash: vector<u8>,
    uri: String,
    parents: vector<ID>,
    ancestors: VecMap<ID, u64>,
    stack_bps: u64,
    /// 0 = never; earliest constraint wins.
    expires_at_ms: u64,
    attached: VecSet<u64>,
    /// Currencies of the terms used, inherited as the child's initial
    /// accepted revenue currencies.
    currencies: VecSet<TypeName>,
}

public struct ParentLinked has copy, drop {
    parent: ID,
    terms_id: u64,
    edge_bps: u64,
}

public fun begin(name: String, content_hash: vector<u8>, uri: String): DerivativeBuilder {
    DerivativeBuilder {
        name,
        content_hash,
        uri,
        parents: vector[],
        ancestors: vec_map::empty(),
        stack_bps: 0,
        expires_at_ms: 0,
        attached: vec_set::empty(),
        currencies: vec_set::empty(),
    }
}

/// Links a parent by burning a `License` minted from it. The license
/// already embeds the agreed revenue share, so no payment happens
/// here; it happened at mint. Approval-gated terms need no extra
/// check either: an approval allowlist is enforced at mint, so a
/// license in hand IS the recorded consent.
public fun add_parent(
    builder: &mut DerivativeBuilder,
    parent: &mut IPAsset,
    reg: &TermsRegistry,
    license: License,
    clock: &Clock,
) {
    let (licensor, terms_id, rev_share_bps) = license::burn(license);
    assert!(licensor == object::id(parent), EWrongLicense);
    let t = *terms::get(reg, terms_id);
    link(builder, parent, &t, terms_id, rev_share_bps, clock);
}

/// Mint-and-link in one step: pays the minting fee directly and
/// links, with no separate license object changing hands.
public fun add_parent_direct<T>(
    builder: &mut DerivativeBuilder,
    parent: &mut IPAsset,
    reg: &TermsRegistry,
    cfg: &ProtocolConfig,
    terms_id: u64,
    payment: &mut Coin<T>,
    max_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    protocol::assert_running(cfg);
    assert!(parent.has_terms(terms_id), ETermsNotAttached);
    parent.assert_config_enabled(terms_id);
    let t = *terms::get(reg, terms_id);
    // No license object on this path, so the approval allowlist is
    // checked here, before any money moves.
    if (terms::derivatives_approval(&t)) {
        assert!(parent.is_approved_licensee(ctx.sender()), ENotApprovedLicensee);
    };

    let fee = parent.effective_minting_fee(terms_id, &t);
    if (fee > 0) {
        assert!(type_name::with_defining_ids<T>() == terms::currency(&t), EWrongCurrency);
        assert!(max_fee == 0 || fee <= max_fee, EFeeAboveMax);
        assert!(payment.value() >= fee, EInsufficientPayment);
        let mut fee_coin = payment.split(fee, ctx);
        protocol::collect(cfg, &mut fee_coin, ctx);
        parent.deposit(fee_coin);
    };

    let rev_share_bps = parent.effective_rev_share_bps(terms_id, &t);
    link(builder, parent, &t, terms_id, rev_share_bps, clock);
}

/// Seals the builder into a shared `IPAsset` and returns the owner
/// cap. `max_total_stack_bps` (0 = no limit) is the registrant's
/// slippage guard on the combined royalty burden.
///
/// Gated on the package version: the merged graph is immutable once
/// written, and since the hot potato forces every begin/add_parent
/// sequence to commit through here, this single gate covers the whole
/// builder flow.
public fun finish(
    builder: DerivativeBuilder,
    cfg: &ProtocolConfig,
    max_total_stack_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): IPOwnerCap {
    protocol::assert_current_version(cfg);
    let DerivativeBuilder {
        name,
        content_hash,
        uri,
        parents,
        ancestors,
        stack_bps,
        expires_at_ms,
        attached,
        currencies,
    } = builder;
    assert!(!parents.is_empty(), ENoParents);
    assert!(stack_bps <= BPS_DENOM, EStackTooHigh);
    assert!(max_total_stack_bps == 0 || stack_bps <= max_total_stack_bps, EStackAboveMax);
    ip::new_derivative(
        name,
        content_hash,
        uri,
        parents,
        ancestors,
        stack_bps,
        expires_at_ms,
        attached,
        currencies,
        clock,
        ctx,
    )
}

fun link(
    builder: &mut DerivativeBuilder,
    parent: &mut IPAsset,
    t: &Terms,
    terms_id: u64,
    edge_bps: u64,
    clock: &Clock,
) {
    ip::assert_alive(parent, clock);
    assert!(terms::derivatives_allowed(t), EDerivativesNotAllowed);
    // Deriving from a derivative needs the terms to flow down.
    if (parent.is_derivative()) {
        assert!(terms::derivatives_reciprocal(t), ENotReciprocal);
    };
    let parent_id = object::id(parent);
    assert!(!builder.parents.contains(&parent_id), EDuplicateParent);
    assert!(builder.parents.length() < MAX_PARENTS, ETooManyParents);
    builder.parents.push_back(parent_id);

    // Direct edge, then the parent's whole ancestor map, absolute and
    // unchanged. Shares reached via multiple paths accumulate.
    upsert(&mut builder.ancestors, parent_id, edge_bps);
    builder.stack_bps = builder.stack_bps + edge_bps;
    let parent_ancestors = *parent.ancestors();
    let mut i = 0;
    let n = parent_ancestors.length();
    while (i < n) {
        let (anc, bps) = parent_ancestors.get_entry_by_idx(i);
        upsert(&mut builder.ancestors, *anc, *bps);
        builder.stack_bps = builder.stack_bps + *bps;
        i = i + 1;
    };
    assert!(builder.ancestors.length() <= MAX_ANCESTORS, ETooManyAncestors);

    // The child dies when its earliest parent dies, or when the
    // license term runs out, whichever comes first.
    builder.expires_at_ms = min_nonzero(builder.expires_at_ms, parent.expires_at_ms());
    if (terms::expiration_ms(t) > 0) {
        builder.expires_at_ms = min_nonzero(
            builder.expires_at_ms,
            clock.timestamp_ms() + terms::expiration_ms(t),
        );
    };

    // The reciprocal rule: the child carries the terms it was born
    // under, and only those. It also inherits their currencies as its
    // accepted revenue currencies.
    if (!builder.attached.contains(&terms_id)) {
        builder.attached.insert(terms_id);
    };
    let currency = terms::currency(t);
    if (!builder.currencies.contains(&currency)) {
        builder.currencies.insert(currency);
    };

    parent.note_derivative();
    event::emit(ParentLinked { parent: parent_id, terms_id, edge_bps });
}

fun upsert(map: &mut VecMap<ID, u64>, key: ID, value: u64) {
    if (map.contains(&key)) {
        let existing = map.get_mut(&key);
        *existing = *existing + value;
    } else {
        map.insert(key, value);
    };
}

/// Zero means "no bound"; the tighter real bound wins.
fun min_nonzero(a: u64, b: u64): u64 {
    if (a == 0) return b;
    if (b == 0) return a;
    if (a < b) a else b
}

public fun max_parents(): u64 { MAX_PARENTS }

public fun max_ancestors(): u64 { MAX_ANCESTORS }

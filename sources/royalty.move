// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Money in, money out: royalty payments into an IP's pool, and the
/// two claim paths out of it.
///
/// A payment lands in the target's own `Pool<T>` and the ancestor
/// accruals are computed in the same instruction (the ancestor map is
/// bounded and merged at registration). Claims are pull-based with
/// the claimer's own `IPOwnerCap` as identity.
///
/// Freeze rules, in one place:
///  - protocol pause freezes payments AND claims (trade-off
///    documented in `protocol.move`),
///  - a dispute tag on the target freezes its payments and every
///    claim out of its pools, until the dispute is resolved.
///
/// Known limit: an ancestor whose own IP is tagged can still claim
/// from an untagged descendant, because the claim call does not carry
/// the ancestor's `IPAsset` and one cap is not proof of the other
/// object's state. Accepted for v1; revisit if disputes need to
/// freeze an infringer's entire income rather than the infringing
/// work's.
module haneul_ip::royalty;

use haneul::clock::Clock;
use haneul::coin::Coin;
use haneul::event;
use haneul_ip::ip::{Self, IPAsset, IPOwnerCap};
use haneul_ip::protocol::{Self, ProtocolConfig};
use std::type_name::{Self, TypeName};

const EZeroPayment: u64 = 0;
const ENotAncestor: u64 = 1;

public struct RoyaltyPaid has copy, drop {
    ip: ID,
    payer: address,
    coin_type: TypeName,
    gross: u64,
    protocol_fee: u64,
}

public struct OwnerClaimed has copy, drop {
    ip: ID,
    coin_type: TypeName,
    amount: u64,
}

public struct AncestorClaimed has copy, drop {
    descendant: ID,
    ancestor: ID,
    coin_type: TypeName,
    amount: u64,
}

/// Pays royalties (or any revenue) to an IP. Any coin type is
/// accepted; the terms' `currency` only binds minting fees. The
/// ancestor cuts accrue inside the target's pool immediately.
public fun pay<T>(
    cfg: &ProtocolConfig,
    target: &mut IPAsset,
    mut payment: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    protocol::assert_running(cfg);
    ip::assert_alive(target, clock);
    let gross = payment.value();
    assert!(gross > 0, EZeroPayment);
    let protocol_fee = protocol::collect(cfg, &mut payment, ctx);
    event::emit(RoyaltyPaid {
        ip: object::id(target),
        payer: ctx.sender(),
        coin_type: type_name::with_defining_ids<T>(),
        gross,
        protocol_fee,
    });
    target.deposit(payment);
}

/// The IP owner's share: everything in the pool not owed to
/// ancestors (dust from bps flooring included).
public fun claim_owner<T>(
    cfg: &ProtocolConfig,
    target: &mut IPAsset,
    cap: &IPOwnerCap,
    ctx: &mut TxContext,
): Coin<T> {
    protocol::assert_running(cfg);
    target.assert_owner(cap);
    ip::assert_not_tagged(target);
    let claimed = ip::withdraw_owner<T>(target, ctx);
    event::emit(OwnerClaimed {
        ip: object::id(target),
        coin_type: type_name::with_defining_ids<T>(),
        amount: claimed.value(),
    });
    claimed
}

/// An ancestor pulls its accrued share out of a descendant's pool.
/// Identity is the cap of the ANCESTOR IP; the descendant object
/// carries the accrual.
public fun claim_ancestor<T>(
    cfg: &ProtocolConfig,
    descendant: &mut IPAsset,
    ancestor_cap: &IPOwnerCap,
    ctx: &mut TxContext,
): Coin<T> {
    protocol::assert_running(cfg);
    ip::assert_not_tagged(descendant);
    let ancestor = ip::cap_ip(ancestor_cap);
    assert!(descendant.is_ancestor_of(ancestor), ENotAncestor);
    let claimed = ip::withdraw_ancestor<T>(descendant, ancestor, ctx);
    event::emit(AncestorClaimed {
        descendant: object::id(descendant),
        ancestor,
        coin_type: type_name::with_defining_ids<T>(),
        amount: claimed.value(),
    });
    claimed
}

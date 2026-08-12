// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// License terms: the machine-readable half of a license agreement.
///
/// This is a port of Story Protocol's PILTerms with the parts that
/// survived their beta -> mainnet evolution: the free-string legal
/// fields (`territories`, `distributionChannels`, ...) that their own
/// code warned against are gone, replaced by a single `uri` pointing
/// at the off-chain legal text — the chain enforces only what it can
/// actually verify.
///
/// Terms are immutable once registered and referenced by id, so a
/// `License` or an IP's attached-terms set can point at them without
/// copying. Per-IP overrides (fee, revenue share, on/off) live on the
/// IP itself as `LicensingConfig` — the "standard contract + rider"
/// split.
module haneul_ip::terms;

use haneul::event;
use haneul::table::{Self, Table};
use std::string::String;
use std::type_name::{Self, TypeName};

const EInvalidRevShare: u64 = 0;
const ENonCommercialRevShare: u64 = 1;
const ENonCommercialAttribution: u64 = 2;
const ENonCommercialMintingFee: u64 = 3;
const ENoDerivativesButAttribution: u64 = 4;
const ENoDerivativesButApproval: u64 = 5;
const ENoDerivativesButReciprocal: u64 = 6;
const ETermsNotFound: u64 = 7;

const BPS_DENOM: u64 = 10_000;

public struct TermsRegistry has key {
    id: UID,
    version: u64,
    terms: Table<u64, Terms>,
    /// Ids start at 1; 0 is never a valid terms id.
    count: u64,
}

public struct Terms has store, copy, drop {
    /// Whether a minted `License` can change hands.
    transferable: bool,
    /// Lifetime of a derivative registered under these terms,
    /// counted from registration. 0 = never expires.
    expiration_ms: u64,
    commercial_use: bool,
    commercial_attribution: bool,
    /// Absolute share (bps) of ALL revenue of a derivative that flows
    /// to the licensor — Story's LAP semantics, not a per-hop split.
    commercial_rev_share_bps: u64,
    derivatives_allowed: bool,
    derivatives_attribution: bool,
    /// If set, linking a derivative requires the licensor's cap
    /// (their signature in the same transaction).
    derivatives_approval: bool,
    /// If set, a derivative may itself license these same terms
    /// onward (derivatives of derivatives).
    derivatives_reciprocal: bool,
    default_minting_fee: u64,
    /// Coin type the minting fee must be paid in. Royalty payments
    /// themselves accept any coin type.
    currency: TypeName,
    /// Off-chain legal text these fields are a digest of.
    uri: String,
}

public struct TermsRegistered has copy, drop {
    terms_id: u64,
    commercial_use: bool,
    derivatives_allowed: bool,
    commercial_rev_share_bps: u64,
    default_minting_fee: u64,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(TermsRegistry {
        id: object::new(ctx),
        version: 1,
        terms: table::new(ctx),
        count: 0,
    });
}

/// Registers immutable license terms; `T` is the minting-fee
/// currency. The internal-consistency rules are ports of Story's
/// `_verifyCommercialUse` / `_verifyDerivatives`: states that cannot
/// mean anything ("non-commercial but takes a revenue share") are
/// rejected at registration, not discovered at use.
public fun register<T>(
    reg: &mut TermsRegistry,
    transferable: bool,
    expiration_ms: u64,
    commercial_use: bool,
    commercial_attribution: bool,
    commercial_rev_share_bps: u64,
    derivatives_allowed: bool,
    derivatives_attribution: bool,
    derivatives_approval: bool,
    derivatives_reciprocal: bool,
    default_minting_fee: u64,
    uri: String,
): u64 {
    assert!(commercial_rev_share_bps <= BPS_DENOM, EInvalidRevShare);
    if (!commercial_use) {
        assert!(commercial_rev_share_bps == 0, ENonCommercialRevShare);
        assert!(!commercial_attribution, ENonCommercialAttribution);
        assert!(default_minting_fee == 0, ENonCommercialMintingFee);
    };
    if (!derivatives_allowed) {
        assert!(!derivatives_attribution, ENoDerivativesButAttribution);
        assert!(!derivatives_approval, ENoDerivativesButApproval);
        assert!(!derivatives_reciprocal, ENoDerivativesButReciprocal);
    };

    let terms_id = reg.count + 1;
    reg.count = terms_id;
    reg.terms.add(terms_id, Terms {
        transferable,
        expiration_ms,
        commercial_use,
        commercial_attribution,
        commercial_rev_share_bps,
        derivatives_allowed,
        derivatives_attribution,
        derivatives_approval,
        derivatives_reciprocal,
        default_minting_fee,
        currency: type_name::with_defining_ids<T>(),
        uri,
    });
    event::emit(TermsRegistered {
        terms_id,
        commercial_use,
        derivatives_allowed,
        commercial_rev_share_bps,
        default_minting_fee,
    });
    terms_id
}

// === Flavors (Story's PILFlavors, the two that matter) ===

/// Free remix culture: anyone may derive, attribution required, no
/// money anywhere, derivatives inherit the same terms.
public fun register_non_commercial_remix<T>(reg: &mut TermsRegistry, uri: String): u64 {
    register<T>(reg, true, 0, false, false, 0, true, true, false, true, 0, uri)
}

/// Paid remix: minting costs `fee`, and `rev_share_bps` of every
/// payment to the derivative flows back to the licensor, recursively.
public fun register_commercial_remix<T>(
    reg: &mut TermsRegistry,
    rev_share_bps: u64,
    fee: u64,
    uri: String,
): u64 {
    register<T>(reg, true, 0, true, true, rev_share_bps, true, true, false, true, fee, uri)
}

public fun get(reg: &TermsRegistry, terms_id: u64): &Terms {
    assert!(reg.terms.contains(terms_id), ETermsNotFound);
    reg.terms.borrow(terms_id)
}

public fun exists_(reg: &TermsRegistry, terms_id: u64): bool {
    reg.terms.contains(terms_id)
}

public fun count(reg: &TermsRegistry): u64 { reg.count }

public fun transferable(t: &Terms): bool { t.transferable }

public fun expiration_ms(t: &Terms): u64 { t.expiration_ms }

public fun commercial_use(t: &Terms): bool { t.commercial_use }

public fun commercial_rev_share_bps(t: &Terms): u64 { t.commercial_rev_share_bps }

public fun derivatives_allowed(t: &Terms): bool { t.derivatives_allowed }

public fun derivatives_approval(t: &Terms): bool { t.derivatives_approval }

public fun derivatives_reciprocal(t: &Terms): bool { t.derivatives_reciprocal }

public fun default_minting_fee(t: &Terms): u64 { t.default_minting_fee }

public fun currency(t: &Terms): TypeName { t.currency }

public fun uri(t: &Terms): String { t.uri }

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

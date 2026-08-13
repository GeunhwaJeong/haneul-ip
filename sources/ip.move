// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// The IP asset itself: identity, provenance graph, and revenue vault
/// in one object.
///
/// One shared object carries everything a registered work needs:
///  - Identity: the object is an addressable identity that can own
///    things; no separate account layer exists.
///  - Registry: the object store is the registry; there is no global
///    lookup contract to keep in sync.
///  - Graph: the ancestor royalty map is two object fields. This
///    works because the graph is append-only: parents are fixed at
///    registration and never change, so each IP's ancestor royalty
///    map can be merged ONCE at registration and stays valid forever.
///  - Vault: the `revenue` Bag holds one `Pool<T>` per coin type,
///    inside the object itself; no per-asset vault deployment.
///
/// Royalty semantics are absolute shares: each ancestor's bps applies
/// to EVERY payment made to this IP, not to a per-hop waterfall. An
/// ancestor's share sits in this object's pool as `owed` until the
/// ancestor claims it with their own cap. The pull model is forced by
/// the fact that an owner's wallet address is not knowable on-chain
/// from the IP object alone.
module haneul_ip::ip;

use haneul::bag::{Self, Bag};
use haneul::balance::Balance;
use haneul::clock::Clock;
use haneul::coin::{Self, Coin};
use haneul::event;
use haneul::vec_map::{Self, VecMap};
use haneul::vec_set::{Self, VecSet};
use haneul_ip::protocol::{Self, ProtocolConfig};
use haneul_ip::terms::{Self, Terms, TermsRegistry};
use std::string::String;
use std::type_name::{Self, TypeName};

#[error(code = 0)]
const ENotOwner: vector<u8> = b"The cap does not own this IP asset.";
#[error(code = 1)]
const EBadContentHash: vector<u8> = b"The content hash must be exactly 32 bytes.";
#[error(code = 2)]
const ETagged: vector<u8> = b"This IP asset is frozen by an upheld dispute.";
#[error(code = 3)]
const EExpired: vector<u8> = b"This IP asset has expired.";
#[error(code = 4)]
const ENotRoot: vector<u8> = b"Only a root IP can attach terms; a derivative's terms are fixed at registration.";
#[error(code = 5)]
const ETermsAlreadyAttached: vector<u8> = b"These terms are already attached to this IP asset.";
#[error(code = 6)]
const ETermsNotAttached: vector<u8> = b"These terms are not attached to this IP asset.";
#[error(code = 7)]
const EInvalidRevShare: vector<u8> = b"The revenue share exceeds 100% (10000 bps).";
#[error(code = 8)]
const ENothingToClaim: vector<u8> = b"There is nothing to claim in this pool.";
#[error(code = 9)]
const EConfigDisabled: vector<u8> = b"Licensing under these terms is disabled by the owner.";
#[error(code = 10)]
const ETermsNotFound: vector<u8> = b"No terms are registered under this id.";
#[error(code = 11)]
const ECurrencyNotAccepted: vector<u8> = b"This IP asset does not accept revenue in this coin type.";
#[error(code = 12)]
const ETooManyCurrencies: vector<u8> = b"The accepted-currency limit has been reached.";
#[error(code = 13)]
const ETooManyApprovals: vector<u8> = b"The approved-licensee limit has been reached.";

const BPS_DENOM: u64 = 10_000;
const CONTENT_HASH_LENGTH: u64 = 32;
/// Bounds the `accepted_currencies` set so membership checks on the
/// payment path stay cheap.
const MAX_ACCEPTED_CURRENCIES: u64 = 16;
/// Bounds the approval allowlist; an owner needing more should model
/// the franchise as multiple IPs.
const MAX_APPROVED_LICENSEES: u64 = 128;

public struct IPAsset has key {
    id: UID,
    /// Schema version stamped at creation. Deliberately NOT checked
    /// against the package version on use: assets are many, and an
    /// exact gate would halt every one of them until each was
    /// individually migrated after an upgrade. Global enforcement
    /// rides on the `ProtocolConfig` gate instead; this field exists
    /// so future code can detect and lazily migrate old-schema assets
    /// one by one.
    version: u64,
    name: String,
    /// 32-byte hash of the underlying work. Self-attested: the chain
    /// records who claimed what and when; it cannot verify the claim.
    /// That gap is what the dispute module exists for.
    content_hash: vector<u8>,
    uri: String,
    creator: address,
    registered_at_ms: u64,
    /// 0 = never expires. A derivative inherits the earliest expiry
    /// among its parents and its license terms.
    expires_at_ms: u64,
    /// Direct parents. Set once at registration, immutable after.
    parents: vector<ID>,
    /// ancestor -> absolute royalty share (bps) of every payment made
    /// to THIS IP. Merged once at registration from the parents'
    /// maps. Direct parents are entries here too.
    ancestors: VecMap<ID, u64>,
    /// Sum of `ancestors` values. <= 10_000 by construction.
    royalty_stack_bps: u64,
    /// Terms ids this IP offers licenses under. Roots choose theirs;
    /// derivatives get exactly the terms they were registered under
    /// (the reciprocal rule) and cannot add more.
    attached_terms: VecSet<u64>,
    /// Per-terms owner overrides: the per-asset rider on the global
    /// terms sheet.
    configs: VecMap<u64, LicensingConfig>,
    /// Coin types this IP accepts revenue in. Deposits in any other
    /// type abort, so a third party cannot bloat this object with
    /// junk-coin pools. Currencies of attached terms are accepted
    /// automatically; the owner can add or stop more. Stopping never
    /// touches existing pools, so funds can never be trapped.
    accepted_currencies: VecSet<TypeName>,
    /// Licensees pre-approved by the owner, for terms that require
    /// approval. Consent is recorded on-chain BEFORE any money moves.
    approved_licensees: VecSet<address>,
    /// Active upheld disputes. Non-zero freezes licensing, linking,
    /// payments and claims.
    tag_count: u64,
    /// TypeName -> Pool<T>: one revenue vault per coin type.
    revenue: Bag,
    licenses_minted: u64,
    derivatives_registered: u64,
}

/// Ownership of an IP. `store` on purpose: IP ownership is an asset
/// that must be sellable/transferable, unlike an admin cap.
public struct IPOwnerCap has key, store {
    id: UID,
    ip: ID,
}

/// Owner overrides for one attached terms id. A snapshot of the
/// effective values is taken into each `License` at mint time, so
/// changing these never rewrites already-sold licenses, which is
/// also why minting takes slippage guards.
public struct LicensingConfig has store, copy, drop {
    disabled: bool,
    minting_fee_override: Option<u64>,
    rev_share_override_bps: Option<u64>,
}

public struct Pool<phantom T> has store {
    balance: Balance<T>,
    /// ancestor -> claimable amount, accrued at payment time.
    owed: VecMap<ID, u64>,
    /// Invariant: sum of `owed` values; the owner's claimable share
    /// is `balance - total_owed`.
    total_owed: u64,
}

public struct IPRegistered has copy, drop {
    ip: ID,
    creator: address,
    name: String,
    content_hash: vector<u8>,
}

public struct DerivativeRegistered has copy, drop {
    ip: ID,
    creator: address,
    parents: vector<ID>,
    royalty_stack_bps: u64,
    expires_at_ms: u64,
}

public struct TermsAttached has copy, drop {
    ip: ID,
    terms_id: u64,
}

public struct LicensingConfigSet has copy, drop {
    ip: ID,
    terms_id: u64,
    disabled: bool,
}

public struct Deposited has copy, drop {
    ip: ID,
    coin_type: TypeName,
    amount: u64,
    to_ancestors: u64,
}

public struct CurrencyAccepted has copy, drop {
    ip: ID,
    coin_type: TypeName,
}

public struct CurrencyStopped has copy, drop {
    ip: ID,
    coin_type: TypeName,
}

public struct LicenseeApproved has copy, drop {
    ip: ID,
    licensee: address,
}

public struct LicenseeRevoked has copy, drop {
    ip: ID,
    licensee: address,
}

// === Registration ===

/// Registers a root IP. Shares the asset, returns the owner cap.
/// Gated on the package version (not the pause switch: registration
/// is not a money path) because it writes state that can never be
/// corrected afterwards.
public fun register(
    cfg: &ProtocolConfig,
    name: String,
    content_hash: vector<u8>,
    uri: String,
    clock: &Clock,
    ctx: &mut TxContext,
): IPOwnerCap {
    protocol::assert_current_version(cfg);
    let (cap, ip_id) = new_ip(
        name,
        content_hash,
        uri,
        vector[],
        vec_map::empty(),
        0,
        0,
        vec_set::empty(),
        vec_set::empty(),
        clock,
        ctx,
    );
    event::emit(IPRegistered { ip: ip_id, creator: ctx.sender(), name, content_hash });
    cap
}

/// Called by `derivative::finish` with the merged graph data.
public(package) fun new_derivative(
    name: String,
    content_hash: vector<u8>,
    uri: String,
    parents: vector<ID>,
    ancestors: VecMap<ID, u64>,
    royalty_stack_bps: u64,
    expires_at_ms: u64,
    attached_terms: VecSet<u64>,
    accepted_currencies: VecSet<TypeName>,
    clock: &Clock,
    ctx: &mut TxContext,
): IPOwnerCap {
    let (cap, ip_id) = new_ip(
        name,
        content_hash,
        uri,
        parents,
        ancestors,
        royalty_stack_bps,
        expires_at_ms,
        attached_terms,
        accepted_currencies,
        clock,
        ctx,
    );
    event::emit(DerivativeRegistered {
        ip: ip_id,
        creator: ctx.sender(),
        parents,
        royalty_stack_bps,
        expires_at_ms,
    });
    cap
}

fun new_ip(
    name: String,
    content_hash: vector<u8>,
    uri: String,
    parents: vector<ID>,
    ancestors: VecMap<ID, u64>,
    royalty_stack_bps: u64,
    expires_at_ms: u64,
    attached_terms: VecSet<u64>,
    accepted_currencies: VecSet<TypeName>,
    clock: &Clock,
    ctx: &mut TxContext,
): (IPOwnerCap, ID) {
    assert!(content_hash.length() == CONTENT_HASH_LENGTH, EBadContentHash);
    let asset = IPAsset {
        id: object::new(ctx),
        version: 1,
        name,
        content_hash,
        uri,
        creator: ctx.sender(),
        registered_at_ms: clock.timestamp_ms(),
        expires_at_ms,
        parents,
        ancestors,
        royalty_stack_bps,
        attached_terms,
        configs: vec_map::empty(),
        accepted_currencies,
        approved_licensees: vec_set::empty(),
        tag_count: 0,
        revenue: bag::new(ctx),
        licenses_minted: 0,
        derivatives_registered: 0,
    };
    let ip_id = object::id(&asset);
    let cap = IPOwnerCap { id: object::new(ctx), ip: ip_id };
    transfer::share_object(asset);
    (cap, ip_id)
}

// === Terms management (owner-only) ===

/// Only roots attach terms; a derivative's terms are fixed at
/// registration, so the deal a work was born under cannot be
/// rewritten afterwards.
public fun attach_terms(
    self: &mut IPAsset,
    cap: &IPOwnerCap,
    reg: &TermsRegistry,
    terms_id: u64,
) {
    self.assert_owner(cap);
    self.assert_not_tagged();
    assert!(self.parents.is_empty(), ENotRoot);
    assert!(terms::exists_(reg, terms_id), ETermsNotFound);
    assert!(!self.attached_terms.contains(&terms_id), ETermsAlreadyAttached);
    self.attached_terms.insert(terms_id);
    // Pricing terms in a currency is the natural opt-in to receive it.
    accept_currency_internal(self, terms::currency(terms::get(reg, terms_id)));
    event::emit(TermsAttached { ip: object::id(self), terms_id });
}

// === Revenue currencies and licensee approvals (owner-only) ===

public fun accept_currency<T>(self: &mut IPAsset, cap: &IPOwnerCap) {
    self.assert_owner(cap);
    accept_currency_internal(self, type_name::with_defining_ids<T>());
}

/// Stops NEW deposits in `T`. Existing pools stay claimable forever,
/// so stopping a currency can never trap funds.
public fun stop_accepting_currency<T>(self: &mut IPAsset, cap: &IPOwnerCap) {
    self.assert_owner(cap);
    let currency = type_name::with_defining_ids<T>();
    if (self.accepted_currencies.contains(&currency)) {
        self.accepted_currencies.remove(&currency);
        event::emit(CurrencyStopped { ip: object::id(self), coin_type: currency });
    };
}

/// Grants `licensee` the standing consent that approval-gated terms
/// require. This runs BEFORE the licensee pays anything, in the
/// owner's own transaction; revocation only affects future mints,
/// never a license already paid for.
public fun approve_licensee(self: &mut IPAsset, cap: &IPOwnerCap, licensee: address) {
    self.assert_owner(cap);
    if (self.approved_licensees.contains(&licensee)) return;
    assert!(self.approved_licensees.length() < MAX_APPROVED_LICENSEES, ETooManyApprovals);
    self.approved_licensees.insert(licensee);
    event::emit(LicenseeApproved { ip: object::id(self), licensee });
}

public fun revoke_licensee(self: &mut IPAsset, cap: &IPOwnerCap, licensee: address) {
    self.assert_owner(cap);
    if (self.approved_licensees.contains(&licensee)) {
        self.approved_licensees.remove(&licensee);
        event::emit(LicenseeRevoked { ip: object::id(self), licensee });
    };
}

fun accept_currency_internal(self: &mut IPAsset, currency: TypeName) {
    if (self.accepted_currencies.contains(&currency)) return;
    assert!(self.accepted_currencies.length() < MAX_ACCEPTED_CURRENCIES, ETooManyCurrencies);
    self.accepted_currencies.insert(currency);
    event::emit(CurrencyAccepted { ip: object::id(self), coin_type: currency });
}

public fun set_licensing_config(
    self: &mut IPAsset,
    cap: &IPOwnerCap,
    terms_id: u64,
    disabled: bool,
    minting_fee_override: Option<u64>,
    rev_share_override_bps: Option<u64>,
) {
    self.assert_owner(cap);
    assert!(self.attached_terms.contains(&terms_id), ETermsNotAttached);
    if (rev_share_override_bps.is_some()) {
        assert!(*rev_share_override_bps.borrow() <= BPS_DENOM, EInvalidRevShare);
    };
    let config = LicensingConfig { disabled, minting_fee_override, rev_share_override_bps };
    if (self.configs.contains(&terms_id)) {
        *self.configs.get_mut(&terms_id) = config;
    } else {
        self.configs.insert(terms_id, config);
    };
    event::emit(LicensingConfigSet { ip: object::id(self), terms_id, disabled });
}

// === Revenue vault (package-internal; entry points live in `royalty`) ===

/// Splits `payment` across the ancestor map as `owed` accruals; the
/// remainder is the owner's. The map is <= MAX_ANCESTORS entries, so
/// the loop is bounded.
public(package) fun deposit<T>(self: &mut IPAsset, payment: Coin<T>) {
    let amount = payment.value();
    if (amount == 0) {
        payment.destroy_zero();
        return
    };
    // The anti-junk gate: only currencies this IP opted into may
    // create or grow pools on it.
    assert!(
        self.accepted_currencies.contains(&type_name::with_defining_ids<T>()),
        ECurrencyNotAccepted,
    );
    let ip_id = object::id(self);
    let ancestors = self.ancestors;
    ensure_pool<T>(self);
    let pool = self.revenue.borrow_mut<TypeName, Pool<T>>(type_name::with_defining_ids<T>());

    let mut to_ancestors = 0;
    let mut i = 0;
    let n = ancestors.length();
    while (i < n) {
        let (anc, bps) = ancestors.get_entry_by_idx(i);
        let cut = ((amount as u128) * ((*bps) as u128) / (BPS_DENOM as u128)) as u64;
        if (cut > 0) {
            if (pool.owed.contains(anc)) {
                let owed = pool.owed.get_mut(anc);
                *owed = *owed + cut;
            } else {
                pool.owed.insert(*anc, cut);
            };
            pool.total_owed = pool.total_owed + cut;
            to_ancestors = to_ancestors + cut;
        };
        i = i + 1;
    };
    pool.balance.join(payment.into_balance());
    event::emit(Deposited {
        ip: ip_id,
        coin_type: type_name::with_defining_ids<T>(),
        amount,
        to_ancestors,
    });
}

public(package) fun withdraw_owner<T>(self: &mut IPAsset, ctx: &mut TxContext): Coin<T> {
    let key = type_name::with_defining_ids<T>();
    assert!(self.revenue.contains(key), ENothingToClaim);
    let pool = self.revenue.borrow_mut<TypeName, Pool<T>>(key);
    let available = pool.balance.value() - pool.total_owed;
    assert!(available > 0, ENothingToClaim);
    coin::from_balance(pool.balance.split(available), ctx)
}

public(package) fun withdraw_ancestor<T>(
    self: &mut IPAsset,
    ancestor: ID,
    ctx: &mut TxContext,
): Coin<T> {
    let key = type_name::with_defining_ids<T>();
    assert!(self.revenue.contains(key), ENothingToClaim);
    let pool = self.revenue.borrow_mut<TypeName, Pool<T>>(key);
    assert!(pool.owed.contains(&ancestor), ENothingToClaim);
    let (_, amount) = pool.owed.remove(&ancestor);
    pool.total_owed = pool.total_owed - amount;
    coin::from_balance(pool.balance.split(amount), ctx)
}

fun ensure_pool<T>(self: &mut IPAsset) {
    let key = type_name::with_defining_ids<T>();
    if (!self.revenue.contains(key)) {
        self.revenue.add(key, Pool<T> {
            balance: haneul::balance::zero<T>(),
            owed: vec_map::empty(),
            total_owed: 0,
        });
    };
}

public fun claimable_by_owner<T>(self: &IPAsset): u64 {
    let key = type_name::with_defining_ids<T>();
    if (!self.revenue.contains(key)) return 0;
    let pool = self.revenue.borrow<TypeName, Pool<T>>(key);
    pool.balance.value() - pool.total_owed
}

public fun claimable_by_ancestor<T>(self: &IPAsset, ancestor: ID): u64 {
    let key = type_name::with_defining_ids<T>();
    if (!self.revenue.contains(key)) return 0;
    let pool = self.revenue.borrow<TypeName, Pool<T>>(key);
    if (!pool.owed.contains(&ancestor)) return 0;
    *pool.owed.get(&ancestor)
}

// === Effective licensing values (terms + per-IP override) ===

public fun effective_minting_fee(self: &IPAsset, terms_id: u64, t: &Terms): u64 {
    if (self.configs.contains(&terms_id)) {
        let config = self.configs.get(&terms_id);
        if (config.minting_fee_override.is_some()) {
            return *config.minting_fee_override.borrow()
        };
    };
    terms::default_minting_fee(t)
}

public fun effective_rev_share_bps(self: &IPAsset, terms_id: u64, t: &Terms): u64 {
    if (self.configs.contains(&terms_id)) {
        let config = self.configs.get(&terms_id);
        if (config.rev_share_override_bps.is_some()) {
            return *config.rev_share_override_bps.borrow()
        };
    };
    terms::commercial_rev_share_bps(t)
}

public(package) fun assert_config_enabled(self: &IPAsset, terms_id: u64) {
    if (self.configs.contains(&terms_id)) {
        assert!(!self.configs.get(&terms_id).disabled, EConfigDisabled);
    };
}

// === Guards and state transitions used by sibling modules ===

public fun assert_owner(self: &IPAsset, cap: &IPOwnerCap) {
    assert!(object::id(self) == cap.ip, ENotOwner);
}

public(package) fun assert_not_tagged(self: &IPAsset) {
    assert!(self.tag_count == 0, ETagged);
}

public(package) fun assert_alive(self: &IPAsset, clock: &Clock) {
    self.assert_not_tagged();
    assert!(!self.is_expired(clock), EExpired);
}

public(package) fun add_tag(self: &mut IPAsset) {
    self.tag_count = self.tag_count + 1;
}

public(package) fun remove_tag(self: &mut IPAsset) {
    self.tag_count = self.tag_count - 1;
}

public(package) fun note_license_minted(self: &mut IPAsset) {
    self.licenses_minted = self.licenses_minted + 1;
}

public(package) fun note_derivative(self: &mut IPAsset) {
    self.derivatives_registered = self.derivatives_registered + 1;
}

// === Views ===

public fun cap_ip(cap: &IPOwnerCap): ID { cap.ip }

public fun is_tagged(self: &IPAsset): bool { self.tag_count > 0 }

public fun tag_count(self: &IPAsset): u64 { self.tag_count }

public fun is_expired(self: &IPAsset, clock: &Clock): bool {
    self.expires_at_ms != 0 && clock.timestamp_ms() >= self.expires_at_ms
}

public fun expires_at_ms(self: &IPAsset): u64 { self.expires_at_ms }

public fun is_derivative(self: &IPAsset): bool { !self.parents.is_empty() }

public fun parents(self: &IPAsset): &vector<ID> { &self.parents }

public fun ancestors(self: &IPAsset): &VecMap<ID, u64> { &self.ancestors }

public fun is_ancestor_of(self: &IPAsset, maybe_ancestor: ID): bool {
    self.ancestors.contains(&maybe_ancestor)
}

public fun ancestor_share_bps(self: &IPAsset, ancestor: ID): u64 {
    if (!self.ancestors.contains(&ancestor)) return 0;
    *self.ancestors.get(&ancestor)
}

public fun royalty_stack_bps(self: &IPAsset): u64 { self.royalty_stack_bps }

public fun has_terms(self: &IPAsset, terms_id: u64): bool {
    self.attached_terms.contains(&terms_id)
}

public fun is_currency_accepted<T>(self: &IPAsset): bool {
    self.accepted_currencies.contains(&type_name::with_defining_ids<T>())
}

public fun is_approved_licensee(self: &IPAsset, licensee: address): bool {
    self.approved_licensees.contains(&licensee)
}

public fun name(self: &IPAsset): String { self.name }

public fun content_hash(self: &IPAsset): vector<u8> { self.content_hash }

public fun creator(self: &IPAsset): address { self.creator }

public fun licenses_minted(self: &IPAsset): u64 { self.licenses_minted }

public fun derivatives_registered(self: &IPAsset): u64 { self.derivatives_registered }

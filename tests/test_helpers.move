// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Shared fixtures for the per-module test files: persona addresses,
/// setup helpers and the multi-step flows (mint license, register
/// derivative, pay royalty, tag an IP) that individual tests compose.
/// Persona constants are re-declared in each test file (Move
/// constants are module-private); the values here are the single
/// source of truth.
#[test_only]
module haneul_ip::test_helpers;

use haneul::clock::{Self, Clock};
use haneul::coin::{Self, Coin};
use haneul::haneul::HANEUL;
use haneul::test_scenario::{Self as ts, Scenario};
use haneul_ip::derivative;
use haneul_ip::dispute::{Self, DisputeRegistry};
use haneul_ip::ip::{Self, IPAsset, IPOwnerCap};
use haneul_ip::license::{Self, License};
use haneul_ip::protocol::{Self, ProtocolCap, ProtocolConfig};
use haneul_ip::royalty;
use haneul_ip::terms::{Self, TermsRegistry};
use std::string::{Self, String};

/// Deployer: treasury and dispute arbiter by init default.
const ADMIN: address = @0xAD;

/// Test-only second coin type for currency/multi-pool tests.
public struct USDX has drop {}

public fun str(bytes: vector<u8>): String { string::utf8(bytes) }

/// A deterministic 32-byte content hash; distinct seeds give
/// distinct hashes.
public fun hash(seed: u8): vector<u8> {
    let mut v = vector[];
    let mut i = 0u64;
    while (i < 32) {
        v.push_back(seed);
        i = i + 1;
    };
    v
}

public fun new_clock(s: &mut Scenario): Clock {
    clock::create_for_testing(s.ctx())
}

/// Runs all three package initializers as ADMIN: ProtocolConfig
/// (fee 0, unpaused), TermsRegistry, DisputeRegistry (arbiter=ADMIN).
public fun setup(s: &mut Scenario) {
    s.next_tx(ADMIN);
    protocol::init_for_testing(s.ctx());
    terms::init_for_testing(s.ctx());
    dispute::init_for_testing(s.ctx());
}

public fun mint_haneul(s: &mut Scenario, amount: u64): Coin<HANEUL> {
    coin::mint_for_testing<HANEUL>(amount, s.ctx())
}

/// Commercial remix terms in HANEUL: `rev_share_bps` of a derivative's
/// revenue flows to the licensor, minting costs `fee`.
public fun std_terms(s: &mut Scenario, rev_share_bps: u64, fee: u64): u64 {
    s.next_tx(ADMIN);
    let mut reg = s.take_shared<TermsRegistry>();
    let id = terms::register_commercial_remix<HANEUL>(&mut reg, rev_share_bps, fee, str(b""));
    ts::return_shared(reg);
    id
}

/// Free, reciprocal, non-commercial remix terms.
public fun free_terms(s: &mut Scenario): u64 {
    s.next_tx(ADMIN);
    let mut reg = s.take_shared<TermsRegistry>();
    let id = terms::register_non_commercial_remix<HANEUL>(&mut reg, str(b""));
    ts::return_shared(reg);
    id
}

/// Fully custom terms registration, for tests that need one flag off.
public fun custom_terms(
    s: &mut Scenario,
    transferable: bool,
    expiration_ms: u64,
    commercial_use: bool,
    rev_share_bps: u64,
    derivatives_allowed: bool,
    derivatives_approval: bool,
    derivatives_reciprocal: bool,
    fee: u64,
): u64 {
    s.next_tx(ADMIN);
    let mut reg = s.take_shared<TermsRegistry>();
    let id = terms::register<HANEUL>(
        &mut reg,
        transferable,
        expiration_ms,
        commercial_use,
        false,
        rev_share_bps,
        derivatives_allowed,
        false,
        derivatives_approval,
        derivatives_reciprocal,
        fee,
        str(b""),
    );
    ts::return_shared(reg);
    id
}

/// Registers a root IP owned by `owner`; returns (ip id, cap id).
public fun root(s: &mut Scenario, owner: address, seed: u8, clock: &Clock): (ID, ID) {
    s.next_tx(owner);
    let cfg = s.take_shared<ProtocolConfig>();
    let cap = ip::register(&cfg, str(b"root"), hash(seed), str(b""), clock, s.ctx());
    let ip_id = ip::cap_ip(&cap);
    let cap_id = object::id(&cap);
    transfer::public_transfer(cap, owner);
    ts::return_shared(cfg);
    (ip_id, cap_id)
}

/// Root IP with `terms_id` already attached.
public fun root_with_terms(
    s: &mut Scenario,
    owner: address,
    seed: u8,
    terms_id: u64,
    clock: &Clock,
): (ID, ID) {
    let (ip_id, cap_id) = root(s, owner, seed, clock);
    s.next_tx(owner);
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    let cap = s.take_from_sender_by_id<IPOwnerCap>(cap_id);
    let reg = s.take_shared<TermsRegistry>();
    ip::attach_terms(&mut asset, &cap, &reg, terms_id);
    ts::return_shared(reg);
    ts::return_shared(asset);
    s.return_to_sender(cap);
    (ip_id, cap_id)
}

/// `buyer` mints a license from `ip_id` and keeps it, paying out of a
/// fresh coin of `pay_amount` (leftover returned to buyer).
public fun mint_license_to(
    s: &mut Scenario,
    buyer: address,
    ip_id: ID,
    terms_id: u64,
    pay_amount: u64,
    clock: &Clock,
): ID {
    s.next_tx(buyer);
    let cfg = s.take_shared<ProtocolConfig>();
    let reg = s.take_shared<TermsRegistry>();
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    let mut payment = mint_haneul(s, pay_amount);
    let license = license::mint<HANEUL>(
        &cfg,
        &mut asset,
        &reg,
        terms_id,
        &mut payment,
        0,
        clock,
        s.ctx(),
    );
    let license_id = object::id(&license);
    license::keep(license, s.ctx());
    transfer::public_transfer(payment, buyer);
    ts::return_shared(cfg);
    ts::return_shared(reg);
    ts::return_shared(asset);
    license_id
}

/// Full derivative flow over the license path, IN ONE TRANSACTION:
/// `creator` buys the license and immediately consumes it to register
/// the child (mint -> add_parent -> finish). This is the composable
/// flow that `mint` returning the `License` exists for.
/// Returns (child ip id, child cap id).
public fun make_child(
    s: &mut Scenario,
    creator: address,
    parent_ip: ID,
    terms_id: u64,
    pay_amount: u64,
    seed: u8,
    clock: &Clock,
): (ID, ID) {
    s.next_tx(creator);
    let cfg = s.take_shared<ProtocolConfig>();
    let reg = s.take_shared<TermsRegistry>();
    let mut parent = s.take_shared_by_id<IPAsset>(parent_ip);
    let mut payment = mint_haneul(s, pay_amount);
    let license = license::mint<HANEUL>(
        &cfg,
        &mut parent,
        &reg,
        terms_id,
        &mut payment,
        0,
        clock,
        s.ctx(),
    );
    let mut builder = derivative::begin(str(b"child"), hash(seed), str(b""));
    derivative::add_parent(&mut builder, &mut parent, &reg, license, clock);
    let cap = derivative::finish(builder, &cfg, 0, clock, s.ctx());
    let child_ip = ip::cap_ip(&cap);
    let cap_id = object::id(&cap);
    transfer::public_transfer(cap, creator);
    transfer::public_transfer(payment, creator);
    ts::return_shared(cfg);
    ts::return_shared(reg);
    ts::return_shared(parent);
    (child_ip, cap_id)
}

/// Owner of `ip_id` puts `licensee` on the approval allowlist.
public fun approve(
    s: &mut Scenario,
    owner: address,
    ip_id: ID,
    cap_id: ID,
    licensee: address,
) {
    s.next_tx(owner);
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    let cap = s.take_from_sender_by_id<IPOwnerCap>(cap_id);
    ip::approve_licensee(&mut asset, &cap, licensee);
    s.return_to_sender(cap);
    ts::return_shared(asset);
}

/// Pays `amount` HANEUL of royalties to `ip_id`.
public fun pay_royalty(s: &mut Scenario, payer: address, ip_id: ID, amount: u64, clock: &Clock) {
    s.next_tx(payer);
    let cfg = s.take_shared<ProtocolConfig>();
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    royalty::pay<HANEUL>(&cfg, &mut asset, mint_haneul(s, amount), clock, s.ctx());
    ts::return_shared(cfg);
    ts::return_shared(asset);
}

/// Simulates a config left behind by a package upgrade: the stored
/// version drops below the package VERSION, so gated entry points
/// abort until `protocol::migrate` runs.
public fun stale_config(s: &mut Scenario) {
    s.next_tx(ADMIN);
    let mut cfg = s.take_shared<ProtocolConfig>();
    protocol::set_version_for_testing(&mut cfg, 0);
    ts::return_shared(cfg);
}

/// Whitelists the "PLAGIARISM" dispute tag as ADMIN.
public fun setup_tag(s: &mut Scenario) {
    s.next_tx(ADMIN);
    let mut reg = s.take_shared<DisputeRegistry>();
    let cap = s.take_from_sender<ProtocolCap>();
    dispute::allow_tag(&mut reg, &cap, str(b"PLAGIARISM"));
    s.return_to_sender(cap);
    ts::return_shared(reg);
}

/// Raises and upholds a "PLAGIARISM" dispute against `ip_id` (ADMIN
/// is both initiator and arbiter here). Returns the dispute id.
/// Requires `setup_tag` to have run.
public fun tag_ip(s: &mut Scenario, ip_id: ID, evidence_seed: u8, clock: &Clock): u64 {
    s.next_tx(ADMIN);
    let mut reg = s.take_shared<DisputeRegistry>();
    let asset = s.take_shared_by_id<IPAsset>(ip_id);
    let dispute_id = dispute::raise(
        &mut reg,
        &asset,
        hash(evidence_seed),
        str(b"PLAGIARISM"),
        clock,
        s.ctx(),
    );
    ts::return_shared(asset);
    ts::return_shared(reg);

    s.next_tx(ADMIN);
    let mut reg = s.take_shared<DisputeRegistry>();
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    dispute::judge(&mut reg, &mut asset, dispute_id, true, s.ctx());
    ts::return_shared(asset);
    ts::return_shared(reg);
    dispute_id
}

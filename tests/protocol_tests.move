// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Tests for `haneul_ip::protocol`: the fee switch (mechanism only,
/// starts at zero) and the circuit breaker over inflows and claims.
#[test_only]
module haneul_ip::protocol_tests;

use haneul::coin::Coin;
use haneul::haneul::HANEUL;
use haneul::test_scenario::{Self as ts, Scenario};
use haneul_ip::ip::{Self, IPAsset, IPOwnerCap};
use haneul_ip::license;
use haneul_ip::protocol::{Self, ProtocolCap, ProtocolConfig};
use haneul_ip::royalty;
use haneul_ip::terms::TermsRegistry;
use haneul_ip::test_helpers::{
    new_clock,
    setup,
    std_terms,
    root_with_terms,
    pay_royalty,
    mint_haneul,
};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const CAROL: address = @0xCA401;

fun set_fee(s: &mut Scenario, fee_bps: u64) {
    s.next_tx(ADMIN);
    let mut cfg = s.take_shared<ProtocolConfig>();
    let cap = s.take_from_sender<ProtocolCap>();
    protocol::set_fee_bps(&mut cfg, &cap, fee_bps);
    s.return_to_sender(cap);
    ts::return_shared(cfg);
}

fun set_paused(s: &mut Scenario, paused: bool) {
    s.next_tx(ADMIN);
    let mut cfg = s.take_shared<ProtocolConfig>();
    let cap = s.take_from_sender<ProtocolCap>();
    protocol::set_paused(&mut cfg, &cap, paused);
    s.return_to_sender(cap);
    ts::return_shared(cfg);
}

#[test]
fun init_defaults_are_fee_zero_unpaused_admin_treasury() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    s.next_tx(ADMIN);
    let cfg = s.take_shared<ProtocolConfig>();
    assert!(protocol::fee_bps(&cfg) == 0);
    assert!(!protocol::is_paused(&cfg));
    assert!(protocol::treasury(&cfg) == ADMIN);
    ts::return_shared(cfg);
    s.end();
}

/// At fee 0 the whole payment lands in the IP's pool.
#[test]
fun zero_fee_passes_full_amount_to_pool() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);

    pay_royalty(&mut s, CAROL, ip_id, 1_000, &clock);

    s.next_tx(ALICE);
    let asset = s.take_shared_by_id<IPAsset>(ip_id);
    assert!(ip::claimable_by_owner<HANEUL>(&asset) == 1_000);
    ts::return_shared(asset);
    clock.destroy_for_testing();
    s.end();
}

/// The fee switch: 5% set, a 1000 payment sends 50 to the treasury
/// and 950 into the pool.
#[test]
fun fee_switch_takes_cut_to_treasury() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    set_fee(&mut s, 500);

    pay_royalty(&mut s, CAROL, ip_id, 1_000, &clock);

    s.next_tx(ADMIN);
    let fee_coin = s.take_from_sender<Coin<HANEUL>>();
    assert!(fee_coin.value() == 50);
    s.return_to_sender(fee_coin);
    let asset = s.take_shared_by_id<IPAsset>(ip_id);
    assert!(ip::claimable_by_owner<HANEUL>(&asset) == 950);
    ts::return_shared(asset);
    clock.destroy_for_testing();
    s.end();
}

#[test]
fun treasury_change_redirects_fee() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    set_fee(&mut s, 500);

    s.next_tx(ADMIN);
    let mut cfg = s.take_shared<ProtocolConfig>();
    let cap = s.take_from_sender<ProtocolCap>();
    protocol::set_treasury(&mut cfg, &cap, CAROL);
    s.return_to_sender(cap);
    ts::return_shared(cfg);

    pay_royalty(&mut s, ALICE, ip_id, 1_000, &clock);

    s.next_tx(CAROL);
    let fee_coin = s.take_from_sender<Coin<HANEUL>>();
    assert!(fee_coin.value() == 50);
    s.return_to_sender(fee_coin);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = haneul_ip::protocol::EFeeAboveMax)]
fun fee_above_100_percent_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    set_fee(&mut s, 10_001);
    s.end();
}

#[test]
#[expected_failure(abort_code = haneul_ip::protocol::EPaused)]
fun pause_blocks_royalty_payment() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    set_paused(&mut s, true);
    pay_royalty(&mut s, CAROL, ip_id, 1_000, &clock);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::protocol::EPaused)]
fun pause_blocks_license_mint() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 100);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    set_paused(&mut s, true);

    s.next_tx(CAROL);
    let cfg = s.take_shared<ProtocolConfig>();
    let reg = s.take_shared<TermsRegistry>();
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    let mut payment = mint_haneul(&mut s, 100);
    let lic =
        license::mint<HANEUL>(&cfg, &mut asset, &reg, terms_id, &mut payment, 0, &clock, s.ctx());
    license::keep(lic, s.ctx());
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::protocol::EPaused)]
fun pause_blocks_owner_claim() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, cap_id) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    pay_royalty(&mut s, CAROL, ip_id, 1_000, &clock);
    set_paused(&mut s, true);

    s.next_tx(ALICE);
    let cfg = s.take_shared<ProtocolConfig>();
    let mut asset = s.take_shared_by_id<IPAsset>(ip_id);
    let cap = s.take_from_sender_by_id<IPOwnerCap>(cap_id);
    let claimed = royalty::claim_owner<HANEUL>(&cfg, &mut asset, &cap, s.ctx());
    transfer::public_transfer(claimed, ALICE);
    abort 99
}

/// The breaker is two-way: unpausing resumes the exact same call.
#[test]
fun unpause_resumes_payments() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    set_paused(&mut s, true);
    set_paused(&mut s, false);
    pay_royalty(&mut s, CAROL, ip_id, 1_000, &clock);

    s.next_tx(ALICE);
    let asset = s.take_shared_by_id<IPAsset>(ip_id);
    assert!(ip::claimable_by_owner<HANEUL>(&asset) == 1_000);
    ts::return_shared(asset);
    clock.destroy_for_testing();
    s.end();
}

/// Cap handoff: the new holder can pull the levers.
#[test]
fun cap_handoff_moves_admin_rights() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    s.next_tx(ADMIN);
    let cap = s.take_from_sender<ProtocolCap>();
    protocol::transfer_cap(cap, ALICE);

    s.next_tx(ALICE);
    let mut cfg = s.take_shared<ProtocolConfig>();
    let cap = s.take_from_sender<ProtocolCap>();
    protocol::set_fee_bps(&mut cfg, &cap, 250);
    assert!(protocol::fee_bps(&cfg) == 250);
    s.return_to_sender(cap);
    ts::return_shared(cfg);
    s.end();
}

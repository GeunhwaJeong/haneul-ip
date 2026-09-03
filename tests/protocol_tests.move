// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Tests for `haneul_ip::protocol`: the fee switch (mechanism only,
/// starts at zero) and the circuit breaker over inflows and claims.
#[test_only]
module haneul_ip::protocol_tests;

use haneul::coin::Coin;
use haneul::event;
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
    stale_config,
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
    // The event carries amount and currency, so a multi-currency
    // treasury reconciles from the event stream alone.
    let fee_events = event::events_by_type<protocol::FeeCollected>();
    assert!(fee_events.length() == 1);
    let (amount, coin_type) = protocol::fee_collected_fields(&fee_events[0]);
    assert!(amount == 50);
    assert!(coin_type == std::type_name::with_defining_ids<HANEUL>());

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

/// After a package upgrade, the previous package's entry points must
/// not keep writing state: the version gate inside `assert_running`
/// shuts every money path until `migrate` runs.
#[test]
#[expected_failure(abort_code = haneul_ip::protocol::EWrongVersion)]
fun stale_version_blocks_money_paths() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    let clock = new_clock(&mut s);
    let terms_id = std_terms(&mut s, 1_000, 0);
    let (ip_id, _) = root_with_terms(&mut s, ALICE, 1, terms_id, &clock);
    stale_config(&mut s);
    pay_royalty(&mut s, CAROL, ip_id, 1_000, &clock);
    abort 99
}

#[test]
fun migrate_bumps_stale_config() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    stale_config(&mut s);
    s.next_tx(ADMIN);
    let mut cfg = s.take_shared<ProtocolConfig>();
    let cap = s.take_from_sender<ProtocolCap>();
    protocol::migrate(&mut cfg, &cap);
    assert!(protocol::version(&cfg) == 1);
    s.return_to_sender(cap);
    ts::return_shared(cfg);
    s.end();
}

/// A replayed migrate (or one against a config already current) is
/// rejected instead of silently re-emitting events.
#[test]
#[expected_failure(abort_code = haneul_ip::protocol::ENotUpgrade)]
fun migrate_at_current_version_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    s.next_tx(ADMIN);
    let mut cfg = s.take_shared<ProtocolConfig>();
    let cap = s.take_from_sender<ProtocolCap>();
    protocol::migrate(&mut cfg, &cap);
    abort 99
}

// === Cap handoff (propose -> accept -> execute) ===

fun propose(s: &mut Scenario, to: address) {
    s.next_tx(ADMIN);
    let mut cfg = s.take_shared<ProtocolConfig>();
    let cap = s.take_from_sender<ProtocolCap>();
    protocol::propose_cap_transfer(&mut cfg, &cap, to);
    s.return_to_sender(cap);
    ts::return_shared(cfg);
}

fun accept_as(s: &mut Scenario, who: address) {
    s.next_tx(who);
    let mut cfg = s.take_shared<ProtocolConfig>();
    protocol::accept_cap_transfer(&mut cfg, s.ctx());
    ts::return_shared(cfg);
}

fun execute(s: &mut Scenario) {
    s.next_tx(ADMIN);
    let mut cfg = s.take_shared<ProtocolConfig>();
    let cap = s.take_from_sender<ProtocolCap>();
    protocol::execute_cap_transfer(&mut cfg, cap);
    ts::return_shared(cfg);
}

/// The full handoff: the recipient counter-signs before the cap
/// moves, and can pull the levers afterwards.
#[test]
fun cap_handoff_three_steps_move_admin_rights() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    propose(&mut s, ALICE);
    accept_as(&mut s, ALICE);
    execute(&mut s);

    s.next_tx(ALICE);
    let mut cfg = s.take_shared<ProtocolConfig>();
    // The proposal is consumed by execution.
    assert!(protocol::pending_admin(&cfg).is_none());
    let cap = s.take_from_sender<ProtocolCap>();
    protocol::set_fee_bps(&mut cfg, &cap, 250);
    assert!(protocol::fee_bps(&cfg) == 250);
    s.return_to_sender(cap);
    ts::return_shared(cfg);
    s.end();
}

/// The typo scenario: only the proposed address can accept.
#[test]
#[expected_failure(abort_code = haneul_ip::protocol::ENotPendingAdmin)]
fun accept_by_wrong_address_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    propose(&mut s, ALICE);
    accept_as(&mut s, CAROL);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::protocol::ENoPendingTransfer)]
fun accept_without_proposal_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    accept_as(&mut s, ALICE);
    abort 99
}

/// The cap cannot move to an address that has not proven it can sign.
#[test]
#[expected_failure(abort_code = haneul_ip::protocol::ETransferNotAccepted)]
fun execute_before_accept_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    propose(&mut s, ALICE);
    execute(&mut s);
    abort 99
}

#[test]
#[expected_failure(abort_code = haneul_ip::protocol::ENoPendingTransfer)]
fun execute_without_proposal_aborts() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    execute(&mut s);
    abort 99
}

/// Cancelling voids the proposal and any acceptance already given.
#[test]
#[expected_failure(abort_code = haneul_ip::protocol::ENoPendingTransfer)]
fun cancel_voids_accepted_proposal() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    propose(&mut s, ALICE);
    accept_as(&mut s, ALICE);

    s.next_tx(ADMIN);
    let mut cfg = s.take_shared<ProtocolConfig>();
    let cap = s.take_from_sender<ProtocolCap>();
    protocol::cancel_cap_transfer(&mut cfg, &cap);
    assert!(protocol::pending_admin(&cfg).is_none());
    assert!(!protocol::pending_accepted(&cfg));
    s.return_to_sender(cap);
    ts::return_shared(cfg);

    execute(&mut s);
    abort 99
}

/// Re-proposing voids the earlier recipient's acceptance: the new
/// recipient must counter-sign for themselves.
#[test]
#[expected_failure(abort_code = haneul_ip::protocol::ETransferNotAccepted)]
fun repropose_resets_acceptance() {
    let mut s = ts::begin(ADMIN);
    setup(&mut s);
    propose(&mut s, ALICE);
    accept_as(&mut s, ALICE);
    propose(&mut s, CAROL);
    execute(&mut s);
    abort 99
}

// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Protocol-level levers shared by every money path in the package:
/// a circuit breaker and a fee switch.
///
/// Both exist for the same reason: a Move package upgrade cannot
/// retrofit them. Old entry points stay callable after an upgrade, so
/// a pause or a fee added in v2 could be bypassed by calling the v1
/// functions. They ship in the first mainnet publish or never.
///
/// The fee STARTS AT ZERO and this module only hard-bounds it to
/// 100%. What rate (if any) to ever charge, and whether to promise a
/// lower cap, is deliberately not decided here; that is business
/// policy, not mechanism.
module haneul_ip::protocol;

use haneul::coin::Coin;
use haneul::event;

const EPaused: u64 = 0;
const EFeeAboveMax: u64 = 1;

const BPS_DENOM: u64 = 10_000;

public struct ProtocolConfig has key {
    id: UID,
    version: u64,
    /// Receives the protocol's cut of every payment.
    treasury: address,
    /// Protocol fee in basis points of each payment. Starts at 0.
    fee_bps: u64,
    /// Circuit breaker over every money path: inflows (royalty
    /// payments, minting fees) AND claims. Freezing claims is a
    /// deliberate trade-off: it can stop a drain through a buggy
    /// withdrawal path, at the cost of giving the cap holder the
    /// power to freeze user funds. Intentionally NOT gated on
    /// anything else: an emergency lever must never be hostage to a
    /// migration or a config state.
    paused: bool,
}

/// Admin capability. `key`-only on purpose: it can never leave the
/// module's own transfer functions, so its custody rules are frozen
/// at publish time.
public struct ProtocolCap has key { id: UID }

public struct FeeSet has copy, drop { fee_bps: u64 }
public struct TreasurySet has copy, drop { treasury: address }
public struct PauseSet has copy, drop { paused: bool }
public struct FeeCollected has copy, drop { amount: u64 }

fun init(ctx: &mut TxContext) {
    transfer::share_object(ProtocolConfig {
        id: object::new(ctx),
        version: 1,
        treasury: ctx.sender(),
        fee_bps: 0,
        paused: false,
    });
    transfer::transfer(ProtocolCap { id: object::new(ctx) }, ctx.sender());
}

/// Every money-moving function in the package calls this first.
public fun assert_running(cfg: &ProtocolConfig) {
    assert!(!cfg.paused, EPaused);
}

/// Takes the protocol's cut out of `payment` and sends it to the
/// treasury. A no-op while the fee is 0. Returns the amount taken.
public(package) fun collect<T>(
    cfg: &ProtocolConfig,
    payment: &mut Coin<T>,
    ctx: &mut TxContext,
): u64 {
    let fee =
        ((payment.value() as u128) * (cfg.fee_bps as u128) / (BPS_DENOM as u128)) as u64;
    if (fee == 0) return 0;
    transfer::public_transfer(payment.split(fee, ctx), cfg.treasury);
    event::emit(FeeCollected { amount: fee });
    fee
}

public fun set_fee_bps(cfg: &mut ProtocolConfig, _cap: &ProtocolCap, fee_bps: u64) {
    assert!(fee_bps <= BPS_DENOM, EFeeAboveMax);
    cfg.fee_bps = fee_bps;
    event::emit(FeeSet { fee_bps });
}

public fun set_treasury(cfg: &mut ProtocolConfig, _cap: &ProtocolCap, treasury: address) {
    cfg.treasury = treasury;
    event::emit(TreasurySet { treasury });
}

/// The emergency lever. Intentionally has no precondition beyond the
/// cap itself.
public fun set_paused(cfg: &mut ProtocolConfig, _cap: &ProtocolCap, paused: bool) {
    cfg.paused = paused;
    event::emit(PauseSet { paused });
}

/// One-step cap handoff.
/// TODO before any mainnet publish: replace with the three-step
/// propose -> accept -> execute handoff (receiver must sign), so a
/// typoed address cannot orphan the protocol.
public fun transfer_cap(cap: ProtocolCap, to: address) {
    transfer::transfer(cap, to);
}

public fun fee_bps(cfg: &ProtocolConfig): u64 { cfg.fee_bps }

public fun treasury(cfg: &ProtocolConfig): address { cfg.treasury }

public fun is_paused(cfg: &ProtocolConfig): bool { cfg.paused }

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

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
///
/// The version gate is the third such one-way door. Every
/// state-writing entry point in the package asserts that the shared
/// object it touches matches the package VERSION, so after an upgrade
/// the stale entry points of the previous package can be shut off by
/// bumping the stored version (`migrate`). Only the singleton objects
/// are gated; see `IPAsset.version` in `ip.move` for why the assets
/// themselves are not.
module haneul_ip::protocol;

use haneul::coin::Coin;
use haneul::event;
use std::type_name::{Self, TypeName};

const EPaused: u64 = 0;
const EFeeAboveMax: u64 = 1;
const EWrongVersion: u64 = 2;
const ENotUpgrade: u64 = 3;
const ENoPendingTransfer: u64 = 4;
const ENotPendingAdmin: u64 = 5;
const ETransferNotAccepted: u64 = 6;

const BPS_DENOM: u64 = 10_000;
/// Bumped together with any package upgrade that must invalidate the
/// previous package's entry points.
const VERSION: u64 = 1;

public struct ProtocolConfig has key {
    id: UID,
    /// Package version this object was last migrated to. Checked by
    /// every state-writing entry point; bumped by `migrate` after a
    /// package upgrade.
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
    /// The address a cap handoff has been proposed to, if any.
    pending_admin: Option<address>,
    /// Whether the proposed recipient has counter-signed. Only an
    /// accepted proposal can be executed.
    pending_accepted: bool,
}

/// Admin capability. `key`-only on purpose: it can never leave the
/// module's own transfer functions, so its custody rules are frozen
/// at publish time.
public struct ProtocolCap has key { id: UID }

public struct FeeSet has copy, drop { fee_bps: u64 }
public struct ConfigMigrated has copy, drop { version: u64 }
public struct CapTransferProposed has copy, drop { to: address }
public struct CapTransferAccepted has copy, drop { by: address }
public struct CapTransferExecuted has copy, drop { to: address }
public struct CapTransferCancelled has copy, drop {}
public struct TreasurySet has copy, drop { treasury: address }
public struct PauseSet has copy, drop { paused: bool }
/// Carries the coin type so the treasury's event stream reconciles
/// per currency without re-reading each transaction.
public struct FeeCollected has copy, drop { amount: u64, coin_type: TypeName }

fun init(ctx: &mut TxContext) {
    transfer::share_object(ProtocolConfig {
        id: object::new(ctx),
        version: VERSION,
        treasury: ctx.sender(),
        fee_bps: 0,
        paused: false,
        pending_admin: option::none(),
        pending_accepted: false,
    });
    transfer::transfer(ProtocolCap { id: object::new(ctx) }, ctx.sender());
}

/// Every money-moving function in the package calls this first.
public fun assert_running(cfg: &ProtocolConfig) {
    assert_current_version(cfg);
    assert!(!cfg.paused, EPaused);
}

/// The version gate alone. State-writing paths that must not freeze
/// on pause (registration is not a money path) call this directly.
/// After a package upgrade the previous package's entry points stay
/// callable forever; bumping the stored version via `migrate` is what
/// shuts them off, and this assert is where they stop.
public fun assert_current_version(cfg: &ProtocolConfig) {
    assert!(cfg.version == VERSION, EWrongVersion);
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
    event::emit(FeeCollected { amount: fee, coin_type: type_name::with_defining_ids<T>() });
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

// === Cap handoff: propose -> accept -> execute ===
//
// The cap is the whole protocol; a one-step transfer to a typoed
// address would orphan it forever. The three-step handoff makes that
// impossible: the cap only ever moves to an address that has already
// proven, with its own signature, that someone controls it.

/// Step 1: the holder names the intended recipient. Re-proposing
/// overwrites any earlier proposal and voids its acceptance.
public fun propose_cap_transfer(cfg: &mut ProtocolConfig, _cap: &ProtocolCap, to: address) {
    cfg.pending_admin = option::some(to);
    cfg.pending_accepted = false;
    event::emit(CapTransferProposed { to });
}

/// Step 2: the recipient counter-signs. This is what makes a typo
/// harmless: an address nobody controls can never produce this
/// signature, so the cap can never be executed into the void.
public fun accept_cap_transfer(cfg: &mut ProtocolConfig, ctx: &TxContext) {
    assert!(cfg.pending_admin.is_some(), ENoPendingTransfer);
    assert!(*cfg.pending_admin.borrow() == ctx.sender(), ENotPendingAdmin);
    cfg.pending_accepted = true;
    event::emit(CapTransferAccepted { by: ctx.sender() });
}

/// Step 3: the holder hands the cap to the accepted recipient and the
/// proposal is consumed.
public fun execute_cap_transfer(cfg: &mut ProtocolConfig, cap: ProtocolCap) {
    assert!(cfg.pending_admin.is_some(), ENoPendingTransfer);
    assert!(cfg.pending_accepted, ETransferNotAccepted);
    let to = cfg.pending_admin.extract();
    cfg.pending_accepted = false;
    transfer::transfer(cap, to);
    event::emit(CapTransferExecuted { to });
}

/// The holder may withdraw a proposal any time before execution.
public fun cancel_cap_transfer(cfg: &mut ProtocolConfig, _cap: &ProtocolCap) {
    cfg.pending_admin = option::none();
    cfg.pending_accepted = false;
    event::emit(CapTransferCancelled {});
}

/// Brings a config left behind by a package upgrade up to the
/// current version, unfreezing the gated entry points. Rejects a
/// same-version call so it cannot be replayed.
public fun migrate(cfg: &mut ProtocolConfig, _cap: &ProtocolCap) {
    assert!(cfg.version < VERSION, ENotUpgrade);
    cfg.version = VERSION;
    event::emit(ConfigMigrated { version: VERSION });
}

public fun version(cfg: &ProtocolConfig): u64 { cfg.version }

public fun pending_admin(cfg: &ProtocolConfig): Option<address> { cfg.pending_admin }

public fun pending_accepted(cfg: &ProtocolConfig): bool { cfg.pending_accepted }

public fun fee_bps(cfg: &ProtocolConfig): u64 { cfg.fee_bps }

public fun treasury(cfg: &ProtocolConfig): address { cfg.treasury }

public fun is_paused(cfg: &ProtocolConfig): bool { cfg.paused }

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

#[test_only]
public fun set_version_for_testing(cfg: &mut ProtocolConfig, version: u64) {
    cfg.version = version;
}

#[test_only]
public fun fee_collected_fields(e: &FeeCollected): (u64, TypeName) {
    (e.amount, e.coin_type)
}

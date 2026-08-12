// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// The license object: a right, sold by an IP, to register a
/// derivative (or simply to hold as proof of licensed use).
///
/// Story models this as an ERC-721 with a transfer hook that reverts
/// for non-transferable licenses. Here the object is `key`-only, so
/// it can never move through generic transfer at all; the ONLY way it
/// changes hands is `transfer_license` below, which checks the flag.
/// The 100-line hook becomes one missing ability.
///
/// Terms values (fee, revenue share) are snapshotted at mint time:
/// the licensor changing their config later must not rewrite a
/// license someone already paid for.
module haneul_ip::license;

use haneul::clock::Clock;
use haneul::coin::Coin;
use haneul::event;
use haneul_ip::ip::{Self, IPAsset};
use haneul_ip::protocol::{Self, ProtocolConfig};
use haneul_ip::terms::{Self, TermsRegistry};
use std::type_name;

const ETermsNotAttached: u64 = 0;
const ENotReciprocal: u64 = 1;
const EWrongCurrency: u64 = 2;
const EFeeAboveMax: u64 = 3;
const ENotTransferable: u64 = 4;
const EInsufficientPayment: u64 = 5;
const EFeeRequired: u64 = 6;

public struct License has key {
    id: UID,
    licensor: ID,
    terms_id: u64,
    /// Effective revenue share at mint time (config override applied).
    rev_share_bps: u64,
    transferable: bool,
}

public struct LicenseMinted has copy, drop {
    license: ID,
    licensor: ID,
    terms_id: u64,
    receiver: address,
    fee_paid: u64,
    rev_share_bps: u64,
}

public struct LicenseTransferred has copy, drop {
    license: ID,
    to: address,
}

/// Mints one license against terms attached to `licensor_ip`, paying
/// the effective minting fee out of `payment`.
///
/// `max_fee` is a slippage guard (0 = no limit): the licensor can
/// change the fee via `set_licensing_config` between the buyer
/// signing and the transaction executing, so the buyer states the
/// most they agreed to pay.
///
/// The fee is deposited into the licensor's own revenue pool, which
/// means the licensor's ancestors take their royalty cut of minting
/// fees too — same money route as Story's `payLicenseMintingFee`.
public fun mint<T>(
    cfg: &ProtocolConfig,
    licensor_ip: &mut IPAsset,
    reg: &TermsRegistry,
    terms_id: u64,
    receiver: address,
    payment: &mut Coin<T>,
    max_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    protocol::assert_running(cfg);
    ip::assert_alive(licensor_ip, clock);
    assert!(licensor_ip.has_terms(terms_id), ETermsNotAttached);
    licensor_ip.assert_config_enabled(terms_id);
    let t = terms::get(reg, terms_id);
    // A derivative only re-licenses terms marked reciprocal
    // (derivatives of derivatives need the parent's permission chain).
    if (licensor_ip.is_derivative()) {
        assert!(terms::derivatives_reciprocal(t), ENotReciprocal);
    };

    let fee = licensor_ip.effective_minting_fee(terms_id, t);
    if (fee > 0) {
        assert!(type_name::with_defining_ids<T>() == terms::currency(t), EWrongCurrency);
        assert!(max_fee == 0 || fee <= max_fee, EFeeAboveMax);
        assert!(payment.value() >= fee, EInsufficientPayment);
        let mut fee_coin = payment.split(fee, ctx);
        protocol::collect(cfg, &mut fee_coin, ctx);
        licensor_ip.deposit(fee_coin);
    };

    let license = License {
        id: object::new(ctx),
        licensor: object::id(licensor_ip),
        terms_id,
        rev_share_bps: licensor_ip.effective_rev_share_bps(terms_id, t),
        transferable: terms::transferable(t),
    };
    let license_id = object::id(&license);
    licensor_ip.note_license_minted();
    event::emit(LicenseMinted {
        license: license_id,
        licensor: object::id(licensor_ip),
        terms_id,
        receiver,
        fee_paid: fee,
        rev_share_bps: license.rev_share_bps,
    });
    transfer::transfer(license, receiver);
    license_id
}

/// Convenience path for free terms — no payment coin needed.
public fun mint_free(
    cfg: &ProtocolConfig,
    licensor_ip: &mut IPAsset,
    reg: &TermsRegistry,
    terms_id: u64,
    receiver: address,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    protocol::assert_running(cfg);
    ip::assert_alive(licensor_ip, clock);
    assert!(licensor_ip.has_terms(terms_id), ETermsNotAttached);
    licensor_ip.assert_config_enabled(terms_id);
    let t = terms::get(reg, terms_id);
    if (licensor_ip.is_derivative()) {
        assert!(terms::derivatives_reciprocal(t), ENotReciprocal);
    };
    assert!(licensor_ip.effective_minting_fee(terms_id, t) == 0, EFeeRequired);

    let license = License {
        id: object::new(ctx),
        licensor: object::id(licensor_ip),
        terms_id,
        rev_share_bps: licensor_ip.effective_rev_share_bps(terms_id, t),
        transferable: terms::transferable(t),
    };
    let license_id = object::id(&license);
    licensor_ip.note_license_minted();
    event::emit(LicenseMinted {
        license: license_id,
        licensor: object::id(licensor_ip),
        terms_id,
        receiver,
        fee_paid: 0,
        rev_share_bps: license.rev_share_bps,
    });
    transfer::transfer(license, receiver);
    license_id
}

/// The only way a `License` changes hands.
public fun transfer_license(license: License, to: address) {
    assert!(license.transferable, ENotTransferable);
    event::emit(LicenseTransferred { license: object::id(&license), to });
    transfer::transfer(license, to);
}

/// Consumed by `derivative::add_parent*`; returns what linking needs.
public(package) fun burn(license: License): (ID, u64, u64) {
    let License { id, licensor, terms_id, rev_share_bps, transferable: _ } = license;
    id.delete();
    (licensor, terms_id, rev_share_bps)
}

public fun licensor(license: &License): ID { license.licensor }

public fun terms_id(license: &License): u64 { license.terms_id }

public fun rev_share_bps(license: &License): u64 { license.rev_share_bps }

public fun is_transferable(license: &License): bool { license.transferable }

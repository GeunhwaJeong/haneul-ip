// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// The license object: a right, sold by an IP, to register a
/// derivative (or simply to hold as proof of licensed use).
///
/// `mint` RETURNS the license instead of delivering it, so one
/// transaction can buy a license and immediately consume it to
/// register a derivative. Call `keep` to take custody when holding is
/// the goal.
///
/// The object is `key`-only, so it can never move through generic
/// transfer at all; the only ways it moves are `keep` (to the
/// transaction sender, the initial delivery) and `transfer_license`,
/// which checks the transferable flag. Non-transferability is a
/// missing ability, not a hook.
///
/// Approval-gated terms are enforced HERE, at mint time: the buyer
/// must already be on the licensor's allowlist, so consent exists
/// on-chain before any money moves. No one can end up holding a paid
/// license they were never allowed to use. Transfer cannot carry the
/// consent to an unapproved party either: approval-gated terms are
/// always non-transferable (`terms::register` rejects the
/// combination).
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
use haneul_ip::terms::{Self, Terms, TermsRegistry};
use std::type_name;

#[error(code = 0)]
const ETermsNotAttached: vector<u8> = b"These terms are not attached to the licensor IP.";
#[error(code = 1)]
const ENotReciprocal: vector<u8> = b"A derivative can only license terms marked reciprocal.";
#[error(code = 2)]
const EWrongCurrency: vector<u8> = b"The payment coin type does not match the terms' currency.";
#[error(code = 3)]
const EFeeAboveMax: vector<u8> = b"The minting fee exceeds the buyer's stated maximum.";
#[error(code = 4)]
const ENotTransferable: vector<u8> = b"This license is not transferable.";
#[error(code = 5)]
const EInsufficientPayment: vector<u8> = b"The payment does not cover the minting fee.";
#[error(code = 6)]
const EFeeRequired: vector<u8> = b"These terms charge a minting fee; use mint instead.";
#[error(code = 7)]
const ENotApprovedLicensee: vector<u8> = b"The minter is not on the licensor's approval allowlist.";

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
    minter: address,
    fee_paid: u64,
    rev_share_bps: u64,
}

public struct LicenseTransferred has copy, drop {
    license: ID,
    to: address,
}

/// Mints one license against terms attached to `licensor_ip`, paying
/// the effective minting fee out of `payment`, and returns it for the
/// caller to keep or consume.
///
/// `max_fee` is a slippage guard (0 = no limit): the licensor can
/// change the fee via `set_licensing_config` between the buyer
/// signing and the transaction executing, so the buyer states the
/// most they agreed to pay.
///
/// The fee is deposited into the licensor's own revenue pool, which
/// means the licensor's ancestors take their royalty cut of minting
/// fees too: a minting fee is revenue like any other.
public fun mint<T>(
    cfg: &mut ProtocolConfig,
    licensor_ip: &mut IPAsset,
    reg: &TermsRegistry,
    terms_id: u64,
    payment: &mut Coin<T>,
    max_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): License {
    let t = verify_mint(cfg, licensor_ip, reg, terms_id, clock, ctx);

    let fee = licensor_ip.effective_minting_fee(terms_id, &t);
    if (fee > 0) {
        assert!(type_name::with_defining_ids<T>() == terms::currency(&t), EWrongCurrency);
        assert!(max_fee == 0 || fee <= max_fee, EFeeAboveMax);
        assert!(payment.value() >= fee, EInsufficientPayment);
        let mut fee_coin = payment.split(fee, ctx);
        protocol::collect(cfg, &mut fee_coin);
        licensor_ip.deposit(fee_coin);
    };

    issue(licensor_ip, terms_id, &t, fee, ctx)
}

/// Convenience path for free terms; no payment coin needed.
public fun mint_free(
    cfg: &ProtocolConfig,
    licensor_ip: &mut IPAsset,
    reg: &TermsRegistry,
    terms_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): License {
    let t = verify_mint(cfg, licensor_ip, reg, terms_id, clock, ctx);
    assert!(licensor_ip.effective_minting_fee(terms_id, &t) == 0, EFeeRequired);
    issue(licensor_ip, terms_id, &t, 0, ctx)
}

/// Takes custody of a license as the transaction sender. Initial
/// delivery to the buyer is not a transfer between parties, so the
/// transferable flag is not consulted.
public fun keep(license: License, ctx: &TxContext) {
    transfer::transfer(license, ctx.sender());
}

/// The only way a `License` moves between parties.
public fun transfer_license(license: License, to: address) {
    assert!(license.transferable, ENotTransferable);
    event::emit(LicenseTransferred { license: object::id(&license), to });
    transfer::transfer(license, to);
}

/// Consumed by `derivative::add_parent`; returns what linking needs.
public(package) fun burn(license: License): (ID, u64, u64) {
    let License { id, licensor, terms_id, rev_share_bps, transferable: _ } = license;
    id.delete();
    (licensor, terms_id, rev_share_bps)
}

/// The gates every mint passes, in one place. Returns the terms by
/// copy so fee and snapshot logic read one consistent version.
fun verify_mint(
    cfg: &ProtocolConfig,
    licensor_ip: &IPAsset,
    reg: &TermsRegistry,
    terms_id: u64,
    clock: &Clock,
    ctx: &TxContext,
): Terms {
    protocol::assert_running(cfg);
    ip::assert_alive(licensor_ip, clock);
    assert!(licensor_ip.has_terms(terms_id), ETermsNotAttached);
    licensor_ip.assert_config_enabled(terms_id);
    let t = *terms::get(reg, terms_id);
    // A derivative only re-licenses terms marked reciprocal
    // (derivatives of derivatives need the permission to flow down).
    if (licensor_ip.is_derivative()) {
        assert!(terms::derivatives_reciprocal(&t), ENotReciprocal);
    };
    // Approval-gated terms: consent must already be on-chain.
    if (terms::derivatives_approval(&t)) {
        assert!(licensor_ip.is_approved_licensee(ctx.sender()), ENotApprovedLicensee);
    };
    t
}

fun issue(
    licensor_ip: &mut IPAsset,
    terms_id: u64,
    t: &Terms,
    fee_paid: u64,
    ctx: &mut TxContext,
): License {
    let license = License {
        id: object::new(ctx),
        licensor: object::id(licensor_ip),
        terms_id,
        rev_share_bps: licensor_ip.effective_rev_share_bps(terms_id, t),
        transferable: terms::transferable(t),
    };
    licensor_ip.note_license_minted();
    event::emit(LicenseMinted {
        license: object::id(&license),
        licensor: object::id(licensor_ip),
        terms_id,
        minter: ctx.sender(),
        fee_paid,
        rev_share_bps: license.rev_share_bps,
    });
    license
}

public fun licensor(license: &License): ID { license.licensor }

public fun terms_id(license: &License): u64 { license.terms_id }

public fun rev_share_bps(license: &License): u64 { license.rev_share_bps }

public fun is_transferable(license: &License): bool { license.transferable }

// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Package identity: the one-time witness, the `Publisher` claim and
/// the `Display` templates wallets and explorers render this
/// package's objects with.
///
/// This module must ship in the first publish. A one-time witness
/// only exists inside `init`, and the `Publisher` it claims is the
/// only authority that can ever create or edit `Display` for the
/// package's types; skip it once and the objects stay unrenderable
/// forever.
module haneul_ip::haneul_ip;

use haneul::display;
use haneul::package;
use haneul_ip::ip::IPAsset;
use haneul_ip::license::License;
use std::string::utf8;

/// One-time witness: proves this code ran exactly once, at publish.
public struct HANEUL_IP has drop {}

fun init(otw: HANEUL_IP, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);

    // {field} placeholders are resolved per object from the object's
    // own fields by the fullnode's display resolution.
    let mut ip_display = display::new<IPAsset>(&publisher, ctx);
    ip_display.add(utf8(b"name"), utf8(b"{name}"));
    ip_display.add(
        utf8(b"description"),
        utf8(b"A registered IP asset. Licensing, derivatives and royalties settle on chain."),
    );
    // `uri` points at the work itself; when it is not an image,
    // wallets simply render no thumbnail.
    ip_display.add(utf8(b"image_url"), utf8(b"{uri}"));
    ip_display.add(utf8(b"link"), utf8(b"{uri}"));
    ip_display.add(utf8(b"creator"), utf8(b"{creator}"));
    ip_display.update_version();

    let mut license_display = display::new<License>(&publisher, ctx);
    license_display.add(utf8(b"name"), utf8(b"IP License (terms {terms_id})"));
    license_display.add(
        utf8(b"description"),
        utf8(b"A license minted by IP asset {licensor} under terms {terms_id}."),
    );
    license_display.update_version();

    // Publisher and Display objects stay editable by their holder;
    // they belong with the deployer, alongside the ProtocolCap.
    transfer::public_transfer(publisher, ctx.sender());
    transfer::public_transfer(ip_display, ctx.sender());
    transfer::public_transfer(license_display, ctx.sender());
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(HANEUL_IP {}, ctx)
}

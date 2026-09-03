// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Tests for `haneul_ip::haneul_ip`: the Publisher claim and the
/// Display templates created at publish.
#[test_only]
module haneul_ip::display_tests;

use haneul::display::Display;
use haneul::package::Publisher;
use haneul::test_scenario::{Self as ts};
use haneul_ip::haneul_ip;
use haneul_ip::ip::IPAsset;
use haneul_ip::license::License;

const ADMIN: address = @0xAD;

/// The deployer ends up holding the package's Display authority and
/// one populated template per renderable type.
#[test]
fun init_claims_publisher_and_creates_displays() {
    let mut s = ts::begin(ADMIN);
    s.next_tx(ADMIN);
    haneul_ip::init_for_testing(s.ctx());

    s.next_tx(ADMIN);
    let publisher = s.take_from_sender<Publisher>();
    assert!(publisher.from_package<IPAsset>());
    assert!(publisher.from_package<License>());

    let ip_display = s.take_from_sender<Display<IPAsset>>();
    assert!(ip_display.fields().length() == 5);
    // Templates only render once their version is published.
    assert!(ip_display.version() == 1);

    let license_display = s.take_from_sender<Display<License>>();
    assert!(license_display.fields().length() == 2);
    assert!(license_display.version() == 1);

    s.return_to_sender(publisher);
    s.return_to_sender(ip_display);
    s.return_to_sender(license_display);
    s.end();
}

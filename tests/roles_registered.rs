//! `#[role]` registers each role in the binary (telepatch `roles()`), which
//! `run --only` checks names against before any host is contacted.

#[test]
fn roles_holds_dev_common() {
    // Referencing the library keeps its roles linked into this test binary.
    let _ = tp_basic::roles::dev_common::dev_common;
    assert!(telepatch::roles().contains(&"dev_common"));
}

#[test]
fn roles_holds_root_user() {
    let _ = tp_basic::roles::root_user::root_user;
    assert!(telepatch::roles().contains(&"root_user"));
}

#[test]
fn roles_holds_hashicorp_packer() {
    let _ = tp_basic::roles::hashicorp_packer::hashicorp_packer;
    assert!(telepatch::roles().contains(&"hashicorp_packer"));
}

#[test]
fn roles_holds_h11ssl_reboot_fix() {
    let _ = tp_basic::roles::h11ssl_reboot_fix::h11ssl_reboot_fix;
    assert!(telepatch::roles().contains(&"h11ssl_reboot_fix"));
}

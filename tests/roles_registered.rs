//! `#[role]` registers each role in the binary (telepatch `roles()`), which
//! `run --only` checks names against before any host is contacted.

#[test]
fn roles_holds_dev_common() {
    // Referencing the library keeps its roles linked into this test binary.
    let _ = tp_basic::roles::dev_common::dev_common;
    assert!(telepatch::roles().contains(&"dev_common"));
}

use tp_basic::vars::Vars;

#[test]
fn container_vars_parse() {
    let text = std::fs::read_to_string("vars/container.toml").unwrap();
    let v: Vars = toml::from_str(&text).unwrap();
    assert_eq!(v.admin_users, vec!["root".to_string()]);
    assert_eq!(v.rustup_version, "1.29.0");
    assert_eq!(v.cargo_version, "1.94.0");
    assert_eq!(v.rustc_version, "1.94.0");
}

#[test]
fn binary_lists_no_playbooks_yet() {
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_tp-basic"))
        .arg("list")
        .output()
        .unwrap();
    assert!(out.status.success(), "{:?}", out);
}

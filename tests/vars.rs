use std::path::Path;

use telepatch::vars::{load, load_file};
use tp_basic::vars::Vars;

fn shipped(name: &str) -> Vars {
    load_file(Some(Path::new(&format!("vars/{name}.toml"))), "").unwrap()
}

fn users(xs: &[&str]) -> Vec<String> {
    xs.iter().map(|s| s.to_string()).collect()
}

#[test]
fn container_vars_load_into_the_role_sections() {
    let v = shipped("container");
    assert_eq!(v.admin_users.admin_users, users(&["root"]));
    assert_eq!(v.admin_users.default_password, "");
    assert_eq!(v.docker.admin_users, users(&["root"]));
    assert_eq!(v.vm_server.admin_users, users(&["root"]));
    assert_eq!(v.rust_kernel.admin_users, users(&["root"]));
    assert_eq!(v.rust_build.admin_users, users(&["root"]));
    assert_eq!(v.rust_build.rustc_version, "1.94.0");
    // the shipped container file is what the roles default to
    assert_eq!(v, Vars::default());
}

#[test]
fn desktop_vars_reach_every_role_with_the_field() {
    let v = shipped("desktop");
    let bot = users(&["bot", "tpdev"]);
    assert_eq!(v.admin_users.admin_users, bot);
    assert_eq!(v.docker.admin_users, bot);
    assert_eq!(v.vm_server.admin_users, bot);
    assert_eq!(v.rust_kernel.admin_users, bot);
    assert_eq!(v.rust_build.admin_users, bot);
    assert_eq!(v.admin_users.default_password, "");
    assert_eq!(v.rust_build.rustc_version, "1.94.0");
}

#[test]
fn no_file_is_an_empty_file() {
    let none: Vars = load_file(None, "").unwrap();
    assert_eq!(none, load("v", "", "").unwrap());
}

#[test]
fn a_section_overrides_the_top_level_for_that_role_only() {
    let v: Vars = load(
        "v",
        "admin_users = [\"a\"]\n[docker]\nadmin_users = [\"d\"]\n",
        "",
    )
    .unwrap();
    assert_eq!(v.docker.admin_users, users(&["d"]));
    assert_eq!(v.admin_users.admin_users, users(&["a"]));
    assert_eq!(v.rust_build.admin_users, users(&["a"]));
}

#[test]
fn dropped_version_pins_are_errors_naming_the_line() {
    for key in ["rustup_version", "cargo_version"] {
        let m = load::<Vars>(
            "v.toml",
            &format!("admin_users = [\"root\"]\n{key} = \"1\"\n"),
            "",
        )
        .unwrap_err();
        assert!(m.starts_with("v.toml:2:") && m.contains(key), "{m}");
    }
}

#[test]
fn a_misspelled_role_field_is_an_error() {
    let m = load::<Vars>("v.toml", "[rust_build]\nrustc = \"1\"\n", "").unwrap_err();
    assert!(m.starts_with("v.toml:2:") && m.contains("rustc"), "{m}");
}

#[test]
fn binary_lists_no_playbooks_yet() {
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_tp-basic"))
        .arg("list")
        .output()
        .unwrap();
    assert!(out.status.success(), "{:?}", out);
}

fn services_vm_playbook() -> telepatch::Playbook<Vars> {
    tp_basic::playbooks()
        .into_iter()
        .find(|p| p.name == "services_vm")
        .unwrap()
}

#[test]
fn a_playbook_default_beats_the_roles_own_default() {
    // layer 3 over layer 4, for `services_vm` only
    let v: Vars = telepatch::vars::load_for(&services_vm_playbook(), "v", "").unwrap();
    assert_eq!(
        v.services_vm.probe_description,
        "telepatch services_vm probe"
    );
    assert_eq!(
        Vars::default().services_vm.probe_description,
        "telepatch probe (role default)"
    );
}

#[test]
fn a_vars_file_value_beats_the_playbook_default() {
    let v: Vars = telepatch::vars::load_for(
        &services_vm_playbook(),
        "v",
        "[services_vm]\nprobe_description = \"from the file\"\n",
    )
    .unwrap();
    assert_eq!(v.services_vm.probe_description, "from the file");
}

#[test]
fn only_services_vm_supplies_defaults() {
    for p in tp_basic::playbooks() {
        let has = !p.defaults_toml().unwrap().is_empty();
        assert_eq!(has, p.name == "services_vm", "{}", p.name);
    }
}

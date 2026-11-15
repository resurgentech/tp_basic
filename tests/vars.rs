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
    assert_eq!(v.admin_users.default_password, None);
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
    assert_eq!(v.admin_users.default_password, None);
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
fn only_the_test_playbooks_supply_defaults() {
    for p in tp_basic::playbooks() {
        let has = !p.defaults_toml().unwrap().is_empty();
        assert_eq!(
            has,
            p.name == "services_vm" || p.name == "reboot_vm",
            "{}",
            p.name
        );
    }
}

#[test]
fn systemd_time_zone_defaults_to_los_angeles_and_loads_from_a_section() {
    // `group_vars/all` of ansible_labtwo_2: iana_tz
    assert_eq!(Vars::default().systemd_time.iana_tz, "America/Los_Angeles");
    assert_eq!(
        shipped("container").systemd_time.iana_tz,
        "America/Los_Angeles"
    );
    let v: Vars = load("v", "[systemd_time]\niana_tz = \"Europe/Berlin\"\n", "").unwrap();
    assert_eq!(v.systemd_time.iana_tz, "Europe/Berlin");
    let v: Vars = load("v", "iana_tz = \"Asia/Tokyo\"\n", "").unwrap();
    assert_eq!(v.systemd_time.iana_tz, "Asia/Tokyo");
}

#[test]
fn hashicorp_packer_admin_users_default_to_root_and_follow_the_top_level_key() {
    assert_eq!(
        Vars::default().hashicorp_packer.admin_users,
        users(&["root"])
    );
    assert_eq!(
        shipped("container").hashicorp_packer.admin_users,
        users(&["root"])
    );
    let v: Vars = load("v", "admin_users = [\"a\", \"b\"]\n", "").unwrap();
    assert_eq!(v.hashicorp_packer.admin_users, users(&["a", "b"]));
    let v: Vars = load("v", "[hashicorp_packer]\nadmin_users = [\"c\"]\n", "").unwrap();
    assert_eq!(v.hashicorp_packer.admin_users, users(&["c"]));
}

/// The oracle case's vars file: the VM's login user, to both roles of the
/// case, as the Ansible side's `--extra-vars` gives it.
#[test]
fn labtwo_hashicorp_packer_vars_name_the_login_user_for_both_roles() {
    let v = shipped("labtwo_hashicorp_packer");
    assert_eq!(v.vm_server.admin_users, users(&["bot"]));
    assert_eq!(v.hashicorp_packer.admin_users, users(&["bot"]));
}

#[test]
fn cuda_vars_default_to_the_ubuntu_2404_values_and_follow_the_top_level_keys() {
    let d = Vars::default().cuda;
    assert_eq!(d.nvidia_driver_packages.len(), 3);
    assert_eq!(d.cuda_packages.len(), 10);
    assert_eq!(d.nvidia_container_toolkit_packages.len(), 4);
    assert_eq!(d.nvidia_container_toolkit_version, "1.19.0-1");
    assert_eq!(d.cuda_install_path, "/usr/local/cuda-13.2");
    assert!(
        d.cuda_keyring_url
            .contains("/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb")
    );
    assert_eq!(d.cuda_keyring_sha256.len(), 64);
    // the shipped container file is the defaults
    assert_eq!(shipped("container").cuda, d);
    let v: Vars = load("v", "cuda_packages = [\"nvtop\"]\n", "").unwrap();
    assert_eq!(v.cuda.cuda_packages, users(&["nvtop"]));
}

/// The oracle case's vars file: the same small lists as the Ansible side's
/// `-e` overrides (scripts/test-vm-oracle.sh, case labtwo_cuda).
#[test]
fn labtwo_cuda_vars_are_the_small_lists_and_nothing_else() {
    let v = shipped("labtwo_cuda").cuda;
    assert!(v.nvidia_driver_packages.is_empty());
    assert_eq!(v.cuda_packages, users(&["nvtop"]));
    let d = Vars::default().cuda;
    assert_eq!(v.cuda_keyring_url, d.cuda_keyring_url);
    assert_eq!(
        v.nvidia_container_toolkit_packages,
        d.nvidia_container_toolkit_packages
    );
    assert_eq!(
        v.nvidia_container_toolkit_version,
        d.nvidia_container_toolkit_version
    );
    assert_eq!(v.cuda_install_path, d.cuda_install_path);
}

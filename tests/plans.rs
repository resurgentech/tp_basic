//! Plan snapshots for `container/dev_base` on all 13 images.

use tp_basic::{playbooks, vars::Vars};

const DISTROS: [&str; 13] = [
    "debian12",
    "debian13",
    "ubuntu2404",
    "ubuntu2604",
    "fedora43",
    "fedora44",
    "rockylinux9",
    "rockylinux10",
    "almalinux9",
    "almalinux10",
    "amazonlinux2023",
    "arch",
    "omarchy",
];

fn plan(name: &str, distro: &str) -> String {
    let pbs = playbooks();
    let pb = pbs
        .iter()
        .find(|p| p.name == name)
        .unwrap_or_else(|| panic!("no playbook {name}"));
    telepatch::testing::plan_for(distro, pb, Vars::default())
}

#[test]
fn dev_base_plans() {
    for d in DISTROS {
        let text = plan("container/dev_base", d);
        insta::with_settings!({snapshot_path => "plans/snapshots"}, {
            insta::assert_snapshot!(format!("dev_base__{d}"), text);
        });
    }
}

#[test]
fn rust_build_plans() {
    for d in DISTROS {
        let text = plan("container/rust", d);
        insta::with_settings!({snapshot_path => "plans/snapshots"}, {
            insta::assert_snapshot!(format!("rust_build__{d}"), text);
        });
    }
}

/// The old repair and update branches read `bin_exists("cargo")` and
/// `bin_version("rustc")` per user. The `Rustup` and `Cargo` sources probe
/// on the host instead, so the plan has no fact reads and no `sh` op in the
/// per-user block, whatever state the host is in.
#[test]
fn rust_build_per_user_block_reads_no_facts() {
    let text = plan("container/rust", "ubuntu2404");
    assert!(text.contains("blocking reads: 0"), "{text}");
    assert!(text.contains("pkg[rustup] as login:root"), "{text}");
    assert!(text.contains("pkg[cargo] as login:root"), "{text}");
    let role = &text[text.find("role rust_build").expect("role rust_build")..];
    assert!(!role.contains("  sh as "), "{role}");
}

#[test]
fn kernel_build_plans() {
    for d in DISTROS {
        let text = plan("container/kernel_build", d);
        insta::with_settings!({snapshot_path => "plans/snapshots"}, {
            insta::assert_snapshot!(format!("kernel_build__{d}"), text);
        });
    }
}

#[test]
fn latest_kernel_build_plans() {
    for d in DISTROS {
        let text = plan("container/latest_kernel_build", d);
        insta::with_settings!({snapshot_path => "plans/snapshots"}, {
            insta::assert_snapshot!(format!("latest_kernel_build__{d}"), text);
        });
    }
}

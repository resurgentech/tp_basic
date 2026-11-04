//! Plan snapshots for the container playbooks and `dev_desktop` on all 13 images.

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

/// `vars/desktop.toml`, as `tp-basic run dev_desktop --vars vars/desktop.toml`
/// loads it; `Vars::default()` would plan for `root` only.
fn desktop_vars() -> Vars {
    let text = std::fs::read_to_string("vars/desktop.toml").unwrap();
    toml::from_str(&text).unwrap()
}

fn desktop_plan(distro: &str) -> String {
    let pbs = playbooks();
    let pb = pbs
        .iter()
        .find(|p| p.name == "dev_desktop")
        .expect("no playbook dev_desktop");
    telepatch::testing::plan_for(distro, pb, desktop_vars())
}

#[test]
fn dev_desktop_plans() {
    for d in DISTROS {
        let text = desktop_plan(d);
        insta::with_settings!({snapshot_path => "plans/snapshots"}, {
            insta::assert_snapshot!(format!("dev_desktop__{d}"), text);
        });
    }
}

/// Bug 1 and 4 of `conversion/admin_users.md`: the current include
/// directive, and a group that exists on the host's family.
#[test]
fn dev_desktop_admin_users_focus() {
    // Only the admin_users role: other roles' packages mention `wheel`.
    let role = |d: &str| {
        let text = desktop_plan(d);
        let from = text.find("role admin_users").expect("role admin_users");
        let to = text[from..].find("role dev_common").map_or(text.len(), |i| from + i);
        text[from..to].to_string()
    };
    for d in DISTROS {
        let text = role(d);
        assert!(text.contains("^[#@]includedir"), "{d}: {text}");
        assert!(text.contains("@includedir /etc/sudoers.d"), "{d}: {text}");
        assert!(text.contains("visudo -cf"), "{d}: {text}");
        assert!(!text.contains("$6$"), "{d}: a hash in the plan");
    }
    for d in ["debian12", "debian13", "ubuntu2404", "ubuntu2604"] {
        let text = role(d);
        assert!(text.contains("sudo") && !text.contains("wheel"), "{d}: {text}");
    }
    for d in ["fedora43", "rockylinux9", "almalinux10", "amazonlinux2023", "arch", "omarchy"] {
        let text = role(d);
        assert!(text.contains("wheel"), "{d}: {text}");
    }
}

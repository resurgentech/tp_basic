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
        let text = plan("container/rust_build", d);
        insta::with_settings!({snapshot_path => "plans/snapshots"}, {
            insta::assert_snapshot!(format!("rust_build__{d}"), text);
        });
    }
}

/// `rust_build` on ubuntu2404 with fixture answers for root's login
/// environment: `cargo` on PATH and `rustc --version` as given.
fn rust_build_with(rustc: Option<&str>) -> String {
    use telepatch::facts::{os::Os, query::Fact};
    use telepatch::testing::{FakeExecutor, FixtureHost, plan_with};
    use telepatch::{RunAs, Value};
    let pbs = playbooks();
    let pb = pbs
        .iter()
        .find(|p| p.name == "container/rust_build")
        .expect("playbook container/rust_build");
    let root = RunAs::login("root");
    let mut fake =
        FakeExecutor::new().answer(root.clone(), Fact::bin_exists("cargo"), Value::Exists(true));
    if let Some(v) = rustc {
        fake = fake.answer(root, Fact::bin_version("rustc"), Value::Text(v.to_string()));
    }
    let host = FixtureHost::new(
        "ubuntu2404",
        Os::fixture("ubuntu2404").expect("fixture"),
        std::rc::Rc::new(Vars::default()),
    );
    plan_with(pb, &host, fake)
}

#[test]
fn rust_build_working_install_updates() {
    let text = rust_build_with(Some("rustc 1.99.1 (abc 2026-10-01)"));
    insta::with_settings!({snapshot_path => "plans/snapshots"}, {
        insta::assert_snapshot!("rust_build__ubuntu2404__working", text);
    });
}

#[test]
fn rust_build_broken_install_repairs() {
    let text = rust_build_with(None);
    insta::with_settings!({snapshot_path => "plans/snapshots"}, {
        insta::assert_snapshot!("rust_build__ubuntu2404__broken", text);
    });
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

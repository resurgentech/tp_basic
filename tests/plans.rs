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

fn desktop_plan_of(name: &str, distro: &str) -> String {
    let pbs = playbooks();
    let pb = pbs
        .iter()
        .find(|p| p.name == name)
        .unwrap_or_else(|| panic!("no playbook {name}"));
    telepatch::testing::plan_for(distro, pb, desktop_vars())
}

fn desktop_plan(distro: &str) -> String {
    desktop_plan_of("dev_desktop", distro)
}

/// The text of one `role <name>` section, up to the next `role ` line.
fn role_section(text: &str, name: &str) -> String {
    let from = text
        .find(&format!("role {name}"))
        .unwrap_or_else(|| panic!("no role {name} in {text}"));
    let rest = &text[from + 5..];
    let to = rest.find("\nrole ").map_or(text.len(), |i| from + 5 + i);
    text[from..to].to_string()
}

#[test]
fn dev_desktop_kept_plans() {
    for d in DISTROS {
        let text = desktop_plan_of("dev_desktop_kept", d);
        insta::with_settings!({snapshot_path => "plans/snapshots"}, {
            insta::assert_snapshot!(format!("dev_desktop_kept__{d}"), text);
        });
    }
}

/// `node` runs after `docker`, which runs after `dev_common`. The mise op of
/// `node` writes `*`, so it cannot hoist over docker's group and user ops
/// into the `just` op of `dev_common`: each keeps its own mise transaction
/// (`just` in `dev_common`, `node` in `role node`), in YAML order. (Before
/// `docker` was ported the two merged.)
#[test]
fn dev_desktop_node_and_tmux_focus() {
    for d in DISTROS {
        let text = desktop_plan(d);
        let common = role_section(&text, "dev_common");
        assert!(common.contains("pkg:mise:root:just=Installed"), "{d}: {common}");
        assert!(!common.contains("pkg:mise:root:node"), "{d}: {common}");
        assert!(common.contains("tp_want=('just')"), "{d}: {common}");
        let node = role_section(&text, "node");
        assert!(node.contains("pkg:mise:root:node=Installed"), "{d}: {node}");
        assert!(node.contains("tp_want=('node')"), "{d}: {node}");
        let at = |r: &str| text.find(&format!("role {r}")).unwrap_or_else(|| panic!("no role {r}"));
        assert!(
            at("dev_common") < at("docker")
                && at("docker") < at("node")
                && at("node") < at("rust_build")
                && at("rust_build") < at("tmux"),
            "{d}"
        );
    }
}

/// `tmuxp` only where the distro packages it: Debian family and Arch.
#[test]
fn tmux_requests_tmuxp_only_where_packaged() {
    for d in DISTROS {
        let text = desktop_plan(d);
        let tmux = role_section(&text, "tmux");
        assert!(tmux.contains("tmux"), "{d}: {tmux}");
        let packaged = matches!(
            d,
            "debian12" | "debian13" | "ubuntu2404" | "ubuntu2604" | "arch" | "omarchy"
        );
        assert_eq!(tmux.contains("tmuxp"), packaged, "{d}: {tmux}");
    }
}

/// The kept set is exactly `admin_users` and `tmux`.
#[test]
fn dev_desktop_kept_is_admin_users_and_tmux() {
    for d in DISTROS {
        let text = desktop_plan_of("dev_desktop_kept", d);
        let roles: Vec<&str> = text
            .lines()
            .filter_map(|l| l.strip_prefix("role "))
            .collect();
        assert_eq!(roles.len(), 2, "{d}: {roles:?}");
        assert!(roles[0].starts_with("admin_users") && roles[1].starts_with("tmux"), "{d}: {roles:?}");
    }
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

/// `docker` (T52): Docker's own repository per family, the five packages,
/// the group, and every admin user in it.
#[test]
fn docker_on_docker_repository() {
    // (distro, repo path, apt suite)
    for (d, path, suite) in [
        ("ubuntu2404", "ubuntu", Some("noble")),
        ("ubuntu2604", "ubuntu", Some("resolute")),
        ("debian12", "debian", Some("bookworm")),
        ("debian13", "debian", Some("trixie")),
        ("fedora43", "fedora", None),
        ("fedora44", "fedora", None),
        ("rockylinux9", "rhel", None),
        ("rockylinux10", "rhel", None),
        ("almalinux9", "rhel", None),
        ("almalinux10", "rhel", None),
    ] {
        let text = desktop_plan(d);
        let sec = role_section(&text, "docker");
        assert!(sec.contains(&format!("download.docker.com/linux/{path}")), "{d}: {sec}");
        if let Some(s) = suite {
            assert!(sec.contains(&format!("'{s}'")), "{d}: {sec}");
        }
        for p in ["docker-ce", "docker-ce-cli", "containerd.io", "docker-buildx-plugin", "docker-compose-plugin"] {
            assert!(sec.contains(p), "{d} {p}: {sec}");
        }
        assert!(sec.contains("group"), "{d}: {sec}");
        for u in ["bot", "tpdev"] {
            assert!(sec.contains(&format!("user {u}")) || sec.contains(&format!("'{u}'")), "{d} {u}: {sec}");
        }
        let hack = sec.contains("systemctl enable --now docker");
        assert_eq!(hack, !path.contains("ubuntu") && path != "debian", "{d}: {sec}");
        if hack {
            assert!(sec.contains("systemctl is-active --quiet docker"), "{d}: {sec}");
        }
    }
}

/// Arch (and Omarchy) and Amazon Linux 2023: the distro package, no repo.
#[test]
fn docker_distro_package_on_arch_and_amazon() {
    for d in ["arch", "omarchy", "amazonlinux2023"] {
        let text = desktop_plan(d);
        let sec = role_section(&text, "docker");
        assert!(!sec.contains("download.docker.com"), "{d}: {sec}");
        assert!(!sec.contains("docker-ce"), "{d}: {sec}");
        assert!(!sec.contains("\n  #1 repo") && !sec.contains(" repo as "), "{d}: {sec}");
        assert!(sec.contains("docker"), "{d}: {sec}");
        assert_eq!(
            sec.contains("systemctl enable --now docker"),
            d != "amazonlinux2023",
            "{d}: {sec}"
        );
    }
}

#[test]
fn docker_never_uses_the_convenience_script() {
    for d in DISTROS {
        assert!(!desktop_plan(d).contains("get.docker.com"), "{d}");
    }
}

/// A distro Docker has no repository for is a trace error naming it.
#[test]
fn docker_unknown_distro_is_a_trace_error() {
    let os = telepatch::facts::os::Os::parse("ID=gentoo\nNAME=Gentoo\nVERSION_ID=2.15\n").unwrap();
    let err = tp_basic::roles::docker::check_distro(&os).unwrap_err().to_string();
    assert!(err.contains("gentoo"), "{err}");
}

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
    telepatch::testing::plan_for_playbook(distro, pb, None)
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

/// `rust_build` installs `stable` (latest, with a target) and `rust_kernel`
/// adds `rust-src` to it: one `pkg[rustup]` op per user and toolchain on
/// every distro, carrying the component.
#[test]
fn latest_kernel_build_has_one_rustup_op_per_toolchain() {
    for d in DISTROS {
        let text = plan("container/latest_kernel_build", d);
        let mut seen: Vec<(String, String)> = Vec::new();
        for line in text.lines().filter(|l| l.contains(" pkg[rustup] as ")) {
            let post = &line[line
                .find(" post [")
                .unwrap_or_else(|| panic!("{d}: {line}"))..];
            // The toolchain's own key: `pkg:rustup:<user>:<tc>=Installed`.
            let tc_key = post
                .split(['[', ',', ']'])
                .map(str::trim)
                .find(|k| k.starts_with("pkg:rustup:") && !k.contains('/'))
                .unwrap_or_else(|| panic!("{d}: no toolchain key in {line}"));
            let tc_key = tc_key.trim_end_matches("=Installed");
            let mut parts = tc_key.trim_start_matches("pkg:rustup:").splitn(2, ':');
            let user = parts.next().unwrap().to_string();
            let tc = parts.next().unwrap().to_string();
            assert!(
                post.contains(&format!("{tc_key}/component/rust-src=Installed")),
                "{d}: {line}"
            );
            assert!(
                !seen.contains(&(user.clone(), tc.clone())),
                "{d}: a second pkg[rustup] op for {user} {tc}:\n{text}"
            );
            seen.push((user, tc));
        }
        assert!(!seen.is_empty(), "{d}: no pkg[rustup] op\n{text}");
    }
}

/// `vars/desktop.toml`, as `tp-basic run dev_desktop --vars vars/desktop.toml`
/// loads it (the same layering); `Vars::default()` would plan for `root` only.
fn desktop_vars() -> Vars {
    telepatch::vars::load_file(Some(std::path::Path::new("vars/desktop.toml")), "").unwrap()
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

#[test]
fn desktop_services_plans() {
    for d in DISTROS {
        let text = desktop_plan_of("desktop_services", d);
        insta::with_settings!({snapshot_path => "plans/snapshots"}, {
            insta::assert_snapshot!(format!("desktop_services__{d}"), text);
        });
    }
}

/// `desktop_services` is a pkg op for `curl` and `ca-certificates` (the
/// `repo` op's precondition), then exactly `docker` and `vm_server`.
#[test]
fn desktop_services_is_docker_and_vm_server() {
    for d in DISTROS {
        let text = desktop_plan_of("desktop_services", d);
        let roles: Vec<&str> = text
            .lines()
            .filter_map(|l| l.strip_prefix("role "))
            .collect();
        // the pkg op runs outside any role
        assert_eq!(roles.len(), 3, "{d}: {roles:?}");
        assert_eq!(roles[0], "(none)", "{d}: {roles:?}");
        let roles = &roles[1..];
        assert!(
            roles[0].starts_with("docker") && roles[1].starts_with("vm_server"),
            "{d}: {roles:?}"
        );
        let head = &text[..text.find("role docker").unwrap()];
        assert!(
            head.contains("curl") && head.contains("ca-certificates"),
            "{d}: {head}"
        );
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
        assert!(
            common.contains("pkg:mise:root:just=Installed"),
            "{d}: {common}"
        );
        assert!(!common.contains("pkg:mise:root:node"), "{d}: {common}");
        assert!(common.contains("tp_want=('just')"), "{d}: {common}");
        let node = role_section(&text, "node");
        assert!(node.contains("pkg:mise:root:node=Installed"), "{d}: {node}");
        assert!(node.contains("tp_want=('node')"), "{d}: {node}");
        let at = |r: &str| {
            text.find(&format!("role {r}"))
                .unwrap_or_else(|| panic!("no role {r}"))
        };
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
        assert!(
            roles[0].starts_with("admin_users") && roles[1].starts_with("tmux"),
            "{d}: {roles:?}"
        );
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

/// Bug 1 and 4 of the admin_users YAML (see `src/roles/admin_users.rs`): the
/// current include directive, and a group that exists on the host's family.
#[test]
fn dev_desktop_admin_users_focus() {
    // Only the admin_users role: other roles' packages mention `wheel`.
    let role = |d: &str| {
        let text = desktop_plan(d);
        let from = text.find("role admin_users").expect("role admin_users");
        let to = text[from..]
            .find("role dev_common")
            .map_or(text.len(), |i| from + i);
        text[from..to].to_string()
    };
    for d in DISTROS {
        let text = role(d);
        // T166: the anchored regexp, through `.line_re_unique`, so a host
        // Ansible already doubled converges to one line.
        assert!(text.contains(INCLUDEDIR_RE_QUOTED), "{d}: {text}");
        assert!(text.contains("@includedir /etc/sudoers.d"), "{d}: {text}");
        assert!(text.contains("visudo -cf"), "{d}: {text}");
        assert!(!text.contains("$6$"), "{d}: a hash in the plan");
    }
    for d in ["debian12", "debian13", "ubuntu2404", "ubuntu2604"] {
        let text = role(d);
        assert!(
            text.contains("sudo") && !text.contains("wheel"),
            "{d}: {text}"
        );
    }
    for d in [
        "fedora43",
        "rockylinux9",
        "almalinux10",
        "amazonlinux2023",
        "arch",
        "omarchy",
    ] {
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
        assert!(
            sec.contains(&format!("download.docker.com/linux/{path}")),
            "{d}: {sec}"
        );
        if let Some(s) = suite {
            assert!(sec.contains(&format!("'{s}'")), "{d}: {sec}");
        }
        for p in [
            "docker-ce",
            "docker-ce-cli",
            "containerd.io",
            "docker-buildx-plugin",
            "docker-compose-plugin",
        ] {
            assert!(sec.contains(p), "{d} {p}: {sec}");
        }
        assert!(sec.contains("group"), "{d}: {sec}");
        for u in ["bot", "tpdev"] {
            assert!(
                sec.contains(&format!("user {u}")) || sec.contains(&format!("'{u}'")),
                "{d} {u}: {sec}"
            );
        }
        assert!(sec.contains("writes [svc:docker.service]"), "{d}: {sec}");
        assert!(!sec.contains("systemctl enable --now docker"), "{d}: {sec}");
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
        assert!(
            !sec.contains("\n  #1 repo") && !sec.contains(" repo as "),
            "{d}: {sec}"
        );
        assert!(sec.contains("docker"), "{d}: {sec}");
        assert!(sec.contains("writes [svc:docker.service]"), "{d}: {sec}");
        assert!(!sec.contains("systemctl enable --now docker"), "{d}: {sec}");
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
    let err = tp_basic::roles::docker::check_distro(&os)
        .unwrap_err()
        .to_string();
    assert!(err.contains("gentoo"), "{err}");
}

/// `golang` sits after `node` and before `rust_build`; its plan has the Go
/// `binary_release` pkg (no inline script; the urls are fetched in prepare,
/// so the plan shows the label, the `bin` fact and the `strip` target) and the login-shell PATH file.
#[test]
fn dev_desktop_golang_focus() {
    let text = desktop_plan("ubuntu2404");
    let go = role_section(&text, "golang");
    assert!(go.contains("pkg[binary_release]"), "{go}");
    assert!(!go.contains("pkg[script]"), "{go}");
    assert!(!go.contains("sha256sum -c"), "{go}");
    assert!(go.contains("/usr/local/go/bin/go"), "{go}");
    assert!(go.contains("/etc/profile.d/go.sh"), "{go}");
    // The file op carries its content base64-encoded:
    // `export PATH="$PATH:/usr/local/go/bin"` plus a newline.
    assert!(
        go.contains("tp_b='ZXhwb3J0IFBBVEg9IiRQQVRIOi91c3IvbG9jYWwvZ28vYmluIgo='"),
        "{go}"
    );
    assert!(go.contains("chmod 644 \"$tp_t\""), "{go}");
    let at = |r: &str| {
        text.find(&format!("role {r}"))
            .unwrap_or_else(|| panic!("no role {r}"))
    };
    assert!(
        at("node") < at("golang") && at("golang") < at("rust_build"),
        "{text}"
    );
    let kept = desktop_plan_of("dev_desktop_kept", "ubuntu2404");
    assert!(!kept.contains("golang"), "{kept}");
}

/// The `tp_want=(..)` line of the pkg op that requests libvirt. The
/// optimizer merges `vm_server`'s packages into the earlier pkg op (docker's
/// on the Debian family and the EL images), so they are not in the
/// `role vm_server` section; the op still runs before its user ops.
fn libvirt_want(text: &str) -> String {
    let lines: Vec<&str> = text.lines().filter(|l| l.contains("tp_want=(")).collect();
    let mut hit = lines.iter().filter(|l| l.contains("libvirt"));
    let one = hit
        .next()
        .unwrap_or_else(|| panic!("no pkg op wants libvirt: {text}"));
    assert!(hit.next().is_none(), "libvirt in two pkg ops: {text}");
    one.to_string()
}

/// `vm_server` (T54): the packages per family (see `src/roles/vm_server.rs`), the
/// Debian family on `qemu-system-x86` (never the virtual `qemu-kvm`).
#[test]
fn vm_server_packages_per_family() {
    for d in DISTROS {
        let text = desktop_plan(d);
        let want = libvirt_want(&text);
        let (yes, no): (&[&str], &[&str]) = match d {
            "debian12" | "debian13" | "ubuntu2404" | "ubuntu2604" => (
                &[
                    "'qemu-system-x86'",
                    "'libvirt-daemon-system'",
                    "'libvirt-clients'",
                    "'virtinst'",
                    "'bridge-utils'",
                ],
                &["qemu-kvm", "virt-install"],
            ),
            "arch" | "omarchy" => (
                &["'libvirt'", "'qemu-base'", "'virt-install'"],
                &["qemu-kvm"],
            ),
            "amazonlinux2023" => (
                &["'qemu-kvm'", "'libvirt'", "'libvirt-client'"],
                &["virt-install"],
            ),
            _ => (
                &[
                    "'qemu-kvm'",
                    "'libvirt'",
                    "'libvirt-client'",
                    "'virt-install'",
                ],
                &[],
            ),
        };
        for w in yes {
            assert!(want.contains(w), "{d} {w}: {want}");
        }
        for n in no {
            assert!(!want.contains(n), "{d} {n}: {want}");
        }
        for n in [
            "vagrant",
            "ansible",
            "ruby",
            "libvirt-devel",
            "virt-manager",
        ] {
            assert!(!want.contains(n), "{d} {n}: {want}");
        }
        assert!(
            !text.contains(".vagrant.d") && !text.contains("/usr/bin/vagrant"),
            "{d}"
        );
    }
}

/// One `svc` op per kit, on that kit's socket: `libvirtd.socket` on the
/// Debian family and Arch, `virtqemud.socket` on Fedora/EL and Amazon; no
/// `sh!` hack is left.
#[test]
fn vm_server_enables_and_starts_the_kits_socket() {
    for d in DISTROS {
        let sec = role_section(&desktop_plan(d), "vm_server");
        let unit = match d {
            "arch" | "omarchy" | "debian12" | "debian13" | "ubuntu2404" | "ubuntu2604" => {
                "libvirtd.socket"
            }
            _ => "virtqemud.socket",
        };
        assert!(sec.contains(&format!("writes [svc:{unit}]")), "{d}: {sec}");
        assert_eq!(sec.matches("writes [svc:").count(), 1, "{d}: {sec}");
        assert!(!sec.contains("enable --now"), "{d}: {sec}");
    }
}

/// One user op per admin user adds `libvirt`, after the package op, and no
/// `group` op makes the group (the package's name must be the one used).
#[test]
fn vm_server_adds_each_admin_user_to_libvirt_after_the_packages() {
    for d in DISTROS {
        let text = desktop_plan(d);
        let sec = role_section(&text, "vm_server");
        assert!(!sec.contains(" group as "), "{d}: {sec}");
        // The (merged) pkg op that wants libvirt comes before the users'.
        let pkg = text.find(&libvirt_want(&text)).unwrap();
        for u in ["bot", "tpdev"] {
            let at = text
                .find(&format!("reads [group:libvirt] writes [user:{u}]"))
                .unwrap_or_else(|| panic!("{d} {u}: {sec}"));
            assert!(pkg < at, "{d} {u}: {sec}");
            assert!(
                sec.contains(&format!("writes [user:{u}]")),
                "{d} {u}: {sec}"
            );
        }
        assert_eq!(sec.matches("tp_g in 'libvirt'").count(), 4, "{d}: {sec}");
    }
}

/// `vm_server` runs after `docker` and before `node`; `dev_desktop_kept`
/// has none of it.
#[test]
fn vm_server_sits_between_docker_and_node() {
    for d in DISTROS {
        let text = desktop_plan(d);
        let at = |r: &str| {
            text.find(&format!("role {r}"))
                .unwrap_or_else(|| panic!("{d}: no role {r}"))
        };
        assert!(
            at("docker") < at("vm_server") && at("vm_server") < at("node"),
            "{d}"
        );
        assert!(
            !desktop_plan_of("dev_desktop_kept", d).contains("vm_server"),
            "{d}"
        );
    }
}

/// T63: the pip line on the RedHat family and Amazon asks for `PyYAML`, not
/// `pyaml` (a different library); Debian and Arch install PyYAML as a distro
/// package and run no pip line.
#[test]
fn dev_base_pip_asks_for_pyyaml_not_pyaml() {
    for d in DISTROS {
        let text = plan("container/dev_base", d);
        assert!(!text.contains("pyaml"), "{d}: pyaml in the plan");
        let pip = matches!(
            d,
            "fedora43"
                | "fedora44"
                | "rockylinux9"
                | "rockylinux10"
                | "almalinux9"
                | "almalinux10"
                | "amazonlinux2023"
        );
        assert_eq!(text.contains("pkg:pip:PyYAML"), pip, "{d}");
    }
}

/// T63: uv's installer must not edit PATH (it writes `env`, `env.fish` and
/// rc-file lines for a directory already on PATH) on any distro.
#[test]
fn dev_base_uv_install_does_not_modify_path() {
    for d in DISTROS {
        let text = plan("container/dev_base", d);
        let line = text
            .lines()
            .find(|l| l.contains("astral.sh/uv/install.sh"))
            .unwrap_or_else(|| panic!("{d}: no uv install line"));
        assert!(
            line.contains("UV_INSTALL_DIR=/usr/local/bin") && line.contains("UV_NO_MODIFY_PATH=1"),
            "{d}: {line}"
        );
    }
}

/// T64: bindgen needs a loadable `libclang.so` on every family. Debian
/// family `libclang-dev`, Fedora/EL/Amazon `clang-devel`, Arch nothing
/// (`clang-libs`, a dependency of `clang`, ships it).
#[test]
fn rust_kernel_libclang_on_every_family() {
    for d in DISTROS {
        let text = plan("container/latest_kernel_build", d);
        let sec = role_section(&text, "rust_kernel");
        let (deb, rpm) = match d {
            "debian12" | "debian13" | "ubuntu2404" | "ubuntu2604" => (true, false),
            "arch" | "omarchy" => (false, false),
            _ => (false, true),
        };
        assert_eq!(sec.contains("libclang-dev"), deb, "{d}: {sec}");
        assert_eq!(sec.contains("clang-devel"), rpm, "{d}: {sec}");
    }
}

/// `services_vm` (test-only, see `playbooks/desktop.rs`): the plan holds a
/// unit op and a drop-in for `tp-probe.service`, a state op (enabled and
/// started) with a guarded restart, a disabled and stopped unit, a masked
/// one, a file and a guarded reload.
#[test]
fn services_vm_plan_has_every_state() {
    for d in DISTROS {
        let text = plan("services_vm", d);
        // one op line per op: `  #<id> <kind> as ... writes [..] [when ..] post ..`
        let ops: Vec<&str> = text.lines().filter(|l| l.starts_with("  #")).collect();
        let n = |pred: &dyn Fn(&str) -> bool| ops.iter().filter(|l| pred(l)).count();
        let has = |what: &str, c: usize| assert_eq!(c, 1, "{d}: {what}:\n{}", ops.join("\n"));
        has(
            "unit op for tp-probe.service",
            n(&|l| {
                l.contains(" unit ") && l.contains("file:/etc/systemd/system/tp-probe.service,")
            }),
        );
        has(
            "drop-in on tp-probe.service",
            n(&|l| l.contains(" unit ") && l.contains("tp-probe.service.d/override.conf")),
        );
        has(
            "unit op for tp-probe-off.service",
            n(&|l| {
                l.contains(" unit ") && l.contains("file:/etc/systemd/system/tp-probe-off.service")
            }),
        );
        has(
            "file op",
            n(&|l| l.contains(" file ") && l.contains("file:/etc/tp-probe.conf")),
        );
        // svc ops of tp-probe.service: the state op (no guard), the restart
        // guarded on the unit op (#0), the reload guarded on the file op
        let probe: Vec<&&str> = ops
            .iter()
            .filter(|l| l.contains(" svc ") && l.contains("svc:tp-probe.service]"))
            .collect();
        assert_eq!(probe.len(), 3, "{d}: {probe:?}");
        assert!(
            !probe[0].contains(" when "),
            "{d}: state op is unguarded: {}",
            probe[0]
        );
        assert!(
            probe[1].contains("when changed(#0)"),
            "{d}: restart: {}",
            probe[1]
        );
        assert!(
            probe[2].contains("when changed(#2)"),
            "{d}: reload: {}",
            probe[2]
        );
        has(
            "svc tp-probe-off.service",
            n(&|l| l.contains(" svc ") && l.contains("svc:tp-probe-off.service]")),
        );
        has(
            "svc tp-probe-masked.service",
            n(&|l| l.contains(" svc ") && l.contains("svc:tp-probe-masked.service]")),
        );
        // what the scripts do: enable+start, restart, reload, disable+stop, mask
        assert!(text.contains("systemctl restart -- \"$tp_u\""), "{d}");
        assert!(text.contains("systemctl reload -- \"$tp_u\""), "{d}");
        assert!(text.contains("systemctl enable -- \"$tp_u\""), "{d}");
        assert!(text.contains("systemctl start -- \"$tp_u\""), "{d}");
        assert!(text.contains("systemctl disable -- \"$tp_u\""), "{d}");
        assert!(text.contains("systemctl stop -- \"$tp_u\""), "{d}");
        assert!(text.contains("systemctl mask -- \"$tp_u\""), "{d}");
    }
}

#[test]
fn services_vm_plans() {
    for d in DISTROS {
        let text = plan("services_vm", d);
        insta::with_settings!({snapshot_path => "plans/snapshots"}, {
            insta::assert_snapshot!(format!("services_vm__{d}"), text);
        });
    }
}

/// The unit's `Description=` is the one var of `services_vm`; the VM script
/// changes it between runs 2 and 3, so the unit file is the only thing that
/// differs: the plan of `vars/services_vm.toml` equals the default's, and a
/// different description changes the plan's unit op only.
#[test]
fn services_vm_description_var_is_the_units_content() {
    let pbs = playbooks();
    let pb = pbs.iter().find(|p| p.name == "services_vm").unwrap();
    let file = std::path::Path::new("vars/services_vm.toml");
    // the shipped file is what the playbook defaults to
    let from_file: Vars = telepatch::vars::load_file_for(pb, Some(file)).unwrap();
    assert_eq!(from_file, telepatch::vars::load_file_for(pb, None).unwrap());
    let a = telepatch::testing::plan_for_playbook("ubuntu2404", pb, Some(file));
    assert_eq!(
        a,
        telepatch::testing::plan_for_playbook("ubuntu2404", pb, None)
    );
    let mut other: Vars = telepatch::vars::load_file_for(pb, None).unwrap();
    other.services_vm.probe_description = "changed".into();
    let b = telepatch::testing::plan_for("ubuntu2404", pb, other);
    assert_ne!(a, b);
}

/// `reboot_vm` (test-only, see `playbooks/reboot.rs`): the marked file op,
/// the reboot barrier, then the file op after it.
#[test]
fn reboot_vm_plan_has_mark_barrier_and_after_op() {
    for d in DISTROS {
        let text = plan("reboot_vm", d);
        let lines: Vec<&str> = text.lines().collect();
        let at = |pred: &dyn Fn(&str) -> bool, what: &str| {
            let v: Vec<usize> = (0..lines.len()).filter(|&i| pred(lines[i])).collect();
            assert_eq!(v.len(), 1, "{d}: {what}:\n{text}");
            v[0]
        };
        let marked = at(
            &|l| l.starts_with("  #") && l.contains("file:/etc/tp-reboot-marked"),
            "marked file op",
        );
        assert!(
            lines[marked].contains("needs_reboot"),
            "{d}: {}",
            lines[marked]
        );
        let barrier = at(&|l| l.contains("reboot if pending"), "barrier line");
        let after = at(
            &|l| l.starts_with("  #") && l.contains("file:/etc/tp-reboot-after"),
            "after op",
        );
        assert!(
            !lines[after].contains("needs_reboot"),
            "{d}: {}",
            lines[after]
        );
        assert!(marked < barrier && barrier < after, "{d}: order\n{text}");
    }
}

#[test]
fn reboot_vm_plans() {
    for d in DISTROS {
        let text = plan("reboot_vm", d);
        insta::with_settings!({snapshot_path => "plans/snapshots"}, {
            insta::assert_snapshot!(format!("reboot_vm__{d}"), text);
        });
    }
}

/// `reboot_vm_clean` (test-only, see `playbooks/reboot.rs`): exactly two
/// ops, each removing one of `reboot_vm`'s two files, in the order
/// `reboot_vm` writes them; nothing marks a reboot and there is no barrier.
#[test]
fn reboot_vm_clean_plan_removes_both_files_and_marks_nothing() {
    for d in DISTROS {
        let text = plan("reboot_vm_clean", d);
        let ops: Vec<&str> = text.lines().filter(|l| l.starts_with("  #")).collect();
        assert_eq!(ops.len(), 2, "{d}: two ops\n{text}");
        for (op, p) in ops
            .iter()
            .zip(["/etc/tp-reboot-marked", "/etc/tp-reboot-after"])
        {
            assert!(
                op.contains(&format!("writes [file:{p}]"))
                    && op.contains(&format!("post [file:{p}=Exists(false)]")),
                "{d}: {op}"
            );
            assert!(!op.contains("needs_reboot"), "{d}: {op}");
        }
        assert!(!text.contains("reboot if pending"), "{d}: barrier\n{text}");
    }
}

#[test]
fn reboot_vm_clean_plans() {
    for d in DISTROS {
        let text = plan("reboot_vm_clean", d);
        insta::with_settings!({snapshot_path => "plans/snapshots"}, {
            insta::assert_snapshot!(format!("reboot_vm_clean__{d}"), text);
        });
    }
}

/// Every registered playbook, planned twice on every distro, is the same
/// text. The plan has no per-process token (T86c).
#[test]
fn plans_are_byte_identical() {
    let pbs = playbooks();
    for pb in &pbs {
        for d in DISTROS {
            let a = telepatch::testing::plan_for_playbook(d, pb, None);
            let b = telepatch::testing::plan_for_playbook(d, pb, None);
            assert_eq!(a, b, "{} on {d}", pb.name);
        }
    }
}

fn op_lines(text: &str) -> Vec<&str> {
    text.lines().filter(|l| l.starts_with("  #")).collect()
}

/// `edge` is `edge` then `edge_extra` and nothing else. On ubuntu2404 one
/// `pkg[rustup]` names `rust-src`, `curl` is before that op and before the
/// repo, and `docker-ce-cli` is after the repo.
#[test]
fn edge_ubuntu2404_is_one_rustup_after_curl_and_the_repo() {
    let text = plan("edge", "ubuntu2404");
    // `edge_extra`'s only op merges into `edge`'s rustup, so the window
    // keeps the `role edge` heading and names the second role on the
    // merged-from line.
    let roles: Vec<&str> = text.lines().filter(|l| l.starts_with("role ")).collect();
    assert!(roles.iter().all(|l| *l == "role edge"), "{roles:?}");
    assert!(text.contains("merged from edge "), "{text}");
    assert!(text.contains(", edge_extra "), "{text}");
    let ops = op_lines(&text);
    let rustup: Vec<_> = ops.iter().filter(|l| l.contains("pkg[rustup]")).collect();
    assert_eq!(rustup.len(), 1, "{text}");
    assert!(
        rustup[0].contains("pkg:rustup:root:stable/component/rust-src"),
        "{}",
        rustup[0]
    );
    let at = |pred: &dyn Fn(&str) -> bool| ops.iter().position(|l| pred(l));
    let curl = at(&|l| l.contains(" pkg ") && l.contains("pkg:curl")).expect("curl pkg");
    let repo = at(&|l| l.contains(" repo ")).expect("repo");
    let cli = at(&|l| l.contains("pkg:docker-ce-cli")).expect("docker-ce-cli");
    let ru = at(&|l| l.contains("pkg[rustup]")).unwrap();
    assert!(curl < repo && curl < ru && repo < cli, "{ops:?}");
    assert!(
        text.contains("https://download.docker.com/linux/ubuntu"),
        "{text}"
    );
    assert!(text.contains("libz-dev"), "{text}");
    assert!(text.contains("zlib1g-dev"), "{text}");
    assert!(
        text.contains("5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5"),
        "{text}"
    );
    assert!(text.contains("/usr/local/bin/edge-jq"), "{text}");
    assert!(
        text.contains("/usr/local/share/telepatch-edge.txt"),
        "{text}"
    );
}

/// Family branches from the edge table: Debian apt, Fedora `fedora`, Rocky
/// and Alma `rhel`, Amazon and Arch no Docker repo.
#[test]
fn edge_family_branches_match_the_table() {
    let deb = plan("edge", "debian12");
    assert!(deb.contains("https://download.docker.com/linux/debian"));
    assert!(deb.contains("libz-dev"));
    assert!(deb.contains("zlib1g-dev"));
    assert!(!deb.contains("mailx"));
    let fed = plan("edge", "fedora44");
    assert!(fed.contains("https://download.docker.com/linux/fedora/docker-ce.repo"));
    assert!(fed.contains("mailx"));
    assert!(fed.contains("s-nail"));
    let rocky = plan("edge", "rockylinux10");
    assert!(rocky.contains("https://download.docker.com/linux/rhel/docker-ce.repo"));
    assert!(rocky.contains("docker-ce-cli"));
    let alma = plan("edge", "almalinux9");
    assert!(alma.contains("https://download.docker.com/linux/rhel/docker-ce.repo"));
    // T133: EL9 asks for what its curl-minimal and s-nail provide (the file
    // provide /usr/bin/curl, the virtual name /bin/mailx); EL10 keeps the
    // names, and the window still splits after the curl install on both.
    for el9 in ["rockylinux9", "almalinux9"] {
        let p = plan("edge", el9);
        assert!(
            p.contains("tp_want=('/usr/bin/curl' 'ca-certificates' 's-nail' '/bin/mailx')"),
            "{el9}:\n{p}"
        );
        assert!(
            !p.contains("pkg:mailx") && !p.contains("pkg:curl,"),
            "{el9}:\n{p}"
        );
        assert!(p.contains("-- split after #1 (pkg curl)"), "{el9}:\n{p}");
    }
    for el10 in ["rockylinux10", "almalinux10"] {
        let p = plan("edge", el10);
        assert!(
            p.contains("tp_want=('curl' 'ca-certificates' 's-nail' 'mailx')"),
            "{el10}:\n{p}"
        );
    }
    let amz = plan("edge", "amazonlinux2023");
    assert!(amz.contains("mailx"));
    assert!(amz.contains("s-nail"));
    assert!(!amz.contains("download.docker.com"));
    assert!(!amz.contains("docker-ce-cli"));
    let arch = plan("edge", "arch");
    assert!(arch.contains("pkg:sh"));
    assert!(arch.contains("pkg:bash"));
    assert!(!arch.contains("download.docker.com"));
    assert!(!arch.contains("docker-ce-cli"));
    let oma = plan("edge", "omarchy");
    assert!(oma.contains("pkg:sh"));
    assert!(!oma.contains("download.docker.com"));
    for d in DISTROS {
        let text = plan("edge", d);
        assert!(
            text.contains("5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5"),
            "{d}"
        );
        assert!(text.contains("rust-src"), "{d}");
        assert_eq!(
            op_lines(&text)
                .iter()
                .filter(|l| l.contains("pkg[rustup]"))
                .count(),
            1,
            "{d}:\n{text}"
        );
    }
}

#[test]
fn edge_plans() {
    for d in DISTROS {
        let text = plan("edge", d);
        insta::with_settings!({
            snapshot_path => "plans/snapshots",
            prepend_module_to_snapshot => false,
        }, {
            insta::assert_snapshot!(format!("edge__{d}"), text);
        });
    }
}

/// `undo_fs` (test-only, see `playbooks/undo.rs`): a content op over an
/// existing file, two `.absent()` ops and the fetch ops (one onto the root
/// filesystem, T139), then the mid-run listing op last.
#[test]
fn undo_fs_plan_has_three_file_ops_and_the_listing_last() {
    for d in DISTROS {
        let text = plan("undo_fs", d);
        let ops = op_lines(&text);
        let find = |what: &str| {
            let v: Vec<usize> = (0..ops.len()).filter(|&i| ops[i].contains(what)).collect();
            assert_eq!(v.len(), 1, "{d}: {what}:\n{text}");
            v[0]
        };
        let a = find("file:/srv/tpfs/tp-undo-file");
        let b = find("file:/srv/tpfs/tp-undo-gone");
        let c = find("file:/var/tmp/tp-undo-fs/gone");
        // T139: the root-filesystem fetch, which lands in the main cache
        let m = find("file:/opt/tp-undo-fs/main.bin");
        let last = ops.len() - 1;
        assert!(
            ops[last].contains("sh") && !ops[last].contains("file:"),
            "{d}: last op: {}",
            ops[last]
        );
        assert!(
            a < last && b < last && c < last && m < last,
            "{d}: the listing is not last\n{text}"
        );
        assert!(text.contains("/root/tp-undo-fs-mid.txt"), "{d}: {text}");
    }
}

#[test]
fn undo_fs_plans() {
    for d in DISTROS {
        let text = plan("undo_fs", d);
        insta::with_settings!({snapshot_path => "plans/snapshots"}, {
            insta::assert_snapshot!(format!("undo_fs__{d}"), text);
        });
    }
}

/// `local_user` (test-only, see `playbooks/local_user.rs`): a file op and an
/// `sh` op, both in the login shell of `tpuser`; the nologin variant is the
/// same plan for `tpnologin`. No snapshots: the plan is two lines.
#[test]
fn local_user_plans_run_in_the_users_login_shell() {
    for (name, user) in [
        ("local_user", "tpuser"),
        ("local_user_nologin", "tpnologin"),
    ] {
        let text = plan(name, "ubuntu2404");
        let ops = op_lines(&text);
        assert_eq!(ops.len(), 2, "{name}:\n{text}");
        assert!(
            ops[0].contains("file:~/file-marker") && ops[0].contains(&format!("login:{user}")),
            "{name}: {}",
            ops[0]
        );
        assert!(
            ops[1].contains("sh") && ops[1].contains(&format!("login:{user}")),
            "{name}: {}",
            ops[1]
        );
    }
}

/// T144: src_repos is the `distro_repos` primitive, with no `sh!`. On
/// Ubuntu it first removes the old labtwo role's `ubuntu-src.sources`, a
/// deb-src-only copy of `ubuntu.sources`; on Debian there is no such file.
#[test]
fn src_repos_is_the_distro_repos_op() {
    for (d, path, legacy) in [
        ("ubuntu2404", "/etc/apt/sources.list.d/ubuntu.sources", true),
        ("ubuntu2604", "/etc/apt/sources.list.d/ubuntu.sources", true),
        ("debian12", "/etc/apt/sources.list.d/debian.sources", false),
        ("debian13", "/etc/apt/sources.list.d/debian.sources", false),
    ] {
        let text = plan("container/kernel_build", d);
        let role = role_section(&text, "src_repos");
        assert!(!role.contains(" sh as "), "{d}: {role}");
        assert!(
            !text.contains("src/roles/src_repos.rs"),
            "{d}: a sh! warning"
        );
        let op = role
            .find("distro_repos")
            .unwrap_or_else(|| panic!("{d}: no distro_repos op: {role}"));
        assert!(role.contains(&format!("file:{path}")), "{d}: {role}");
        let old = role.find("file:/etc/apt/sources.list.d/ubuntu-src.sources");
        assert_eq!(old.is_some(), legacy, "{d}: {role}");
        if let Some(o) = old {
            assert!(o < op, "{d}: the removal runs first: {role}");
        }
    }
    for d in ["fedora43", "arch"] {
        let text = plan("container/kernel_build", d);
        assert!(!text.contains("distro_repos"), "{d}: {text}");
    }
}

/// T145: kernel_build stands alone. Base Ansible moved clang and llvm into
/// dev_common (9f76efa) and added lld; kernel_build requests the LLVM set
/// itself on the Debian family and RedHat, so the role applied without
/// dev_common can still build with `LLVM=1`.
#[test]
fn kernel_build_requests_the_llvm_set_itself() {
    for d in [
        "ubuntu2404",
        "ubuntu2604",
        "debian12",
        "debian13",
        "fedora43",
        "rockylinux9",
        "almalinux10",
    ] {
        let role = role_section(&plan("container/kernel_build", d), "kernel_build");
        for n in ["'clang'", "'llvm'", "'lld'"] {
            assert!(role.contains(n), "{d}: kernel_build lacks {n}: {role}");
        }
    }
}

// ---- T151: maasfix (labtwo_maasfix) ---------------------------------------

const MAAS_SOURCES: &str = "/etc/apt/sources.list.d/ubuntu.sources";
const MAAS_POINTER: &str = "# Ubuntu sources have moved to /etc/apt/sources.list.d/ubuntu.sources";

/// The three directories maasfix globs for `*.network` (T173).
const NETWORKD_DIRS: [&str; 3] = [
    "/etc/systemd/network",
    "/run/systemd/network",
    "/usr/local/lib/systemd/network",
];

/// What netplan writes on the VM image and on a networkd-managed MAAS host.
const NETPLAN_NETWORK: &str = "/run/systemd/network/10-netplan-x.network";

/// The plan of `labtwo_maasfix` for an os-release text, with
/// `/etc/apt/sources.list.d/ubuntu.sources` present or absent, and the given
/// `.network` files on the host (each answers the glob of its directory).
/// The default fake answers every fact absent (a glob: no match), so the
/// present cases are answered here.
fn maasfix_plan_with(
    name: &str,
    os: telepatch::facts::os::Os,
    sources_exist: bool,
    network_files: &[&str],
) -> String {
    use telepatch::facts::query::Fact;
    use telepatch::testing::{FakeExecutor, FixtureHost, plan_with};
    use telepatch::{RunAs, Value};
    let pbs = playbooks();
    let pb = pbs
        .iter()
        .find(|p| p.name == "labtwo_maasfix")
        .unwrap_or_else(|| panic!("no playbook labtwo_maasfix"));
    let host = FixtureHost::new(name, os, std::rc::Rc::new(Vars::default()));
    let mut fake = FakeExecutor::new().answer(
        RunAs::root_shell(),
        Fact::exists(MAAS_SOURCES),
        Value::Exists(sources_exist),
    );
    let mut dirs: Vec<String> = network_files
        .iter()
        .map(|f| f.rsplit_once('/').expect("absolute").0.to_string())
        .collect();
    dirs.sort();
    dirs.dedup();
    for d in dirs {
        let mut hits: Vec<String> = network_files
            .iter()
            .filter(|f| f.rsplit_once('/').map(|(p, _)| p) == Some(d.as_str()))
            .map(|f| f.to_string())
            .collect();
        hits.sort();
        fake = fake.answer(
            RunAs::root_shell(),
            Fact::glob(format!("{d}/*.network")),
            Value::Paths(hits),
        );
    }
    plan_with(pb, &host, fake)
}

/// A networkd-managed host (netplan's file in `/run/systemd/network`).
fn maasfix_plan_for_os(name: &str, os: telepatch::facts::os::Os, sources_exist: bool) -> String {
    maasfix_plan_with(name, os, sources_exist, &[NETPLAN_NETWORK])
}

fn maasfix_plan(distro: &str, sources_exist: bool) -> String {
    let os = telepatch::facts::os::Os::fixture(distro).unwrap();
    maasfix_plan_for_os(distro, os, sources_exist)
}

/// The svc op for systemd-networkd-wait-online in `text` (its header line
/// and script lines), if any, reduced to what it wants: `"enabled"` when the
/// script runs `systemctl enable` and not `disable`, `"disabled"` for the
/// reverse, anything else verbatim.
fn wait_online_svc(text: &str) -> Option<String> {
    let mut lines = text.lines();
    lines.find(|l| {
        l.contains(" svc as ") && l.contains("writes [svc:systemd-networkd-wait-online.service]")
    })?;
    let script: Vec<&str> = lines.take_while(|l| l.starts_with("      |")).collect();
    let script = script.join("\n");
    let en = script.contains("systemctl enable --");
    let dis = script.contains("systemctl disable --");
    Some(match (en, dis) {
        (true, false) => "enabled".to_string(),
        (false, true) => "disabled".to_string(),
        _ => script,
    })
}

fn maasfix_ubuntu(distro: &str, network_files: &[&str]) -> String {
    let os = telepatch::facts::os::Os::fixture(distro).unwrap();
    maasfix_plan_with(distro, os, true, network_files)
}

/// T173: no `.network` file in any of the three directories: the waiter is
/// disabled, and the drop-in is written as before.
#[test]
fn maasfix_disables_wait_online_where_networkd_manages_nothing() {
    for d in ["ubuntu2404", "ubuntu2604"] {
        let text = maasfix_ubuntu(d, &[]);
        let svc = wait_online_svc(&text).unwrap_or_else(|| panic!("{d}: no svc op: {text}"));
        assert_eq!(svc, "disabled", "{d}: {text}");
        assert!(
            text.contains("systemd-networkd-wait-online.service.d/override.conf"),
            "{d}: {text}"
        );
        assert!(!text.contains(" sh as "), "{d}: {text}");
    }
}

/// A vendor file in `/usr/lib/systemd/network` is not read: still disabled.
#[test]
fn maasfix_ignores_vendor_network_files() {
    let text = maasfix_ubuntu(
        "ubuntu2404",
        &["/usr/lib/systemd/network/80-container-ve.network"],
    );
    let svc = wait_online_svc(&text).unwrap_or_else(|| panic!("no svc op: {text}"));
    assert_eq!(svc, "disabled", "{text}");
}

/// A `.network` file in any one of the three directories: enabled.
#[test]
fn maasfix_enables_wait_online_where_networkd_manages_a_link() {
    for dir in NETWORKD_DIRS {
        let f = format!("{dir}/10-x.network");
        let text = maasfix_ubuntu("ubuntu2404", &[f.as_str()]);
        let svc = wait_online_svc(&text).unwrap_or_else(|| panic!("{dir}: no svc op: {text}"));
        assert_eq!(svc, "enabled", "{dir}: {text}");
        assert!(
            text.contains("systemd-networkd-wait-online.service.d/override.conf"),
            "{dir}: {text}"
        );
    }
}

/// Off Ubuntu/Pop no svc op, managed or not.
#[test]
fn maasfix_has_no_svc_op_off_ubuntu() {
    for d in DISTROS.iter().filter(|d| !d.starts_with("ubuntu")) {
        for files in [&[][..], &[NETPLAN_NETWORK][..]] {
            let os = telepatch::facts::os::Os::fixture(d).unwrap();
            let text = maasfix_plan_with(d, os, true, files);
            assert!(wait_online_svc(&text).is_none(), "{d}: {text}");
        }
    }
}

/// A MAAS-deployed host has `ubuntu.sources`, so the snapshots are planned
/// with it present.
#[test]
fn labtwo_maasfix_plans() {
    for d in DISTROS {
        let text = maasfix_plan(d, true);
        insta::with_settings!({snapshot_path => "plans/snapshots"}, {
            insta::assert_snapshot!(format!("labtwo_maasfix__{d}"), text);
        });
    }
}

/// Ubuntu 24.04 and later: the pointer comment (one `file` op, content only)
/// when `ubuntu.sources` exists, and the networkd drop-in; no `sh`.
#[test]
fn maasfix_writes_pointer_and_drop_in_on_ubuntu() {
    for d in ["ubuntu2404", "ubuntu2604"] {
        let text = maasfix_plan(d, true);
        assert!(!text.contains(" sh as "), "{d}: {text}");
        assert_eq!(
            text.matches("file:/etc/apt/sources.list=").count(),
            1,
            "{d}: {text}"
        );
        assert!(
            text.contains("unit systemd-networkd-wait-online.service"),
            "{d}: {text}"
        );
        assert!(
            text.contains("systemd-networkd-wait-online.service.d/override.conf"),
            "{d}: {text}"
        );
    }
    // The op carries exactly the pointer comment and a newline (the plan
    // shows content base64-encoded; this is `MAAS_POINTER\n` encoded).
    let text = maasfix_plan("ubuntu2404", true);
    let want = "IyBVYnVudHUgc291cmNlcyBoYXZlIG1vdmVkIHRvIC9ldGMvYXB0L3NvdXJjZXMubGlzdC5kL3VidW50dS5zb3VyY2VzCg==";
    assert!(text.contains(want), "{MAAS_POINTER}: {text}");
}

/// Without `ubuntu.sources` the sources.list op is not traced; the drop-in is.
#[test]
fn maasfix_leaves_sources_list_when_no_ubuntu_sources() {
    let text = maasfix_plan("ubuntu2404", false);
    assert!(!text.contains("file:/etc/apt/sources.list="), "{text}");
    assert!(text.contains("systemd-networkd-wait-online"), "{text}");
}

/// Every other distro is a no-op, even with the file present.
#[test]
fn maasfix_is_a_no_op_off_ubuntu() {
    for d in DISTROS.iter().filter(|d| !d.starts_with("ubuntu")) {
        let text = maasfix_plan(d, true);
        assert!(
            !text.contains("systemd-networkd-wait-online"),
            "{d}: {text}"
        );
        assert!(!text.contains("file:/etc/apt/sources.list"), "{d}: {text}");
    }
}

/// Ubuntu before 24.04 is deprecated and has no branch; Pop!_OS follows the
/// YAML's `ubuntu2404_based` flag, which names it, from 24.04 on.
#[test]
fn maasfix_gate_is_ubuntu_or_pop_from_2404() {
    let os = |id: &str, ver: &str| {
        telepatch::facts::os::Os::parse(&format!(
            "ID={id}\nID_LIKE=\"ubuntu debian\"\nNAME=x\nVERSION_ID=\"{ver}\"\n"
        ))
        .unwrap()
    };
    for (id, ver, runs) in [
        ("ubuntu", "22.04", false),
        ("ubuntu", "24.04", true),
        ("ubuntu", "26.04", true),
        ("pop", "22.04", false),
        ("pop", "24.04", true),
    ] {
        let text = maasfix_plan_for_os("t", os(id, ver), true);
        assert_eq!(
            text.contains("systemd-networkd-wait-online"),
            runs,
            "{id} {ver}: {text}"
        );
    }
}

// ---- T152: systemd_time (labtwo_systemd_time) -----------------------------

/// The plan of `labtwo_systemd_time` for `distro` with the given vars.
fn systemd_time_plan(distro: &str, vars: Vars) -> String {
    use telepatch::testing::{FakeExecutor, FixtureHost, plan_with};
    let pbs = playbooks();
    let pb = pbs
        .iter()
        .find(|p| p.name == "labtwo_systemd_time")
        .unwrap_or_else(|| panic!("no playbook labtwo_systemd_time"));
    let os = telepatch::facts::os::Os::fixture(distro).unwrap();
    let host = FixtureHost::new(distro, os, std::rc::Rc::new(vars));
    plan_with(pb, &host, FakeExecutor::new())
}

#[test]
fn labtwo_systemd_time_plans() {
    for d in DISTROS {
        let text = systemd_time_plan(d, Vars::default());
        insta::with_settings!({snapshot_path => "plans/snapshots"}, {
            insta::assert_snapshot!(format!("labtwo_systemd_time__{d}"), text);
        });
    }
}

/// Every family installs tzdata, then sets the zone; no `sh`, and the
/// timezone op follows the pkg op (it reads `pkg:tzdata`).
#[test]
fn systemd_time_installs_tzdata_then_sets_the_zone() {
    for d in DISTROS {
        let text = systemd_time_plan(d, Vars::default());
        assert!(!text.contains(" sh as "), "{d}: {text}");
        let pkg = text
            .find("pkg as shell:root reads [] writes [pkg:tzdata]")
            .unwrap_or_else(|| panic!("{d}: no tzdata pkg: {text}"));
        let tz = text
            .find("timezone as shell:root reads [pkg:tzdata]")
            .unwrap_or_else(|| panic!("{d}: no timezone: {text}"));
        assert!(pkg < tz, "{d}: {text}");
        assert!(text.contains("America/Los_Angeles"), "{d}: {text}");
    }
}

/// The zone is the `iana_tz` var, not a literal.
#[test]
fn systemd_time_uses_the_iana_tz_var() {
    let mut v = Vars::default();
    v.systemd_time.iana_tz = "Europe/Berlin".to_string();
    let text = systemd_time_plan("ubuntu2404", v);
    assert!(text.contains("Europe/Berlin"), "{text}");
    assert!(!text.contains("America/Los_Angeles"), "{text}");
}

// ---- T153: root_user (labtwo_root_user) -----------------------------------

fn root_user_plan(distro: &str) -> String {
    plan("labtwo_root_user", distro)
}

#[test]
fn labtwo_root_user_plans() {
    for d in DISTROS {
        let text = root_user_plan(d);
        insta::with_settings!({snapshot_path => "plans/snapshots"}, {
            insta::assert_snapshot!(format!("labtwo_root_user__{d}"), text);
        });
    }
}

/// The sudoers include regexp both roles share (T166), as the plan quotes it.
const INCLUDEDIR_RE_QUOTED: &str = r"'^[#@]includedir\s+/etc/sudoers\.d/?\s*$'";

/// `/root/.ssh` as a 0700 root dir and the two sudoers edits, each checked by
/// visudo; the includedir line is the `@` spelling so a stock Ubuntu line is
/// kept and the secure_path line is the YAML's.
#[test]
fn root_user_makes_ssh_dir_and_two_validated_sudoers_edits() {
    for d in DISTROS {
        let text = root_user_plan(d);
        assert!(text.contains("file:/root/.ssh"), "{d}: {text}");
        assert!(text.contains("chmod 700"), "{d}: {text}");
        assert_eq!(
            text.matches("file as shell:root reads [] writes [file:/etc/sudoers]")
                .count(),
            2,
            "{d}: {text}"
        );
        assert!(text.contains("visudo -cf"), "{d}: {text}");
        assert!(text.contains("includedir"), "{d}: {text}");
        // T166: admin_users' anchored regexp, not the broader
        // `^[#@]includedir`, which would delete an unrelated include.
        assert!(text.contains(INCLUDEDIR_RE_QUOTED), "{d}: {text}");
        assert!(!text.contains("'^[#@]includedir'"), "{d}: {text}");
        assert!(text.contains("@includedir /etc/sudoers.d"), "{d}: {text}");
        assert!(
            !text.contains("\n#includedir /etc/sudoers.d"),
            "{d}: {text}"
        );
        // admin_users' per-distro line, not the YAML's (FOREMAN, T153): the
        // two roles edit the same line and must agree, or a full labtwo run
        // flips it back and forth.
        assert!(
            !text.contains(
                "Defaults    secure_path = /sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin:/usr/local/sbin"
            ),
            "{d}: {text}"
        );
    }
    let ubuntu = root_user_plan("ubuntu2404");
    assert!(
        ubuntu.contains("/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"),
        "{ubuntu}"
    );
}

/// "Leave as found" (user, 2026-11-15): no sshd op of any kind.
#[test]
fn root_user_never_touches_sshd() {
    for d in DISTROS {
        let text = root_user_plan(d);
        assert!(!text.contains("sshd"), "{d}: {text}");
        assert!(!text.contains("/etc/ssh"), "{d}: {text}");
        assert!(!text.contains("PermitRootLogin"), "{d}: {text}");
        assert!(!text.contains("PasswordAuthentication"), "{d}: {text}");
        assert!(!text.contains(" sh as "), "{d}: {text}");
        assert!(!text.contains(" svc "), "{d}: {text}");
    }
}

// ---- T154: hashicorp_packer (labtwo_hashicorp_packer) ---------------------

fn hashicorp_packer_plan(distro: &str) -> String {
    plan("labtwo_hashicorp_packer", distro)
}

/// The role's own part of the plan: from its `role hashicorp_packer` header
/// on (it follows `vm_server`).
fn packer_part(text: &str) -> &str {
    let at = text
        .find("role hashicorp_packer")
        .unwrap_or_else(|| panic!("no hashicorp_packer role: {text}"));
    &text[at..]
}

#[test]
fn labtwo_hashicorp_packer_plans() {
    for d in DISTROS {
        let text = hashicorp_packer_plan(d);
        insta::with_settings!({snapshot_path => "plans/snapshots"}, {
            insta::assert_snapshot!(format!("labtwo_hashicorp_packer__{d}"), text);
        });
    }
}

/// Debian family: the prerequisites, both legacy files removed, the deb822
/// source with its key, then packer, in that order; the removals come before
/// the repo op and the packer install so apt never reads the repo twice. No
/// `sh`.
#[test]
fn hashicorp_packer_debian_removes_legacy_then_adds_the_source_then_installs() {
    for d in ["debian12", "debian13", "ubuntu2404", "ubuntu2604"] {
        let text = hashicorp_packer_plan(d);
        let part = packer_part(&text);
        assert!(!part.contains(" sh as "), "{d}: {part}");
        let at = |needle: &str| {
            part.find(needle)
                .unwrap_or_else(|| panic!("{d}: no {needle:?}: {part}"))
        };
        // curl and ca-certificates: the optimizer folds the role's pkg op
        // into `vm_server`'s, which wants both too, ahead of this role.
        let before = &text[..text.len() - part.len()];
        assert!(before.contains("pkg:curl"), "{d}: {text}");
        assert!(before.contains("pkg:ca-certificates"), "{d}: {text}");
        let list = at("writes [file:/etc/apt/sources.list.d/hashicorp.list]");
        let gpg = at("writes [file:/etc/apt/trusted.gpg.d/hashicorp.gpg]");
        let repo = at("repo as shell:root");
        let packer = at("writes [pkg:packer]");
        assert!(list < repo && gpg < repo, "{d}: {part}");
        assert!(repo < packer, "{d}: {part}");
        assert!(
            part.contains("apt.releases.hashicorp.com/gpg"),
            "{d}: {part}"
        );
        assert!(part.contains("hashicorp.sources"), "{d}: {part}");
        assert!(
            part.contains("'https://apt.releases.hashicorp.com'"),
            "{d}: {part}"
        );
    }
}

/// The codename is the host's.
#[test]
fn hashicorp_packer_suite_is_the_release_codename() {
    assert!(packer_part(&hashicorp_packer_plan("ubuntu2404")).contains("' 'noble' 'main'"));
    assert!(packer_part(&hashicorp_packer_plan("debian12")).contains("' 'bookworm' 'main'"));
    assert!(packer_part(&hashicorp_packer_plan("debian13")).contains("' 'trixie' 'main'"));
}

/// Each admin user joins `kvm` and `libvirt`, after the packages.
#[test]
fn hashicorp_packer_adds_admin_users_to_kvm_and_libvirt() {
    let text = hashicorp_packer_plan("ubuntu2404");
    let part = packer_part(&text);
    let user = part
        .find("user as shell:root")
        .unwrap_or_else(|| panic!("no user op: {part}"));
    assert!(part.contains("kvm"), "{part}");
    assert!(part.contains("libvirt"), "{part}");
    assert!(user > part.find("writes [pkg:packer]").unwrap(), "{part}");
}

/// Other families: no op at all; the role leaves the plan to `vm_server`.
#[test]
fn hashicorp_packer_does_nothing_off_the_debian_family() {
    for d in [
        "fedora43",
        "fedora44",
        "rockylinux9",
        "rockylinux10",
        "almalinux9",
        "almalinux10",
        "amazonlinux2023",
        "arch",
        "omarchy",
    ] {
        let text = hashicorp_packer_plan(d);
        assert!(!text.contains("hashicorp"), "{d}: {text}");
        assert!(!text.contains("packer"), "{d}: {text}");
    }
}

// ---- T155: H11SSL_reboot_fix (labtwo_h11ssl_reboot_fix) -------------------

fn h11ssl_plan(distro: &str) -> String {
    plan("labtwo_h11ssl_reboot_fix", distro)
}

#[test]
fn labtwo_h11ssl_reboot_fix_plans() {
    for d in DISTROS {
        let text = h11ssl_plan(d);
        insta::with_settings!({snapshot_path => "plans/snapshots"}, {
            insta::assert_snapshot!(format!("labtwo_h11ssl_reboot_fix__{d}"), text);
        });
    }
}

/// Ubuntu 24.04 and later: one `kernel_args` op owning the grub.d drop-in,
/// wanting `reboot=efi`. The role has no reboot op and no `sh`: the op marks
/// the reboot itself (when `/proc/cmdline` lacks the token, a run-time fact
/// the plan does not show, so the snapshot is the fresh-host case).
#[test]
fn h11ssl_sets_reboot_efi_through_kernel_args_on_ubuntu_24_and_later() {
    for d in ["ubuntu2404", "ubuntu2604"] {
        let text = h11ssl_plan(d);
        assert_eq!(
            text.matches("kernel_args as shell:root").count(),
            1,
            "{d}: {text}"
        );
        assert!(
            text.contains("writes [file:/etc/default/grub.d/99-telepatch-kernel-args.cfg]"),
            "{d}: {text}"
        );
        assert!(text.contains("reboot=*"), "{d}: {text}");
        assert!(text.contains("reboot=efi"), "{d}: {text}");
        assert!(!text.contains(" sh as "), "{d}: {text}");
        assert!(!text.contains("reboot as"), "{d}: {text}");
        // The Ansible token in /etc/default/grub is left alone: no op edits it.
        assert!(!text.contains("file:/etc/default/grub]"), "{d}: {text}");
    }
}

/// Every other distro, Debian included: no op. The fault being fixed is a
/// quirk of one board under the Ubuntu 24.04+ gate (`ubuntu2404_based`).
#[test]
fn h11ssl_does_nothing_off_ubuntu_24_and_later() {
    for d in [
        "debian12",
        "debian13",
        "fedora43",
        "fedora44",
        "rockylinux9",
        "rockylinux10",
        "almalinux9",
        "almalinux10",
        "amazonlinux2023",
        "arch",
        "omarchy",
    ] {
        let text = h11ssl_plan(d);
        assert!(!text.contains("kernel_args"), "{d}: {text}");
        assert!(!text.contains("reboot=efi"), "{d}: {text}");
    }
}

// ---- T156: cuda (labtwo_cuda) ---------------------------------------------

fn cuda_plan(distro: &str) -> String {
    plan("labtwo_cuda", distro)
}

/// The plan with the oracle case's vars file (the small lists).
fn cuda_small_plan(distro: &str) -> String {
    let pbs = playbooks();
    let pb = pbs
        .iter()
        .find(|p| p.name == "labtwo_cuda")
        .expect("labtwo_cuda");
    telepatch::testing::plan_for_playbook(
        distro,
        pb,
        Some(std::path::Path::new("vars/labtwo_cuda.toml")),
    )
}

#[test]
fn labtwo_cuda_plans() {
    for d in DISTROS {
        let text = cuda_plan(d);
        insta::with_settings!({snapshot_path => "plans/snapshots"}, {
            insta::assert_snapshot!(format!("labtwo_cuda__{d}"), text);
        });
    }
}

/// Ubuntu 24.04 and later: the keyring package from its checksummed fetch,
/// both legacy toolkit files removed before the flat deb822 repo, the driver
/// marked for reboot and the CUDA packages not, the four toolkit packages
/// in one pinned op after the repo, one docker restart guarded on it, the
/// profile. No `sh`.
#[test]
fn cuda_ubuntu_orders_keyring_legacy_repo_packages_restart_profile() {
    for d in ["ubuntu2404", "ubuntu2604"] {
        let text = cuda_plan(d);
        assert!(!text.contains(" sh as "), "{d}: {text}");
        let at = |needle: &str| {
            text.find(needle)
                .unwrap_or_else(|| panic!("{d}: no {needle:?}: {text}"))
        };
        let keyring = at("pkg:cuda-keyring");
        let list = at("writes [file:/etc/apt/sources.list.d/nvidia-container-toolkit.list]");
        let gpg = at("writes [file:/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg]");
        let repo = at("repo as shell:root");
        let driver = at("pkg:nvidia-driver-580");
        let cuda = at("pkg:cuda-toolkit-13-2");
        let tk = at("pkg:nvidia-container-toolkit,");
        let docker = at("svc");
        let profile = at("file:/etc/profile.d/cuda.sh");
        assert!(keyring < repo, "{d}: {text}");
        assert!(list < repo && gpg < repo, "{d}: {text}");
        assert!(repo < driver && repo < cuda && repo < tk, "{d}: {text}");
        assert!(tk < docker, "{d}: {text}");
        let _ = profile;
        assert!(
            text.contains("nvidia.github.io/libnvidia-container/stable/deb/$(ARCH)"),
            "{d}: {text}"
        );
        assert!(
            text.contains("nvidia-container-toolkit.sources"),
            "{d}: {text}"
        );
        for n in [
            "pkg:nvidia-container-toolkit,",
            "pkg:nvidia-container-toolkit-base",
            "pkg:libnvidia-container-tools",
            "pkg:libnvidia-container1",
        ] {
            assert!(text.contains(n), "{d}: {n}: {text}");
        }
        // one pinned op for the four (FOREMAN, T156): they depend on each
        // other at `=` one version, so apt must install them in one call
        assert!(
            text.contains(
                "tp_want=('nvidia-container-toolkit' 'nvidia-container-toolkit-base' 'libnvidia-container-tools' 'libnvidia-container1')"
            ),
            "{d}: {text}"
        );
        assert_eq!(text.matches("tp_pin='1.19.0-1'").count(), 1, "{d}: {text}");
        // the package's own list and keyring are never touched
        assert!(!text.contains("cuda-ubuntu2404-x86_64.list"), "{d}: {text}");
        assert!(!text.contains("cuda-archive-keyring"), "{d}: {text}");
    }
}

/// The driver op alone marks the reboot (the YAML's `restart host` notify on
/// the CUDA and toolkit installs was over wide), the fetch carries the
/// checksum, and the profile is 0644.
#[test]
fn cuda_marks_only_the_driver_and_checks_the_keyring_sum() {
    let text = cuda_plan("ubuntu2404");
    assert_eq!(text.matches("needs_reboot").count(), 1, "{text}");
    let line = text
        .lines()
        .find(|l| l.contains("needs_reboot"))
        .expect("a reboot mark");
    assert!(line.contains("pkg:nvidia-driver-580"), "{line}");
    // the CUDA packages are a separate op (the driver op's own timeout splits it), not folded into the marked one
    assert!(!line.contains("cuda-toolkit-13-2"), "{line}");
    assert!(!line.contains("nvtop"), "{line}");
    assert!(
        text.contains("d2a6b11c096396d868758b86dab1823b25e14d70333f1dfa74da5ddaf6a06dba"),
        "{text}"
    );
    assert!(text.contains("cuda-keyring_1.1-1_all.deb"), "{text}");
    assert!(text.contains("1.1-1"), "{text}");
    assert!(text.contains("1.19.0-1"), "{text}");
    assert!(
        text.contains("chmod 644") || text.contains("0644") || text.contains("644"),
        "{text}"
    );
}

/// The oracle case's vars file: an empty driver list is no op and no
/// reboot mark; the CUDA list is `nvtop` alone.
#[test]
fn cuda_with_the_small_lists_has_no_driver_op_and_no_reboot() {
    let text = cuda_small_plan("ubuntu2404");
    assert!(!text.contains("nvidia-driver-580"), "{text}");
    assert!(!text.contains("cuda-drivers-580"), "{text}");
    assert!(!text.contains("reboot"), "{text}");
    assert!(text.contains("pkg:nvtop"), "{text}");
    assert!(!text.contains("cuda-toolkit-13-2"), "{text}");
    assert!(text.contains("pkg:cuda-keyring"), "{text}");
    assert!(text.contains("pkg:libnvidia-container1"), "{text}");
}

/// Everything but Ubuntu and Pop!_OS 24.04 and later: no op. The vendor
/// repository is NVIDIA's ubuntu2404 one.
#[test]
fn cuda_does_nothing_off_ubuntu_24_and_later() {
    for d in [
        "debian12",
        "debian13",
        "fedora43",
        "fedora44",
        "rockylinux9",
        "rockylinux10",
        "almalinux9",
        "almalinux10",
        "amazonlinux2023",
        "arch",
        "omarchy",
    ] {
        let text = cuda_plan(d);
        assert!(!text.contains("cuda"), "{d}: {text}");
        assert!(!text.contains("nvidia"), "{d}: {text}");
    }
}

// ---- T157: the labtwo playbook ---------------------------------------------

mod labtwo_pb {
    use super::DISTROS;
    use telepatch::{Host, Playbook, PlaybookFuture};
    use tp_basic::playbooks::labtwo::labtwo_entry;
    use tp_basic::vars::Vars;

    fn grouped(h: Host<Vars>, groups: &[&str]) -> PlaybookFuture {
        labtwo_entry(h.with_groups(groups.iter().map(|g| g.to_string()).collect()))
    }
    fn servers(h: Host<Vars>) -> PlaybookFuture {
        grouped(h, &["servers"])
    }
    fn storage(h: Host<Vars>) -> PlaybookFuture {
        grouped(h, &["storage_servers"])
    }
    fn all_three(h: Host<Vars>) -> PlaybookFuture {
        grouped(h, &["servers", "maas_installs", "H11SSL_motherboards"])
    }
    fn gpu(h: Host<Vars>) -> PlaybookFuture {
        grouped(h, &["servers", "gpu_servers"])
    }
    fn gpu_only(h: Host<Vars>) -> PlaybookFuture {
        grouped(h, &["gpu_servers"])
    }
    fn nothing(h: Host<Vars>) -> PlaybookFuture {
        grouped(h, &[])
    }

    fn plan_with_groups(set: &str, distro: &str, vars: &str) -> String {
        let run: fn(Host<Vars>) -> PlaybookFuture = match set {
            "servers" => servers,
            "storage" => storage,
            "maas_h11ssl" => all_three,
            "gpu" => gpu,
            "gpu_only" => gpu_only,
            "none" => nothing,
            _ => panic!("unknown set {set}"),
        };
        let pb = Playbook::new("labtwo", run);
        telepatch::testing::plan_for_playbook(
            distro,
            &pb,
            Some(std::path::Path::new(&format!("vars/{vars}.toml"))),
        )
    }

    fn snap(name: &str, text: &str) {
        insta::with_settings!({snapshot_path => "plans/snapshots", prepend_module_to_snapshot => false}, {
            insta::assert_snapshot!(name.to_string(), text);
        });
    }

    #[test]
    fn labtwo_is_registered() {
        assert!(tp_basic::playbooks().iter().any(|p| p.name == "labtwo"));
    }

    #[test]
    fn labtwo_plans() {
        for d in ["ubuntu2404", "ubuntu2604"] {
            for (set, tag) in [
                ("servers", "servers"),
                ("maas_h11ssl", "servers_maas_h11ssl"),
                ("gpu", "servers_gpu"),
                ("none", "none"),
            ] {
                snap(
                    &format!("labtwo__{tag}__{d}"),
                    &plan_with_groups(set, d, "labtwo"),
                );
            }
        }
        for d in DISTROS {
            if d.starts_with("ubuntu") {
                continue;
            }
            snap(
                &format!("labtwo__servers__{d}"),
                &plan_with_groups("servers", d, "labtwo"),
            );
        }
    }

    /// A host in no group gets nothing, not even the barrier.
    #[test]
    fn host_in_no_group_gets_nothing() {
        let text = plan_with_groups("none", "ubuntu2404", "labtwo");
        assert!(!text.contains("role "), "{text}");
        assert!(!text.contains("reboot"), "{text}");
    }

    /// Either group of the third play runs the same roles.
    #[test]
    fn storage_servers_match_servers() {
        assert_eq!(
            plan_with_groups("servers", "ubuntu2404", "labtwo").replace("servers", "x"),
            plan_with_groups("storage", "ubuntu2404", "labtwo")
                .replace("storage_servers", "x")
                .replace("servers", "x"),
        );
    }

    /// With the real vars the plan sets the accounts' password from the
    /// reference (the plan shows only `<secret>`); the VM vars leave
    /// accounts locked, so their plan has no password step.
    #[test]
    fn vm_vars_have_no_password_step() {
        let real = plan_with_groups("gpu", "ubuntu2404", "labtwo");
        let vm = plan_with_groups("gpu", "ubuntu2404", "labtwo_vm");
        assert!(real.contains("chpasswd -e"), "{real}");
        assert!(real.contains("<secret>"), "{real}");
        assert!(!vm.contains("chpasswd"), "{vm}");
        assert!(!vm.contains("<secret>"), "{vm}");
    }

    #[test]
    fn play_roles_in_yaml_order_with_one_final_barrier() {
        let text = plan_with_groups("gpu", "ubuntu2404", "labtwo");
        let order = [
            "role admin_users",
            "role root_user",
            "role dev_common",
            "role src_repos",
            "role kernel_build",
            "role docker",
            "role vm_server",
            "role hashicorp_packer",
            "role rust_build",
            "role tmux",
            "role systemd_time",
            "role cuda",
        ];
        let mut at = 0;
        for r in order {
            let i = text[at..]
                .find(r)
                .unwrap_or_else(|| panic!("{r} missing or out of order:\n{text}"));
            at += i + r.len();
        }
        assert!(!text.contains("zsh"), "{text}");
        assert_eq!(text.matches("reboot if pending").count(), 1, "{text}");
        let barrier = text.find("reboot if pending").unwrap();
        assert!(text[barrier..].find("role ").is_none(), "{text}");
        assert!(!text.contains("sshd"), "{text}");
    }

    #[test]
    fn maas_and_h11ssl_come_first() {
        let text = plan_with_groups("maas_h11ssl", "ubuntu2404", "labtwo");
        let m = text.find("role maasfix").expect("maasfix");
        let h = text.find("role h11ssl_reboot_fix").expect("h11ssl");
        let a = text.find("role admin_users").expect("admin_users");
        assert!(m < h && h < a, "{text}");
        assert!(!text.contains("role cuda"), "{text}");
    }

    #[test]
    fn cuda_only_for_gpu_servers() {
        let text = plan_with_groups("gpu_only", "ubuntu2404", "labtwo");
        assert!(text.contains("role cuda"), "{text}");
        assert!(!text.contains("role admin_users"), "{text}");
    }
}

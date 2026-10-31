//! `rust_build`: what a Rust build needs, system packages and a per-user
//! rustup. Port of `roles/rust_build/tasks/*.yml`; the decisions and the
//! reasons are in `conversion/rust.md` (Option 2).

use telepatch::facts::os::{Distro, Family, Os};
use telepatch::{Host, TraceError, role, sh};

use crate::vars::Vars;

/// `inventories/group_vars/all:4`. Amazon is not in the list.
fn redhat_based(os: &Os) -> bool {
    os.family == Family::RedHat
        && match &os.distro {
            Distro::Fedora | Distro::Rocky | Distro::Alma => true,
            Distro::Other(id) => id == "centos" || id == "rhel",
            _ => false,
        }
}

/// `inventories/group_vars/all:6`. Tests the distribution, not the family.
fn debian_based(os: &Os) -> bool {
    matches!(os.distro, Distro::Debian | Distro::Ubuntu | Distro::PopOs)
}

/// `inventories/group_vars/all:5`. Tests the family (omarchy is Arch).
fn arch_based(os: &Os) -> bool {
    os.family == Family::Arch
}

/// `inventories/group_vars/all:10`.
fn amazonlinux2023_based(os: &Os) -> bool {
    os.distro == Distro::Amazon && os.version.major() == Some(2023)
}

/// `main.yml:17-21` looped `admin_users` and then `[root]`, so root ran
/// twice whenever `admin_users` held root. The union, each user once, in
/// that order (conversion/rust.md, item 1).
fn users(vars: &Vars) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for u in vars.admin_users.iter().map(String::as_str).chain(["root"]) {
        if !out.iter().any(|x| x == u) {
            out.push(u.to_string());
        }
    }
    out
}

#[role]
pub async fn rust_build(h: &Host<Vars>) -> Result<(), TraceError> {
    // main.yml:4-14. One branch per image; an image no flag matches gets none.
    if debian_based(&h.os) {
        // debian.yml:2-10
        h.pkg(["g++", "libssl-dev", "pkg-config", "clang", "musl-tools"]);
    } else if redhat_based(&h.os) {
        // redhat.yml:2-8
        h.pkg(["gcc-c++", "openssl-devel", "pkgconf-pkg-config", "clang"]);
        // redhat.yml:11-17. musl-gcc is packaged for Fedora and EL10 (EPEL)
        // only. The YAML's `ansible_distribution == 'Fedora' or major >= 10`
        // reduces to the version test: every Fedora in the fleet is >= 10.
        if h.os.version.major().is_some_and(|m| m >= 10) {
            h.pkg(["musl-gcc"]);
        }
    } else if amazonlinux2023_based(&h.os) {
        // amazonlinux2023.yml:3-10. No musl-gcc is packaged here.
        h.pkg(["gcc-c++", "openssl-devel", "pkgconf-pkg-config", "clang"]);
    } else if arch_based(&h.os) {
        // archlinux.yml:2-9. `musl` owns /usr/bin/musl-gcc.
        h.pkg(["openssl", "pkgconf", "clang", "musl"]);
    }

    // main.yml:16-21 and per_user.yml, once per user.
    for u in users(&h.vars) {
        // Every op through `s` runs in a fresh login environment of `u`, so
        // `~/.cargo/bin` is on PATH once the installer's profile line exists
        // (conversion/rust.md, item 7).
        let s = h.as_user(&u);

        // per_user.yml:13-20, :43-55. Absent, broken or working: cargo not
        // on PATH is absent; cargo there and `rustc --version` silent is
        // broken (item 3, 4). The reads wait for the package window.
        let has_cargo = s.bin_exists("cargo").await;
        let rustc = s.bin_version("rustc").await;

        if !has_cargo {
            // per_user.yml:122-134. `command -v`, not `which` (item 6).
            // A literal: `sh!` quotes every `{var}` it interpolates.
            sh!(
                s,
                "(set -o pipefail && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y)",
                unless = "command -v cargo"
            );
        } else if rustc.is_none() {
            // per_user.yml:73-97. The home comes from the passwd entry, not
            // `/home/<name>` (item 2).
            sh!(
                s,
                "home=$(getent passwd {u} | cut -d: -f6) && [ -n \"$home\" ] && rm -rf \"$home/.rustup\" \"$home/.cargo\""
            );
            sh!(
                s,
                "(set -o pipefail && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y)"
            );
        } else {
            // per_user.yml:99-113. The `!=` tests against the pins always
            // held, so the YAML updated on every re-run; `rustup update`
            // also self-updates, so `rustup self update` is not repeated
            // (item 5).
            sh!(s, "rustup update");
        }

        // per_user.yml:137-168. Built from source, unpinned (item 11).
        sh!(
            s,
            "cargo install cargo-deb",
            unless = "command -v cargo-deb"
        );
        sh!(
            s,
            "cargo install cargo-generate-rpm",
            unless = "command -v cargo-generate-rpm"
        );
        // per_user.yml:170-183
        sh!(
            s,
            "rustup target add x86_64-unknown-linux-musl",
            unless = "rustup target list --installed | grep -qx x86_64-unknown-linux-musl"
        );
    }
    Ok(())
}

//! `rust_build`: what a Rust build needs, system packages and a per-user
//! rustup. Port of `roles/rust_build/tasks/*.yml`.
//!
//! Purpose: `container/rust` (the docker container `rust_build`, parent
//! `dev_base`, all 13 distros) applies `dev_common` again and then this role,
//! as root. The role installs the distro packages a Rust build needs, one
//! list per family, then per user installs rustup with the default
//! toolchain (or repairs or updates an existing install) and adds
//! `cargo-deb`, `cargo-generate-rpm` and the `x86_64-unknown-linux-musl`
//! target. Workstations run the role through the same flags, and then the
//! user loop covers the human `ansible_user` as well as root. The only other
//! playbook that applies it is `latest_kernel_build`, after `kernel_build`
//! and before `rust_kernel`, and it is built only on ubuntu2604, so there
//! the role runs a second time on a host that already has rustup (the
//! update path, not the install path).
//!
//! Unlike `dev_common`, the port is by outcome, not 1:1: same package
//! tables and same installed set, with the fixes below for bugs the oracle
//! cannot see. Nothing it changes appears in the oracle's names. Changes
//! that do alter what the oracle sees are listed at the end of this file
//! under "After equivalence" and are not made yet.
//!
//! Equivalence (2026-10-30): the docker oracle (package names and arch,
//! system pip names, for root the rustup toolchains, components and targets
//! and the names in `~/.cargo/bin`, apt sources, `/usr/local/bin` names)
//! reported ubuntu2404 and rockylinux10 identical against ansible
//! 79d1ca16bfdeb678496986e1d7a0d407b06f4b45, with the non-gating version
//! side diff identical too. The other 11 images were not run as a gate.
//! The oracle builds fresh, so it does not exercise the repair or update
//! paths nor a re-run (see the fixes and `Open:` items below).
//!
//! Fixes made in the port, none visible to the oracle:
//! - Users are `admin_users` plus root, deduplicated (see `users`).
//! - The home directory comes from the passwd entry, never from the name
//!   (see the repair branch).
//! - Checks use `command -v` or `bin_exists`, not `which`: `which` is absent
//!   on five bases (see the install branch).
//! - The extras finish in the same run that repairs (see the end of the
//!   user loop).
//! - The `musl-gcc` condition is written as "major version at least 10".
//!
//! Dropped branches, which no image reaches and which are not ported: Amazon
//! Linux 2 (the role has no file for it), and the Debian 10 and Ubuntu 20.04
//! and 22.04 flags, which this role never read; they stay in the Ansible
//! `group_vars` for other roles. The `ansible_user`-is-human case is no
//! image's, but the role still takes a list of users.
//!
//! Kept as written: the package names per family, `musl-gcc` only where
//! it is packaged, the default profile, the musl target on every host,
//! `cargo install` for the two tools, and the repair block. Users other than
//! `admin_users` and root get nothing: the ubuntu2404 and ubuntu2604 bases
//! carry an `ubuntu` user (uid 1000) with no rustup, and a loop over all
//! passwd users would still pass the oracle and be wrong.
//!
//! Ops here are `sh!`: telepatch has no `fetch`, `git` or tool-install
//! primitive. This role installs no pip names, adds no repo and puts
//! nothing in `/usr/local/bin` (`uv` and `uvx` come from `dev_common`), and
//! it never installs `curl`: `dev_common` runs first and every base has
//! `curl` and `cc` (observed 2026-10-30), so a program that applies this
//! role alone depends on that.
//!
//! The version pins in `group_vars` (`rustup_version` 1.29.0,
//! `cargo_version` and `rustc_version` 1.94.0) never pinned anything and
//! this role does not read them; they stay in `Vars` until no role does.
//! The installer ran with `-y` and no `--default-toolchain`, so it installs
//! whatever `stable` is on the build day (observed 2026-10-30: rustup
//! 1.29.2, cargo and rustc 1.99.1 on the existing images). The YAML compared
//! the pins with `!=`, so any host not on exactly the pin ran
//! `rustup self update` and `rustup update`, which move to latest, not to
//! the pin; nothing in the role could produce the pinned versions. The port
//! keeps the effect and drops the comparison.
//!
//! Open: the order of fact reads and installs on a re-run. `bin_exists` and
//! `bin_version` are awaited before the install ops run, so on a fresh host
//! they read "absent" and the extras are guarded by `unless` at the op,
//! not by a fact. Whether a fact taken before the install step can see the
//! install is settled by `tp plan` of the port on a bare dev_base container
//! (the plan must list the cargo-deb op as unskipped) and an apply followed
//! by a second apply that lists no changed op. Neither is part of the
//! oracle.

use telepatch::facts::os::{Distro, Family, Os};
use telepatch::{Host, TraceError, role, sh};

use crate::vars::Vars;

/// Amazon is not in this family (`inventories/group_vars/all:4`); it has its
/// own branch below. A copy of the flag in `dev_common.rs`, which keeps its
/// own private.
fn redhat_based(os: &Os) -> bool {
    os.family == Family::RedHat
        && match &os.distro {
            Distro::Fedora | Distro::Rocky | Distro::Alma => true,
            Distro::Other(id) => id == "centos" || id == "rhel",
            _ => false,
        }
}

/// Tests the distribution, not the family (`group_vars/all:6`).
fn debian_based(os: &Os) -> bool {
    matches!(os.distro, Distro::Debian | Distro::Ubuntu | Distro::PopOs)
}

/// Tests the family (`group_vars/all:5`); omarchy reaches Arch this way.
fn arch_based(os: &Os) -> bool {
    os.family == Family::Arch
}

/// Amazon Linux 2023 only (`group_vars/all:10`); its package list differs
/// from RedHat's.
fn amazonlinux2023_based(os: &Os) -> bool {
    os.distro == Distro::Amazon && os.version.major() == Some(2023)
}

/// The YAML looped `admin_users` and then `[root]`, so root ran twice
/// whenever `admin_users` held root, and in every image it does (the
/// Dockerfiles pass `ansible_user=root`). The second pass found cargo
/// installed and, because the versions never equal the pins, ran the update
/// commands again. The second loop exists so root is covered on a workstation
/// where `admin_users` is a human. The union, each user once, in that order.
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
    // One branch per image; an image no flag matches gets none. The apt cache
    // refresh the YAML left to the Dockerfile's `apt-get update` is the
    // engine's, once before the first apt install.
    if debian_based(&h.os) {
        // `musl-tools` provides `/usr/bin/musl-gcc` (observed 2026-10-30).
        h.pkg(["g++", "libssl-dev", "pkg-config", "clang", "musl-tools"]);
    } else if redhat_based(&h.os) {
        // No repo is added here; EPEL comes from `base.el` outside this repo.
        h.pkg(["gcc-c++", "openssl-devel", "pkgconf-pkg-config", "clang"]);
        // The role's own comment says musl-gcc is packaged only for Fedora
        // and EL10+ (EPEL): pure Rust musl builds work without it, crates
        // that compile C code for musl need it. True for fedora43, fedora44,
        // rockylinux10 and almalinux10, false for rockylinux9 and almalinux9.
        // On EL10 it comes from `epel` (observed 2026-10-30: `rpm -q`
        // vendor Fedora Project, repoquery repo `epel`); EPEL has no EL9
        // build. The YAML's `ansible_distribution == 'Fedora' or major >= 10`
        // has a redundant first half: every Fedora in the fleet (43, 44) is
        // at least 10, and it is evaluated only inside the RedHat branch, so
        // the version test alone gives the same result.
        // Open: that a crate compiling C code for the musl target fails on
        // rockylinux9 (the comment's second half) was not run; it needs
        // network fetches and is outside the oracle. A hello-world built
        // offline for the musl target on rockylinux9, which has no musl-gcc,
        // gave a static-pie executable that runs (observed 2026-10-30).
        // Source: https://packages.fedoraproject.org/pkgs/musl/musl-gcc/epel-10.html (accessed 2026-10-30)
        if h.os.version.major().is_some_and(|m| m >= 10) {
            h.pkg(["musl-gcc"]);
        }
    } else if amazonlinux2023_based(&h.os) {
        // No musl-gcc is packaged here, and the YAML says so. The role never
        // ran on Amazon Linux 2.
        h.pkg(["gcc-c++", "openssl-devel", "pkgconf-pkg-config", "clang"]);
    } else if arch_based(&h.os) {
        // `musl` owns `/usr/bin/musl-gcc` (observed 2026-10-30).
        h.pkg(["openssl", "pkgconf", "clang", "musl"]);
    }

    // Once per user.
    for u in users(&h.vars) {
        // Every op through `s` runs in a fresh `bash -l` of `u`, not the
        // passwd shell the YAML parsed. The installer adds
        // `. "$HOME/.cargo/env"` to `~/.profile` (observed 2026-10-30), which
        // a login bash reads, so `~/.cargo/bin` is on PATH once the install
        // ran and the YAML's `. ~/.cargo/env &&` prefix is not written. The
        // equivalence run confirmed it; were it to fail, the fix is to
        // source that file in these ops. The profile edit also reaches
        // `~/.bashrc` and `~/.bash_profile` where they exist; the oracle
        // does not compare profile files.
        let s = h.as_user(&u);

        // Absent, broken or working, from two reads. The YAML marked a host
        // broken when `which cargo` succeeded and `rustc --version` printed
        // nothing; its version pipeline ended in `cut`, which hid a failing
        // rustc, so the empty output was the signal, and `bin_version`
        // returning `None` is the same signal. cargo not on PATH is absent
        // (the YAML also read "not installed" when `which` failed for any
        // reason, such as a passwd shell that cannot run `-lc`; a broken
        // install with `~/.cargo/bin` gone but `~/.rustup` left takes the
        // install path, not the repair path, here as there). The reads wait
        // for the package window.
        // Decided: `unless` on each op that has an existence check, and one
        // `bin_version` fact for this three-way decision, because repair is
        // three ops and an op-level `unless` cannot branch on a multi-op
        // choice. Cost: one awaited round trip per user and run.
        let has_cargo = s.bin_exists("cargo").await;
        let rustc = s.bin_version("rustc").await;

        if !has_cargo {
            // `command -v`, not `which`: `which` is absent from dev_base and
            // the finished rust_build images on fedora43, fedora44,
            // rockylinux10, almalinux10 and amazonlinux2023 (observed
            // 2026-10-30, `which: command not found`, exit 127). There every
            // YAML check read "not installed" even after installing, so a
            // re-run reinstalled rustup, rebuilt `cargo-deb` and
            // `cargo-generate-rpm` and re-added the target; the oracle
            // builds fresh and cannot see it.
            // The documented install is `curl` with `--proto '=https'
            // --tlsv1.2 -sSf` piped from the script host into `sh -s -- -y`
            // (rustup.rs, and the rustup book for `-y`). The YAML downloaded
            // the script to a shared `/tmp/rustup.sh` and ran it per user;
            // the file is gone here (the Dockerfile deletes `/tmp/*` anyway)
            // and the command is the same two actions. The project documents
            // a checksum for `rustup-init` binaries only, not for the
            // script, so the download is unverified here as in the YAML. The
            // script served on 2026-10-30 prints `rustup-init 1.29.2` and
            // accepts `-y, --yes`; `-y` is also the book's route past rustup
            // refusing when a distro Rust sits in `/usr`. The `-y` default
            // profile installs `cargo`, `clippy`, `rust-docs`, `rust-std`,
            // `rustc` and `rustfmt`, hence the components the oracle sees.
            // The subshell keeps `pipefail` out of the persistent shell and
            // fails the op when `curl` fails. A literal: `sh!` quotes every
            // `{var}` it interpolates.
            // Source: https://rustup.rs/ (accessed 2026-10-30)
            // Source: https://rust-lang.github.io/rustup/installation/index.html (accessed 2026-10-30)
            // Source: https://rust-lang.github.io/rustup/installation/already-installed-rust.html (accessed 2026-10-30)
            // Source: https://rust-lang.github.io/rustup/concepts/profiles.html (accessed 2026-10-30)
            sh!(
                s,
                "(set -o pipefail && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y)",
                unless = "command -v cargo"
            );
        } else if rustc.is_none() {
            // Repair: remove both trees, then reinstall. Kept although no
            // image reaches it (a fresh install is never broken) because
            // workstations do; the oracle cannot test it, so a unit test on
            // the command plan stands in. The home comes from the passwd
            // entry, not `/home/<name>`: the YAML removed
            // `/home/<name>/.rustup` and `.cargo`, which for root is a no-op
            // (root's home is `/root`, `/home/root` does not exist, observed
            // 2026-10-30 on all 13 images), so `rustup -y` then ran over the
            // broken tree.
            sh!(
                s,
                "home=$(getent passwd {u} | cut -d: -f6) && [ -n \"$home\" ] && rm -rf \"$home/.rustup\" \"$home/.cargo\""
            );
            sh!(
                s,
                "(set -o pipefail && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y)"
            );
        } else {
            // Working install: the YAML's `!=` tests against the pins always
            // held, so it ran `rustup self update` and `rustup update` on
            // every re-run (see the module doc on the pins). `rustup update`
            // updates stable and then checks for a self-update unless
            // `--no-self-update` is given, so the separate
            // `rustup self update` overlapped it and is not repeated. A fresh
            // install gets no update in the same run. This path runs in a
            // build only on ubuntu2604, in `latest_kernel_build`, and it was
            // not probed or run in the oracle.
            // Source: https://rust-lang.github.io/rustup/basics.html (accessed 2026-10-30)
            sh!(s, "rustup update");
        }

        // The extras run in all three branches, so a repaired host gets them
        // in the same run; the YAML skipped them while its broken flag was
        // set. Built from source and unpinned: they take the newest release
        // on the build day (observed on the arch image: cargo-deb v3.8.0,
        // cargo-generate-rpm v0.21.1). The YAML does not say why `libssl-dev`,
        // `openssl-devel`, `openssl`, `pkg-config` and `clang` are requested;
        // they are build-time dependencies of something here, and the oracle
        // compares the package list, so all stay. `cargo install cargo-deb`
        // is the documented method and needs Rust 1.76 or newer, which the
        // install above provides. The cargo-generate-rpm page returned
        // HTTP 404 on 2026-10-30, so its method is unconfirmed by
        // documentation.
        // Open: `cargo install --list` as root on each rust_build image; the
        // oracle's `~/.cargo/bin` capture holds both names and the version
        // side diff shows drift.
        // Source: https://github.com/kornelski/cargo-deb (accessed 2026-10-30)
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
        // The musl target is added on every host regardless of musl-gcc,
        // hence the component `rust-std-x86_64-unknown-linux-musl` and the
        // target list gnu and musl.
        sh!(
            s,
            "rustup target add x86_64-unknown-linux-musl",
            unless = "rustup target list --installed | grep -qx x86_64-unknown-linux-musl"
        );
    }
    Ok(())
}

// After equivalence. Each changes what the oracle sees, so each is its own
// change with its own oracle diff, made only once the 13-image oracle is
// green:
// - Pin the toolchain, or state that `stable` is the intent, and delete the
//   pin variables from `Vars` and `group_vars`. Pinning changes toolchain
//   names (`1.94.0-...` instead of `stable-...`) and the component versions.
// - Replace the `curl | sh` script download by a checksummed `rustup-init`
//   download (the `.sha256` file beside it on `static.rust-lang.org`); no
//   names change.
//   Source: https://rust-lang.github.io/rustup/installation/other.html (accessed 2026-10-30)
// - Pin `cargo-deb` and `cargo-generate-rpm` (`cargo install --locked
//   --version`) or fetch release binaries (build time and versions change).
// - Request `musl-gcc` on Rocky and Alma 9 if a crate needs it; there is no
//   EPEL 9 build, so the answer is a different package source.
// - Drop the `rls` and `rust-analyzer` stub names from `~/.cargo/bin` by
//   choosing the `minimal` profile (the component list and the names change).
// - Install `which`, or drop it from `dev_common`'s assumptions; only needed
//   if another role calls `which`.

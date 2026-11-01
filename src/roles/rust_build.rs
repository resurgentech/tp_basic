//! `rust_build`: what a Rust build needs, system packages and a per-user
//! rustup. Port of `roles/rust_build/tasks/*.yml`.
//!
//! Purpose: `container/rust` (the docker container `rust_build`, parent
//! `dev_base`, all 13 distros) applies `dev_common` again and then this role,
//! as root. The role installs the distro packages a Rust build needs, one
//! list per family, then per user installs rustup with the default
//! toolchain (or installs a missing toolchain into an existing rustup, or
//! updates it) and adds `cargo-deb`, `cargo-generate-rpm` and the
//! `x86_64-unknown-linux-musl` target. Workstations run the role through the same flags, and then the
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
//! The oracle builds fresh, so it does not exercise the update path nor a
//! re-run (see the fixes and `Open:` items below).
//!
//! Re-port (2026-10-31): the per-user block moved from `sh!` lines to a
//! `Rustup` and a `Cargo` `pkg` source (the installer primitive that the
//! understanding doc, since removed, asked to build before the port). The
//! plans differ only inside that block, and the plans no longer read facts,
//! so `blocking reads` is 0 and the host has no barrier between `dev_common`
//! and these ops. The oracle result above is to be re-run on the new form
//! (`rust_build` on ubuntu2404 and rockylinux10, `latest_kernel_build` on
//! ubuntu2604).
//!
//! Fixes made in the port, none visible to the oracle:
//! - Users are `admin_users` plus root, deduplicated (see `users`).
//! - Presence is decided by `command -v` and rustup's own listings, never
//!   `which`: `which` is absent on five bases (see the toolchain op).
//! - Root is processed once (see `users`), not twice.
//! - The extras finish in the same run as the toolchain: the musl target
//!   through `.targets`, `cargo-deb` and `cargo-generate-rpm` through the
//!   `Cargo` source (see the user loop).
//! - A broken install (cargo proxies, no toolchain) is repaired by
//!   installing the toolchain into the existing tree; the YAML's `rm` of
//!   `/home/<name>/.rustup` was a no-op for root.
//! - The `musl-gcc` condition is written as "major version at least 10".
//!
//! Dropped branches, which no image reaches and which are not ported: Amazon
//! Linux 2 (the role has no file for it), and the Debian 10 and Ubuntu 20.04
//! and 22.04 flags, which this role never read; they stay in the Ansible
//! `group_vars` for other roles. The `ansible_user`-is-human case is no
//! image's, but the role still takes a list of users.
//!
//! Kept as written: the package names per family (in full, although
//! `dev_common` already installed `g++`, `clang`, `gcc-c++`,
//! `pkgconf-pkg-config`, `openssl` and `pkgconf` on the parent image: `pkg`
//! is idempotent and the lists are the contract when the role is applied
//! on a desktop), `musl-gcc` only where it is packaged, the default
//! profile, the musl target on every host, and `cargo install` for the two
//! tools. Users other than
//! `admin_users` and root get nothing: the ubuntu2404 and ubuntu2604 bases
//! carry an `ubuntu` user (uid 1000) with no rustup, and a loop over all
//! passwd users would still pass the oracle and be wrong.
//!
//! The per-user ops are `pkg` with a `Rustup` and a `Cargo` source, not
//! `sh!`: the source owns the install command, the probe and the update, so
//! the role holds no shell. The `h.pkg` lists are distro packages. This role
//! installs no pip names, adds no repo and puts nothing in `/usr/local/bin`
//! (`uv` and `uvx` come from `dev_common`), and it never installs `curl`:
//! `dev_common` runs first and every base has `curl` and `cc` (observed
//! 2026-10-30), so a program that applies this role alone depends on that.
//! Amazon Linux 2023 is `Family::RedHat` in the engine but not `redhat_based`
//! in the YAML (`group_vars/all:4`), so it is split on the distro.
//!
//! The version pins in `group_vars` (`rustup_version` 1.29.0,
//! `cargo_version` and `rustc_version` 1.94.0) never pinned anything and
//! this role does not read them; they stay in `Vars`, unread, until
//! "After equivalence" removes them. The installer ran with `-y` and no
//! `--default-toolchain`, so it installs whatever `stable` is on the build
//! day (observed 2026-10-30: rustup 1.29.2, cargo and rustc 1.99.1 on the
//! existing images). The YAML compared the pins with `!=`, so any host not
//! on exactly the pin ran `rustup self update` and `rustup update`, which
//! move to latest, not to the pin; nothing in the role could produce the
//! pinned versions. The port keeps the effect and drops the comparison: the
//! toolchain is wanted at `Latest`, which is what the YAML did in practice,
//! and the cargo tools are wanted `Present`.
//!
//! Open: that a re-run changes nothing (`just test-idempotent ubuntu2404
//! rust`, needs network for `rustup check`) and that `latest_kernel_build`
//! on ubuntu2604, where the role runs a second time, ends identical in the
//! oracle. Neither is settled by the plan snapshots.

use telepatch::facts::os::{Distro, Family, Os};
use telepatch::{Host, TraceError, role};

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
        // ran and the YAML's `. ~/.cargo/env &&` prefix is not written (the
        // two sources also prepend `${CARGO_HOME:-$HOME/.cargo}/bin` to PATH
        // themselves, before probing and after the installer). The
        // equivalence run confirmed it for the `sh!` form. The profile edit
        // also reaches `~/.bashrc` and `~/.bash_profile` where they exist;
        // the oracle does not compare profile files.
        let s = h.as_user(&u);

        // The toolchain: a `pkg` with a `Rustup` source, name `stable`.
        // Wanted is `Latest`: the YAML's installer ran with `-y` and no
        // `--default-toolchain`, so it installed whatever stable was on the
        // build day, and its "update" branch moved to latest on every re-run
        // (see the module doc on the pins). The default profile installs
        // `cargo`, `clippy`, `rust-docs`, `rust-std`, `rustc` and `rustfmt`,
        // hence the components the oracle sees. The source runs the
        // documented one-liner (`curl --proto '=https' --tlsv1.2 -sSf
        // https://sh.rustup.rs | sh -s -- -y`, rustup.rs and the rustup book
        // for `-y`) with `--default-toolchain stable --profile default`
        // appended, in a subshell under `pipefail` so a failing `curl` fails
        // the op and `pipefail` stays out of the persistent shell. The
        // project documents a checksum for `rustup-init` binaries only, not
        // for the script, so the download is unverified here as in the YAML.
        // The script served on 2026-10-30 prints `rustup-init 1.29.2` and
        // accepts `-y, --yes`, `--default-toolchain` and `--profile`;
        // `-y` is also the book's route past rustup refusing when a distro
        // Rust sits in `/usr`. Written with `*` (the installer edits files
        // nobody listed), so it orders like the `sh!` lines it replaced.
        //
        // What the YAML's cases become, from the source's own probe, not a
        // fact read in this role: rustup absent runs the installer; rustup
        // present with the toolchain missing, including the YAML's "broken"
        // state (cargo proxies on PATH, no toolchain, so `rustc --version`
        // prints nothing) runs `rustup toolchain install stable`; both end
        // with `rustup default stable` if another default is set. The
        // YAML's repair removed `~/.rustup` and `~/.cargo` and reinstalled;
        // this reinstalls the toolchain into the existing tree and leaves
        // the rest alone, so no `rm` and no home directory is needed (the
        // YAML's `/home/<name>` was wrong for root anyway: root's home is
        // `/root`, `/home/root` does not exist, observed 2026-10-30 on all
        // 13 images). Nothing the oracle sees reaches that state: a fresh
        // image has neither cargo nor rustup. With the toolchain already
        // present and `Latest` wanted (the second application, in
        // `latest_kernel_build` on ubuntu2604): `rustup check`, and `rustup
        // update stable` only when it reports an update for `stable` or for
        // rustup itself; `rustup update` also checks for a rustup
        // self-update unless `--no-self-update` is given, so the YAML's
        // separate `rustup self update` overlapped it and is not repeated.
        // A fresh install gets no update in the same run. The check needs
        // the network, so a re-run of this role does too. Not probed or
        // run in the oracle before the port; the idempotence run covers it.
        //
        // The musl target is added on every host regardless of `musl-gcc`,
        // hence the component `rust-std-x86_64-unknown-linux-musl` and the
        // target list gnu and musl; `.targets` reads `rustup target list
        // --installed --toolchain stable` and adds only what is missing, in
        // the same run as the install. `.set_default()` keeps `stable` as
        // the default toolchain, which is the state the installer leaves.
        // `command -v`, not `which`, is how presence is decided (the
        // source's `command -v rustup` and rustup's own listings): `which`
        // is absent from dev_base and the finished rust_build images on
        // fedora43, fedora44, rockylinux10, almalinux10 and amazonlinux2023
        // (observed 2026-10-30, `which: command not found`, exit 127), so
        // there every YAML check read "not installed" even after
        // installing, and a re-run reinstalled rustup, rebuilt `cargo-deb`
        // and `cargo-generate-rpm` and re-added the target. The oracle
        // builds fresh and cannot see it.
        // Source: https://rustup.rs/ (accessed 2026-10-30)
        // Source: https://rust-lang.github.io/rustup/installation/index.html (accessed 2026-10-30)
        // Source: https://rust-lang.github.io/rustup/installation/already-installed-rust.html (accessed 2026-10-30)
        // Source: https://rust-lang.github.io/rustup/concepts/profiles.html (accessed 2026-10-30)
        // Source: https://rust-lang.github.io/rustup/basics.html (accessed 2026-10-30)
        s.rustup("stable")
            .targets(["x86_64-unknown-linux-musl"])
            .set_default()
            .latest();

        // The two tools: a `pkg` with a `Cargo` source, wanted `Present`
        // (any version; the YAML had no `--version`). One `cargo install`
        // for the names the host's `cargo install --list` does not show,
        // and none when both are listed, where the YAML's `which` guard
        // reran on five images. It runs after the toolchain op because both
        // write `*`, so `cargo` is on PATH by then (the source fails with
        // "cargo not found" otherwise). Built from source and unpinned:
        // they take the newest release on the build day (observed on the
        // arch image: cargo-deb v3.8.0, cargo-generate-rpm v0.21.1; the
        // YAML had no `--locked` either, and neither has the source). The
        // YAML does not say why `libssl-dev`, `openssl-devel`, `openssl`,
        // `pkg-config` and `clang` are requested; they are build-time
        // dependencies of something here, and the oracle compares the
        // package list, so all stay. `cargo install cargo-deb` is the
        // documented method and needs Rust 1.76 or newer, which the
        // toolchain above provides. Cargo itself skips a package already
        // installed at the same version ("Ignored package ... is already
        // installed", exit 0; observed 2026-10-31), which is what kept the
        // `which`-less images correct under the YAML. The cargo-generate-rpm
        // page returned HTTP 404 on 2026-10-30, so its method is unconfirmed
        // by documentation. Unlike the YAML, which skipped the tools while
        // its broken flag was set, a repaired host gets them in the same
        // run.
        // Open: `cargo install --list` as root on each rust_build image; the
        // oracle's `~/.cargo/bin` capture holds both names and the version
        // side diff shows drift.
        // Source: https://github.com/kornelski/cargo-deb (accessed 2026-10-30)
        // Source: https://doc.rust-lang.org/cargo/commands/cargo-install.html (accessed 2026-10-31)
        s.cargo(["cargo-deb", "cargo-generate-rpm"]);
    }
    Ok(())
}

// After equivalence. Each changes what the oracle sees, so each is its own
// change with its own oracle diff, made only once the 13-image oracle is
// green:
// - Pin the toolchain, or state that `stable` is the intent, and delete the
//   pin variables from `Vars` and `group_vars`. `.pin` is not available on
//   rustup: name a version toolchain instead (`s.rustup("1.94.0")`), which
//   changes toolchain names (`1.94.0-...` instead of `stable-...`) and the
//   component versions, and needs `RUSTUP_VERSION` on the installer if
//   rustup itself is to be pinned.
// - Replace the `curl | sh` script download by a checksummed `rustup-init`
//   download (the `.sha256` file beside it on `static.rust-lang.org`) as the
//   source's `.installer(..)`; no names change.
//   Source: https://rust-lang.github.io/rustup/installation/other.html (accessed 2026-10-30)
// - Pin `cargo-deb` and `cargo-generate-rpm` through `.pin(v)` per name on
//   the `Cargo` source (`--version`; the source adds no `--locked`, so a
//   locked install needs a `.installer`-style command or an engine change),
//   or fetch release binaries (build time and versions change). Today's
//   latest are cargo-deb 3.8.0 and cargo-generate-rpm 0.21.1, so a pin
//   changes nothing until the next release.
// - Request `musl-gcc` on Rocky and Alma 9 if a crate needs it; there is no
//   EPEL 9 build, so the answer is a different package source.
// - Drop the `rls` and `rust-analyzer` stub names from `~/.cargo/bin` by
//   choosing the `minimal` profile (`.profile("minimal")`; the component
//   list changes: `rust-docs` goes, and `clippy` and `rustfmt` come back
//   through `.components` if wanted).
// - Pass `--no-modify-path` and write one `/etc/profile.d` line instead of
//   editing each user's rc files (the oracle does not capture them, but
//   `rust_kernel`, `rust_tools` and interactive users rely on `cargo` being
//   on the login PATH, so it is a behaviour change for users).
// - Install `which`, or drop it from `dev_common`'s assumptions; only needed
//   if another role calls `which`.

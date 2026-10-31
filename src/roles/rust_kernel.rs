//! `rust_kernel`: what the kernel's Rust support needs on top of the
//! `rust_build` toolchain: libclang (Debian family), the `rust-src`
//! component and `bindgen`. Port of `roles/rust_kernel/tasks/*.yml`.
//!
//! Purpose: `container/latest_kernel_build` (the docker container of that
//! name, parent `rust_build`) makes an image that can build the latest
//! upstream Linux kernel tree with the latest rustup toolchain,
//! Rust-enabled. It runs as root and applies `dev_common`, `src_repos`,
//! `kernel_build`, `rust_build` and then this role, which no other playbook
//! applies. The container is built only for distros whose `set` is
//! `latest`, and exactly one has it: ubuntu2604. So one image reaches this
//! role. The role is a layer on `rust_build`, not a second installer: it
//! never installs rustup, cargo or a toolchain, and needs `~/.cargo/env`
//! and `rustup` for each user; if `~/.cargo/env` is absent the shell fails
//! and the run stops, which is the right behaviour. The role's own
//! acceptance check is `make rustavailable` in a kernel tree (the kernel
//! documentation spells it `make LLVM=1 rustavailable`); it is a comment in
//! the YAML and nothing executes it.
//!
//! Equivalence (2026-10-30): the docker oracle (`test-container ubuntu2604
//! latest_kernel_build`) reported ubuntu2604 identical against ansible
//! 79d1ca16bfdeb678496986e1d7a0d407b06f4b45, gating set and the non-gating
//! versions side both. ubuntu2604 is the only image in the `latest` set, so
//! no other image can run this role. What the role adds on that image, all
//! of it in the gating set: `libclang-dev` and, through its dependency,
//! `libclang-21-dev` (package names); the `rust-src` component for root;
//! `bindgen` in root's `~/.cargo/bin` (crate `bindgen-cli`). Pip names,
//! apt sources, `/usr/local/bin`, toolchains and targets do not change.
//!
//! Fixes made in the port, none visible to the oracle:
//! - `changed_if = "downloading"` (see the first `sh!`): the YAML's
//!   `changed_when: "'installing' in rust_src_result.stderr"` never matches
//!   the output of rustup 1.29.2, so the Ansible task reported unchanged on
//!   a real install and on a no-op alike. Only the report was wrong; the
//!   component is installed either way, which is why the oracle cannot see
//!   it.
//! - Users are `admin_users` plus root, deduplicated (see `users`): the YAML
//!   ran the per-user tasks twice for root.
//!
//! Dropped branches, which no image reaches and which are not ported: the
//! RedHat, Amazon and Arch families. The role has no task for them (only the
//! apt task carries a `when`), so on such a host the YAML would have run just
//! the two per-user tasks and installed no libclang package. No image of
//! those families runs `latest_kernel_build` (all 12 other distros are in the
//! `default` set, which ends at `rust_build`), and none was added. Pop!_OS
//! and other Debian-family hosts share the Debian arm.
//!
//! Kept as written: the order `rust_build` then `rust_kernel`; the
//! `. ~/.cargo/env &&` prefix; no `--toolchain` on the component add, so
//! `rust-src` goes to the user's default toolchain (on this image the only
//! one, `stable-x86_64-unknown-linux-gnu`); `cargo install --locked
//! bindgen-cli` unpinned.
//!
//! Open: `make LLVM=1 rustavailable` in a kernel tree inside
//! `resurgentech/latest_kernel_build-ubuntu2604:latest`. The oracle compares
//! names, not whether the installed rustc (1.99.1 observed) and bindgen
//! (0.73.2 observed) suit a given kernel tree, and the kernel quick-start
//! gives no numeric minimum; this check is the role's own acceptance test and
//! was not run.
//! Open: rustup's progress wording is not a documented interface, so the
//! `downloading` regex rests on one observation (see the first `sh!`).
//!
//! Method current (2026-10-30): the three things the role installs are the
//! three the kernel documentation lists (the standard library source, bindgen,
//! libclang), by the same commands.
//! Source: https://docs.kernel.org/rust/quick-start.html (accessed 2026-10-30)
//! Source: https://rust-lang.github.io/rust-bindgen/requirements.html (accessed 2026-10-30)
//! Source: https://rust-lang.github.io/rustup/concepts/components.html (accessed 2026-10-30)
//! Source: https://packages.ubuntu.com/resolute/libclang-dev (accessed 2026-10-30)
//!
//! After equivalence (each changes what the oracle sees; not made yet):
//! - pin or upgrade `bindgen-cli`;
//! - install `libclang-dev` on every family;
//! - run `make LLVM=1 rustavailable` as a post-condition in a kernel tree;
//! - add `--toolchain` to the component add.

use telepatch::facts::os::{Distro, Os};
use telepatch::{Host, TraceError, role, sh};

use crate::vars::Vars;

/// `inventories/group_vars/all:6`. Tests the distribution, not the family.
/// A copy of the fn in `rust_build.rs` (private there).
fn debian_based(os: &Os) -> bool {
    matches!(os.distro, Distro::Debian | Distro::Ubuntu | Distro::PopOs)
}

/// The YAML looped `admin_users` and then `[root]`, so root ran twice
/// whenever `admin_users` held root; the image build sets
/// `ansible_user=root`, so here it always did. The second pass changed
/// nothing (`rustup component add` reports "is up to date" and `creates`
/// skips the build), so the oracle could not see it. The union, each user
/// once, in that order. A copy of the fn in `rust_build.rs` (private there).
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
pub async fn rust_kernel(h: &Host<Vars>) -> Result<(), TraceError> {
    // `libclang-dev` is the development metapackage for libclang, which
    // bindgen uses to read the kernel's C. Debian family only: no other
    // family has the task, and the clang packages `rust_build` installs
    // there are what bring libclang. On Debian the `clang` package alone left
    // no `libclang-dev` (observed in `rust_build-ubuntu2604`: `libclang1-21`
    // present, `libclang-dev` absent), which is why the task exists. The
    // task has no cache update; the image build refreshed the cache before
    // the playbook began. Package name current on ubuntu2604: `libclang-dev`
    // 1:21.1.6-71 from universe, depending on `libclang-21-dev` (observed
    // 2026-10-30, both installed in `latest_kernel_build-ubuntu2604` and
    // absent from `rust_build-ubuntu2604`).
    if debian_based(&h.os) {
        h.pkg(["libclang-dev"]);
    }

    for u in users(&h.vars) {
        // A fresh login environment of `u`: `~` is u's home and
        // `~/.cargo/bin` is on PATH. Components are per toolchain per user,
        // so each user gets its own `rust-src` and `bindgen`.
        let s = h.as_user(&u);

        // `rust_build` left `~/.cargo/env`; sourcing it does not depend on a
        // login profile having been written. The YAML ran this under the
        // default `/bin/sh` with `become_user`, not the user's login shell.
        // The kernel needs `rust-src` because its build cross-compiles
        // `core`. `changed_if` matches combined stdout and stderr and
        // requires rc 0 (the YAML tested stderr only; stdout is empty here,
        // so they agree). Observed 2026-10-30, rustup 1.29.2 in
        // `rust_build-ubuntu2604`, rc 0 both times: the first add printed
        // `info: downloading component rust-src` on stderr and nothing on
        // stdout, the repeat printed `info: component rust-src is up to
        // date`. The word `installing` never appears, so the YAML's test
        // could not fire; `downloading` is what a real add prints. Open: the
        // check `docker run --rm --entrypoint sh
        // resurgentech/rust_build-ubuntu2604:latest -c '. ~/.cargo/env;
        // rustup component add rust-src 2>&1'` should be repeated if rustup
        // moves.
        // Source: https://rust-lang.github.io/rustup/concepts/components.html (accessed 2026-10-30)
        sh!(
            s,
            ". ~/.cargo/env && rustup component add rust-src",
            changed_if = "downloading"
        );

        // `cargo install --locked` builds from source with the published
        // lockfile, takes minutes, needs network and a C linker (`gcc`, from
        // `dev_common`), and serves whatever version crates.io has on the
        // build day (0.73.2 observed). `creates` guards it, so a later play
        // never rebuilds: there is no upgrade path, and versions are not an
        // equivalence point. `creates` is a path in the user's own home, so
        // the guard is per user. The tilde is left unquoted so the shell
        // expands it in the user's login environment: the plan shows
        // `[ -e ~/.cargo/bin/bindgen ]`, root's home for root and the passwd
        // home for anyone else, without a `getent` op. This replaces the
        // earlier plan of an absolute home path, which the plan output
        // superseded. It also avoids the `/home/<name>` form that `rust_build`
        // would give (`/home/root` for root, which does not exist).
        // Source: https://docs.kernel.org/rust/quick-start.html (accessed 2026-10-30)
        sh!(
            s,
            ". ~/.cargo/env && cargo install --locked bindgen-cli",
            creates = "~/.cargo/bin/bindgen"
        );
    }
    Ok(())
}

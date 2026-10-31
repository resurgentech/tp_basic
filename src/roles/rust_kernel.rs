//! `rust_kernel`: what the kernel's Rust support needs on top of the
//! `rust_build` toolchain: libclang (Debian family), the `rust-src`
//! component and `bindgen`. Port of `roles/rust_kernel/tasks/*.yml`; the
//! decisions and the reasons are in `conversion/latest_kernel_build.md`.

use telepatch::facts::os::{Distro, Os};
use telepatch::{Host, TraceError, role, sh};

use crate::vars::Vars;

/// `inventories/group_vars/all:6`. Tests the distribution, not the family.
/// A copy of the fn in `rust_build.rs` (private there).
fn debian_based(os: &Os) -> bool {
    matches!(os.distro, Distro::Debian | Distro::Ubuntu | Distro::PopOs)
}

/// `main.yml:12-16` looped `admin_users` and then `[root]`, so root ran
/// twice whenever `admin_users` held root. The union, each user once, in
/// that order (latest_kernel_build.md, Preserved knowledge 2). A copy of
/// the fn in `rust_build.rs` (private there).
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
    // main.yml:6-10. Debian family only; no other family has the task.
    if debian_based(&h.os) {
        h.pkg(["libclang-dev"]);
    }

    // main.yml:12-16 and per_user.yml, once per user.
    for u in users(&h.vars) {
        // A fresh login environment of `u`: `~` is u's home and
        // `~/.cargo/bin` is on PATH (Open question 1).
        let s = h.as_user(&u);

        // per_user.yml:3-8. `rust_build` left `~/.cargo/env`; sourcing it
        // does not depend on a login profile (Preserved knowledge 7).
        // rustup 1.29.2 prints `downloading component rust-src` on a real
        // add and `component rust-src is up to date` on a repeat; the
        // YAML's `installing` never matched (Preserved knowledge 3).
        sh!(
            s,
            ". ~/.cargo/env && rustup component add rust-src",
            changed_if = "downloading"
        );

        // per_user.yml:10-13. `creates` is checked in u's own home: the
        // tilde is left unquoted so the shell expands it (item 5).
        sh!(
            s,
            ". ~/.cargo/env && cargo install --locked bindgen-cli",
            creates = "~/.cargo/bin/bindgen"
        );
    }
    Ok(())
}

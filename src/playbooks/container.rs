//! `playbooks/container/*.yml`: image-build playbooks, run as root with
//! `tp-basic run container/<name> --local --vars vars/container.toml`.

use telepatch::{Host, Playbook, PlaybookFuture, TraceError};

use crate::roles::dev_common::dev_common;
use crate::roles::kernel_build::kernel_build;
use crate::roles::rust_build::rust_build;
use crate::roles::rust_kernel::rust_kernel;
use crate::roles::src_repos::src_repos;
use crate::vars::Vars;

/// Every container playbook, registered under `container/<name>`.
pub fn all() -> Vec<Playbook<Vars>> {
    vec![
        Playbook {
            name: "container/kernel_build",
            run: kernel_build_entry,
        },
        Playbook {
            name: "container/dev_base",
            run: dev_base_entry,
        },
        Playbook {
            name: "container/rust",
            run: rust_build_entry,
        },
        Playbook {
            name: "container/latest_kernel_build",
            run: latest_kernel_build_entry,
        },
    ]
}

fn dev_base_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { dev_base(&h).await })
}

/// `container/dev_base`: runs against all hosts as root (the run's user) and
/// applies the one role `dev_common`; the purpose and decisions are in that
/// role's comments.
async fn dev_base(h: &Host<Vars>) -> Result<(), TraceError> {
    dev_common(h).await
}

fn rust_build_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { rust_build_playbook(&h).await })
}

/// `playbooks/container/rust.yml:8-9`: roles in YAML order, `dev_common` then
/// `rust_build`. Registered as `container/rust` (it mirrors `rust.yml`); the
/// docker container is named `rust_build`. Equivalence: see `rust_build.rs`.
async fn rust_build_playbook(h: &Host<Vars>) -> Result<(), TraceError> {
    dev_common(h).await?;
    rust_build(h).await
}

fn kernel_build_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { kernel_build_playbook(&h).await })
}

/// `playbooks/container/kernel_build.yml:7-10`: roles in YAML order. The
/// second `dev_common` run is the same role again (the first is the
/// `dev_base` image's own); it adds no package name, and only `uv` and `uvx`
/// are replaced in place. Equivalence: see `roles/kernel_build.rs`.
async fn kernel_build_playbook(h: &Host<Vars>) -> Result<(), TraceError> {
    dev_common(h).await?;
    src_repos(h).await?;
    kernel_build(h).await
}

fn latest_kernel_build_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { latest_kernel_build(&h).await })
}

/// `playbooks/container/latest_kernel_build.yml:7-12`: roles in YAML order,
/// all hosts, as root. Builds the `latest_kernel_build` image (parent
/// `rust_build`, only for the `latest` distro set, which is ubuntu2604 alone)
/// that can build the latest upstream kernel with the latest rustup
/// toolchain, Rust-enabled. `dev_common`, `src_repos`, `kernel_build` and
/// `rust_build` are applied again as their own playbooks apply them; only
/// `rust_kernel` is specific to this one. Equivalence (2026-10-30): the
/// docker oracle reported ubuntu2604 identical against ansible 79d1ca1,
/// versions side too; the reasons and open items are in
/// `roles/rust_kernel.rs`.
async fn latest_kernel_build(h: &Host<Vars>) -> Result<(), TraceError> {
    dev_common(h).await?;
    src_repos(h).await?;
    kernel_build(h).await?;
    rust_build(h).await?;
    rust_kernel(h).await
}

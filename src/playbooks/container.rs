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
            name: "container/rust_build",
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

/// `playbooks/container/dev_base.yml:7-8`: roles in YAML order.
async fn dev_base(h: &Host<Vars>) -> Result<(), TraceError> {
    dev_common(h).await
}

fn rust_build_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { rust_build_playbook(&h).await })
}

/// `playbooks/container/rust.yml:8-9`: roles in YAML order. The docker
/// container is named `rust_build`.
async fn rust_build_playbook(h: &Host<Vars>) -> Result<(), TraceError> {
    dev_common(h).await?;
    rust_build(h).await
}

fn kernel_build_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { kernel_build_playbook(&h).await })
}

/// `playbooks/container/kernel_build.yml:7-10`: roles in YAML order. The
/// second `dev_common` run is the same role again.
async fn kernel_build_playbook(h: &Host<Vars>) -> Result<(), TraceError> {
    dev_common(h).await?;
    src_repos(h).await?;
    kernel_build(h).await
}

fn latest_kernel_build_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { latest_kernel_build(&h).await })
}

/// `playbooks/container/latest_kernel_build.yml:7-12`: roles in YAML order.
async fn latest_kernel_build(h: &Host<Vars>) -> Result<(), TraceError> {
    dev_common(h).await?;
    src_repos(h).await?;
    kernel_build(h).await?;
    rust_build(h).await?;
    rust_kernel(h).await
}

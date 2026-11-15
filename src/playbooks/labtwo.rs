//! Test playbooks for the VM oracle's `labtwo_<role>` cases: one role of
//! `ansible_labtwo_2/playbooks/labtwo.yml` each, run on its own so the
//! oracle compares just that role against the Ansible original.
//! `scripts/test-vm-oracle.sh` runs them (`OC_TP`). They are not in any
//! YAML.
//!
//! The `labtwo` playbook itself (T157) is the YAML as one function: the
//! per-group plays of `playbooks/labtwo.yml`, then one reboot barrier.

use telepatch::{Host, Playbook, PlaybookFuture, TraceError};

use crate::roles::admin_users::admin_users;
use crate::roles::cuda::cuda;
use crate::roles::dev_common::dev_common;
use crate::roles::docker::docker;
use crate::roles::h11ssl_reboot_fix::h11ssl_reboot_fix;
use crate::roles::hashicorp_packer::hashicorp_packer;
use crate::roles::kernel_build::kernel_build;
use crate::roles::maasfix::maasfix;
use crate::roles::root_user::root_user;
use crate::roles::rust_build::rust_build;
use crate::roles::src_repos::src_repos;
use crate::roles::systemd_time::systemd_time;
use crate::roles::tmux::tmux;
use crate::roles::vm_server::vm_server;
use crate::vars::Vars;

/// Every labtwo test playbook, registered under its oracle case name.
pub fn all() -> Vec<Playbook<Vars>> {
    vec![
        Playbook::new("labtwo", labtwo_entry),
        Playbook::new("labtwo_maasfix", labtwo_maasfix_entry),
        Playbook::new("labtwo_systemd_time", labtwo_systemd_time_entry),
        Playbook::new("labtwo_root_user", labtwo_root_user_entry),
        Playbook::new("labtwo_hashicorp_packer", labtwo_hashicorp_packer_entry),
        Playbook::new("labtwo_h11ssl_reboot_fix", labtwo_h11ssl_reboot_fix_entry),
        Playbook::new("labtwo_cuda", labtwo_cuda_entry),
    ]
}

/// The `labtwo` playbook's entry (public so the plan tests can trace it with
/// inventory groups set).
pub fn labtwo_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { labtwo(&h).await })
}

/// `playbooks/labtwo.yml`, per host by inventory group, in the YAML's play
/// order: `maas_installs` (maasfix), `H11SSL_motherboards`
/// (H11SSL_reboot_fix), `servers` and `storage_servers` (the third play's
/// roles in YAML order; `zsh`, listed after `dev_common`, was dropped by the
/// user), `gpu_servers` (cuda). The single reboot barrier follows them all:
/// roles mark `.needs_reboot()`, the playbook places the barrier. A host in
/// no group gets nothing, and no barrier either (nothing can be pending).
async fn labtwo(h: &Host<Vars>) -> Result<(), TraceError> {
    let mut any = false;
    if h.in_group("maas_installs") {
        maasfix(h).await?;
        any = true;
    }
    if h.in_group("H11SSL_motherboards") {
        h11ssl_reboot_fix(h).await?;
        any = true;
    }
    if h.in_group("servers") || h.in_group("storage_servers") {
        admin_users(h).await?;
        root_user(h).await?;
        dev_common(h).await?;
        src_repos(h).await?;
        kernel_build(h).await?;
        docker(h).await?;
        vm_server(h).await?;
        hashicorp_packer(h).await?;
        rust_build(h).await?;
        tmux(h).await?;
        systemd_time(h).await?;
        any = true;
    }
    if h.in_group("gpu_servers") {
        cuda(h).await?;
        any = true;
    }
    if any {
        h.reboot().if_pending();
    }
    Ok(())
}

fn labtwo_maasfix_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { labtwo_maasfix(&h).await })
}

/// `playbooks/labtwo.yml:4-7`, the "Fix up quirks of the MAAS installs" play.
async fn labtwo_maasfix(h: &Host<Vars>) -> Result<(), TraceError> {
    maasfix(h).await
}

fn labtwo_systemd_time_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { labtwo_systemd_time(&h).await })
}

/// `playbooks/labtwo.yml`, the `systemd_time` entry of the `servers` and
/// `storage_servers` play's role list (`ansible_labtwo_2`).
async fn labtwo_systemd_time(h: &Host<Vars>) -> Result<(), TraceError> {
    systemd_time(h).await
}

fn labtwo_root_user_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { labtwo_root_user(&h).await })
}

/// `playbooks/labtwo.yml`, the `root_user` entry of the `servers` and
/// `storage_servers` play's role list (`ansible_labtwo_2`).
async fn labtwo_root_user(h: &Host<Vars>) -> Result<(), TraceError> {
    root_user(h).await
}

fn labtwo_hashicorp_packer_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { labtwo_hashicorp_packer(&h).await })
}

/// `playbooks/labtwo.yml`, `vm_server` then `hashicorp_packer` in the `servers`
/// and `storage_servers` play's role list (`ansible_labtwo_2`): the packer
/// role relies on `vm_server` for the `kvm` and `libvirt` groups.
async fn labtwo_hashicorp_packer(h: &Host<Vars>) -> Result<(), TraceError> {
    vm_server(h).await?;
    hashicorp_packer(h).await
}

fn labtwo_h11ssl_reboot_fix_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { labtwo_h11ssl_reboot_fix(&h).await })
}

/// `playbooks/labtwo.yml:9-12`, the `H11SSL_motherboards` play: its one role.
async fn labtwo_h11ssl_reboot_fix(h: &Host<Vars>) -> Result<(), TraceError> {
    h11ssl_reboot_fix(h).await
}

fn labtwo_cuda_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { labtwo_cuda(&h).await })
}

/// `playbooks/labtwo.yml`, the `gpu_servers` play: its one role. No reboot
/// barrier here: the playbook step (T157) places `h.reboot().if_pending()`.
async fn labtwo_cuda(h: &Host<Vars>) -> Result<(), TraceError> {
    cuda(h).await
}

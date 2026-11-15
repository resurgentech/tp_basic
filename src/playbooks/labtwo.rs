//! Test playbooks for the VM oracle's `labtwo_<role>` cases: one role of
//! `ansible_labtwo_2/playbooks/labtwo.yml` each, run on its own so the
//! oracle compares just that role against the Ansible original.
//! `scripts/test-vm-oracle.sh` runs them (`OC_TP`). They are not in any
//! YAML; the real playbook's role order lands with the labtwo port.

use telepatch::{Host, Playbook, PlaybookFuture, TraceError};

use crate::roles::cuda::cuda;
use crate::roles::h11ssl_reboot_fix::h11ssl_reboot_fix;
use crate::roles::hashicorp_packer::hashicorp_packer;
use crate::roles::maasfix::maasfix;
use crate::roles::root_user::root_user;
use crate::roles::systemd_time::systemd_time;
use crate::roles::vm_server::vm_server;
use crate::vars::Vars;

/// Every labtwo test playbook, registered under its oracle case name.
pub fn all() -> Vec<Playbook<Vars>> {
    vec![
        Playbook::new("labtwo_maasfix", labtwo_maasfix_entry),
        Playbook::new("labtwo_systemd_time", labtwo_systemd_time_entry),
        Playbook::new("labtwo_root_user", labtwo_root_user_entry),
        Playbook::new("labtwo_hashicorp_packer", labtwo_hashicorp_packer_entry),
        Playbook::new("labtwo_h11ssl_reboot_fix", labtwo_h11ssl_reboot_fix_entry),
        Playbook::new("labtwo_cuda", labtwo_cuda_entry),
    ]
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

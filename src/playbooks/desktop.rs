//! `playbooks/dev_desktop.yml`: the development desktop, run as root with
//! `tp-basic run dev_desktop --vars vars/desktop.toml`.

use telepatch::{Host, Playbook, PlaybookFuture, TraceError};

use crate::roles::admin_users::admin_users;
use crate::roles::dev_common::dev_common;
use crate::roles::rust_build::rust_build;
use crate::vars::Vars;

/// Every desktop playbook, registered under its YAML name.
pub fn all() -> Vec<Playbook<Vars>> {
    vec![
        Playbook {
            name: "dev_desktop",
            run: dev_desktop_entry,
        },
        Playbook {
            name: "dev_desktop_kept",
            run: dev_desktop_kept_entry,
        },
    ]
}

fn dev_desktop_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { dev_desktop(&h).await })
}

/// `playbooks/dev_desktop.yml:8-17`: roles in YAML order. Only the roles
/// already ported are here; each later step inserts its role at its YAML
/// position (docker, vm_server, nvm_node, golang between `dev_common` and
/// `rust_build`; tmux last). `rust_tools` is dropped.
async fn dev_desktop(h: &Host<Vars>) -> Result<(), TraceError> {
    admin_users(h).await?;
    dev_common(h).await?;
    rust_build(h).await
}

fn dev_desktop_kept_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { dev_desktop_kept(&h).await })
}

/// The roles of `dev_desktop` whose end state the VM oracle compares with
/// the Ansible run. For now `admin_users` alone; T51 adds `tmux`.
async fn dev_desktop_kept(h: &Host<Vars>) -> Result<(), TraceError> {
    admin_users(h).await
}

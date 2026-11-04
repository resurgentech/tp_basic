//! `playbooks/dev_desktop.yml`: the development desktop, run as root with
//! `tp-basic run dev_desktop --vars vars/desktop.toml`.

use telepatch::{Host, Playbook, PlaybookFuture, TraceError};

use crate::roles::admin_users::admin_users;
use crate::roles::dev_common::dev_common;
use crate::roles::docker::docker;
use crate::roles::golang::golang;
use crate::roles::node::node;
use crate::roles::rust_build::rust_build;
use crate::roles::tmux::tmux;
use crate::roles::vm_server::vm_server;
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
/// position. `docker` and `vm_server` sit between `dev_common` and `node`,
/// so `node`'s mise op no longer merges into `dev_common`'s. `node` stands
/// where `nvm_node` did (dropped, see `roles/node.rs`); `golang` follows it;
/// `rust_tools` is dropped (decided "straight out" by the user, 2026-11-04).
/// The YAML's play is a bare role list, `hosts: all`, `remote_user: root`
/// (`playbooks/dev_desktop.yml:4-16`), nine roles in the order above plus
/// `rust_tools` before `tmux`. `default_password` is `""` in the ansible
/// repo (`inventories/group_vars/all:26`; its comment says an
/// `openssl passwd -6` hash, so no secret is mirrored), and `full_users` and
/// `vnc_users` served only `rust_tools` and a tigervnc role out of scope,
/// so neither is in `Vars`. `docker` and `vm_server` are also applied by
/// `playbooks/minikube.yml`, which this repo does not port.
async fn dev_desktop(h: &Host<Vars>) -> Result<(), TraceError> {
    admin_users(h).await?;
    dev_common(h).await?;
    docker(h).await?;
    vm_server(h).await?;
    node(h).await?;
    golang(h).await?;
    rust_build(h).await?;
    tmux(h).await
}

fn dev_desktop_kept_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { dev_desktop_kept(&h).await })
}

/// The roles of `dev_desktop` whose end state the VM oracle compares with
/// the Ansible run. `admin_users` and `tmux`.
async fn dev_desktop_kept(h: &Host<Vars>) -> Result<(), TraceError> {
    admin_users(h).await?;
    tmux(h).await
}

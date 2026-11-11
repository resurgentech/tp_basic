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
use crate::vars::{ServicesVmVars, Vars};

/// Every desktop playbook, registered under its YAML name.
pub fn all() -> Vec<Playbook<Vars>> {
    vec![
        Playbook::new("dev_desktop", dev_desktop_entry),
        Playbook::new("dev_desktop_kept", dev_desktop_kept_entry),
        Playbook::new("desktop_services", desktop_services_entry),
        Playbook::new("services_vm", services_vm_entry).defaults(services_vm_defaults),
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

fn desktop_services_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { desktop_services(&h).await })
}

/// Not in the YAML: the two service-bearing roles of `dev_desktop`, for the
/// svc proofs (`scripts/test-services.sh` in an init-less container,
/// `scripts/test-vm.sh` on the VM). `curl` and `ca-certificates` come first
/// because `docker`'s `repo` op needs them and the pinned Debian-family bases
/// ship no curl; the rest of `dev_desktop`'s chain would only add minutes.
async fn desktop_services(h: &Host<Vars>) -> Result<(), TraceError> {
    h.pkg(["curl", "ca-certificates"]);
    docker(h).await?;
    vm_server(h).await
}

/// The playbook's own `Description=` for the probe unit: layer 3, above the
/// role default and below a vars file (`vars/services_vm.toml`).
fn services_vm_defaults() -> Vars {
    Vars {
        services_vm: ServicesVmVars {
            probe_description: "telepatch services_vm probe".to_string(),
            probe_conf: "probe=1\n".to_string(),
        },
        ..Vars::default()
    }
}

fn services_vm_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { services_vm(&h).await })
}

/// Not in the YAML: the proof of service states, units and guarded restarts
/// on a booted VM (`scripts/test-vm.sh services_vm`) and offline in an
/// init-less container (`scripts/test-services.sh`). No role: the units are
/// the playbook's own, named `tp-probe*`.
///
/// * `tp-probe.service` runs `sleep infinity`, with a drop-in; it is
///   enabled and started, and restarts when its unit file changes. It has
///   `ExecReload=/bin/true` so the guarded reload (when `/etc/tp-probe.conf`
///   changes) has something to run. The `Description=` comes from
///   `services_vm.probe_description` (the VM script changes it between
///   runs 2 and 3). The conf file's body comes from `services_vm.probe_conf`,
///   whose default is the old literal `probe=1\n`; run 4 changes only that.
/// * `tp-probe-off.service` exists (an `[Install]` section, so "disabled"
///   is a state of a real unit) and is disabled and stopped.
/// * `tp-probe-masked.service` has no file: `systemctl mask` links it to
///   /dev/null, and refuses when a file of that name is in /etc/systemd.
async fn services_vm(h: &Host<Vars>) -> Result<(), TraceError> {
    let desc = &h.vars.services_vm.probe_description;
    let unit = h
        .unit("tp-probe.service")
        .content(format!(
            "[Unit]\nDescription={desc}\n\n[Service]\nExecStart=/bin/sleep infinity\nExecReload=/bin/true\n\n[Install]\nWantedBy=multi-user.target\n"
        ))
        .mode(0o644);
    h.unit("tp-probe.service")
        .drop_in("override", "[Service]\nEnvironment=TP_PROBE=1\n");
    let conf = h
        .file("/etc/tp-probe.conf")
        .content(h.vars.services_vm.probe_conf.as_str());
    h.unit("tp-probe-off.service")
        .content("[Unit]\nDescription=telepatch services_vm probe, off\n\n[Service]\nExecStart=/bin/sleep infinity\n\n[Install]\nWantedBy=multi-user.target\n");
    h.svc("tp-probe.service")
        .enabled()
        .started()
        .restart_on(&unit);
    h.svc("tp-probe.service").reload().when(conf.changed());
    h.svc("tp-probe-off").disabled().stopped();
    h.svc("tp-probe-masked").masked().stopped();
    Ok(())
}

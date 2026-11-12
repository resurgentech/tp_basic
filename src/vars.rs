//! Playbook variables, mirroring `inventories/group_vars/all` of the Ansible
//! repo for the parts the ported roles use.
//!
//! `Vars` is a struct of role sections, one vars struct per role, and a role
//! reads only its own: `h.vars.rust_build.admin_users`. (The structs live
//! here, not in the role files, so adding one does not shift the `sh!`
//! source lines the plan snapshots record.) A vars file is layered per
//! section by `telepatch::vars`: the role's `[section]`, then a top-level
//! key of the same name (every role with a field of that name), then the
//! playbook's defaults (`services_vm` alone supplies any), then the role's
//! own `Default`. A
//! top-level key no role has, or an unknown key in a section, is an error
//! naming the file and line.

use serde::{Deserialize, Serialize};
use telepatch::Secret;

/// The default `admin_users`: the container user. Ansible's default is
/// `["{{ ansible_user }}"]`; container builds run as root.
fn root_only() -> Vec<String> {
    vec!["root".to_string()]
}

/// `roles/admin_users`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, default)]
pub struct AdminUsersVars {
    /// Users the role sets up. Container builds run as root.
    pub admin_users: Vec<String>,
    /// A crypt(3) hash for accounts a run creates (`group_vars/all:26`).
    /// `None` leaves them locked. A literal never goes in a tracked file:
    /// pass a reference (`{ env = "..." }`, `{ file = "..." }`,
    /// `{ prompt = "..." }`, `{ bao = "...", field = "..." }`) from a
    /// `--vars` file kept outside the repo.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_password: Option<Secret>,
}

impl Default for AdminUsersVars {
    fn default() -> Self {
        AdminUsersVars {
            admin_users: root_only(),
            default_password: None,
        }
    }
}

/// `roles/docker`: its users join the `docker` group.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, default)]
pub struct DockerVars {
    /// Users the role sets up. Container builds run as root.
    pub admin_users: Vec<String>,
}

impl Default for DockerVars {
    fn default() -> Self {
        DockerVars {
            admin_users: root_only(),
        }
    }
}

/// `roles/vm_server`: its users join the kvm and libvirt groups.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, default)]
pub struct VmServerVars {
    /// Users the role sets up. Container builds run as root.
    pub admin_users: Vec<String>,
}

impl Default for VmServerVars {
    fn default() -> Self {
        VmServerVars {
            admin_users: root_only(),
        }
    }
}

/// `roles/rust_kernel`: the users that get a toolchain.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, default)]
pub struct RustKernelVars {
    /// Users the role sets up. Container builds run as root.
    pub admin_users: Vec<String>,
}

impl Default for RustKernelVars {
    fn default() -> Self {
        RustKernelVars {
            admin_users: root_only(),
        }
    }
}

/// `roles/rust_build`: the users that get a toolchain.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, default)]
pub struct RustBuildVars {
    /// Users the role sets up. Container builds run as root.
    pub admin_users: Vec<String>,
    /// Pinned in `group_vars/all` but never read by the role.
    pub rustc_version: String,
}

impl Default for RustBuildVars {
    fn default() -> Self {
        RustBuildVars {
            admin_users: root_only(),
            rustc_version: "1.94.0".to_string(),
        }
    }
}

/// `playbooks/desktop.rs` `services_vm` (test-only, not a role): the vars
/// `scripts/test-vm.sh` changes. `probe_description` between runs 2 and 3
/// (the unit file); `probe_conf` on run 4 (the conf file, not the unit).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, default)]
pub struct ServicesVmVars {
    /// The `Description=` line of the probe unit `tp-probe.service`: the
    /// only part of the unit file a var sets, so changing it changes the
    /// unit's content and nothing else.
    pub probe_description: String,
    /// The body of `/etc/tp-probe.conf`. The default is the literal the
    /// file op used before this var existed, so a plan that does not set
    /// it does not move.
    pub probe_conf: String,
}

impl Default for ServicesVmVars {
    fn default() -> Self {
        ServicesVmVars {
            probe_description: "telepatch probe (role default)".to_string(),
            probe_conf: "probe=1\n".to_string(),
        }
    }
}

/// Roles with vars of their own. A role not listed reads none.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, default)]
pub struct Vars {
    pub admin_users: AdminUsersVars,
    pub docker: DockerVars,
    pub vm_server: VmServerVars,
    pub rust_kernel: RustKernelVars,
    pub rust_build: RustBuildVars,
    pub services_vm: ServicesVmVars,
}

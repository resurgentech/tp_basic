//! Playbook variables, mirroring `inventories/group_vars/all` of the Ansible
//! repo for the parts the ported roles use.

use serde::Deserialize;

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Vars {
    /// Users that get per-user tooling (rustup, cargo tools). Ansible's
    /// default is `["{{ ansible_user }}"]`; container builds run as root.
    pub admin_users: Vec<String>,
    pub rustup_version: String,
    pub cargo_version: String,
    pub rustc_version: String,
    /// A crypt(3) hash for accounts a run creates (`group_vars/all:26`).
    /// Empty leaves them locked. A real hash never goes in the repo: pass
    /// it in a `--vars` file kept outside it.
    #[serde(default)]
    pub default_password: String,
}

impl Default for Vars {
    /// The values of `group_vars/all` at ansible 79d1ca1, with the
    /// container user (`root`) as the only admin user.
    fn default() -> Self {
        Vars {
            admin_users: vec!["root".to_string()],
            rustup_version: "1.29.0".to_string(),
            cargo_version: "1.94.0".to_string(),
            rustc_version: "1.94.0".to_string(),
            default_password: String::new(),
        }
    }
}

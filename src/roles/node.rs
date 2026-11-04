//! `node`: Node.js for every user of a workstation, through mise's system
//! layer. Replaces `roles/nvm_node/tasks/main.yml` (decision of 2026-11-04
//! in `conversion/dev_desktop.md`, "Node through mise instead of nvm").
//!
//! nvm_node was dropped, not ported: its one task is `include_role` of the
//! Galaxy role `stephdewit.nvm` (`roles/nvm_node/tasks/main.yml:3`), listed
//! unpinned in `tools/scripts/requirements.yml` and not mirrored in the
//! repo, so its behaviour cannot be checked; its settings
//! (`inventories/group_vars/all:34-37`) described an nvm tree under
//! `/var/lib/nvm` and a line in `/etc/bash.bashrc`, neither of which has
//! an equivalent here. mise is already how this fleet installs tools
//! the distros package badly (`just`, in `dev_common`), so Node comes from
//! the same layer. It needs the `mise` binary and shims `dev_common`
//! installs, hence the playbook runs this role after it.

use telepatch::{Host, TraceError, role};

use crate::vars::Vars;

/// The intent of `nvm_node_version: lts` (`inventories/group_vars/all:35`) is
/// a stable Node on every login shell. The call below asks mise for `node`
/// with `Present`: the first run installs mise's default request for a bare
/// name and later runs leave it alone (mise does not re-resolve it by
/// itself). The page does not say that default is the LTS line, so the
/// wanted version is not pinned to `lts` yet (conversion/dev_desktop.md,
/// "Question for the reviewer").
/// Source: https://mise.jdx.dev/lang/node.html (accessed 2026-11-03)
#[role]
pub async fn node(h: &Host<Vars>) -> Result<(), TraceError> {
    h.mise(["node"]);
    Ok(())
}

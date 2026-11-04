//! `node`: Node.js for every user of a workstation, through mise's system
//! layer. Replaces `roles/nvm_node/tasks/main.yml` of the ansible repo at
//! commit 79d1ca1 (decision of the user, 2026-11-04: nvm_node dropped, Node
//! from `h.mise(["node"])`, in its own one-line role where `nvm_node` stood
//! rather than in `dev_common`, which all four container playbooks run and
//! whose image builds and oracle differences Node would change).
//!
//! nvm_node was dropped, not ported: its one task is `include_role` of the
//! Galaxy role `stephdewit.nvm` (`roles/nvm_node/tasks/main.yml:3`), listed
//! unpinned in `tools/scripts/requirements.yml` and not mirrored in the
//! repo, so its behaviour cannot be checked; its settings
//! (`inventories/group_vars/all:34-37`) described an nvm tree under
//! `/var/lib/nvm` and a line in `/etc/bash.bashrc` (nvm 0.40.4, node `lts`,
//! `nvm_install_path`, `nvm_shell_init_file`), neither of which has
//! an equivalent here; nothing else in the repo reads `nvm_install_path`.
//! mise is already how this fleet installs tools
//! the distros package badly (`just`, in `dev_common`), so Node comes from
//! the same layer. It needs the `mise` binary and shims `dev_common`
//! installs, hence the playbook runs this role after it.
//!
//! What mise does for Node: it installs from the official archive on
//! nodejs.org and checks it against `SHASUMS256.txt` and that file's
//! OpenPGP signature. Its version requests: `latest` is the newest
//! release, `lts` the newest release of the current LTS line, a numeric
//! prefix the newest matching release. `mise use -g node@26` writes a
//! per-user default and the page describes no system-wide form; the system
//! layer (`h.mise`, shims in `/usr/local/share/mise/shims`) is the one
//! `dev_common` sets up for `just`.
//! Source: https://mise.jdx.dev/lang/node.html (accessed 2026-11-03)
//!
//! Dropped with the old way: Ansible Node came from the Galaxy role
//! `stephdewit.nvm`, unpinned, so its behaviour could not be checked
//! (verdict: mise is the current way in this fleet).

use telepatch::{Host, TraceError, role};

use crate::vars::Vars;

/// The intent of `nvm_node_version: lts` (`inventories/group_vars/all:35`) is
/// a stable Node on every login shell. The call below asks mise for `node`
/// with `Present`: the first run installs mise's default request for a bare
/// name and later runs leave it alone (mise does not re-resolve it by
/// itself). The page does not say that default is the LTS line, so the
/// wanted version is not pinned to `lts` yet. Open question: (a) pin the
/// request to `lts`, which keeps what Ansible installed and costs a
/// one-word pin on the handle, or (b) leave mise's default, which tracks
/// the newest release like `just` and can move `node --version` to a
/// non-LTS line. The reviewer's position was (a): a workstation wants a
/// stable Node.
/// Open: `docker run --rm ubuntu:24.04 sh -c 'apt-get update -qq && apt-get
/// install -y -qq curl ca-certificates >/dev/null && curl -fsSL
/// https://mise.run | sh && ~/.local/bin/mise ls-remote node@lts | tail
/// -1'` prints the version `lts` resolves to today.
/// Source: https://mise.jdx.dev/lang/node.html (accessed 2026-11-03)
#[role]
pub async fn node(h: &Host<Vars>) -> Result<(), TraceError> {
    h.mise(["node"]);
    Ok(())
}

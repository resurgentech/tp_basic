//! Test-only playbooks for `as_user` over `--local` (T120), not in any YAML.
//!
//! `scripts/test-vm.sh local_user` copies the musl `tp-basic` into a VM and
//! runs these with `--local` there, the only place a real second user
//! exists: as root, and as the VM's passwordless-sudo login user, the ops
//! below run in `tpuser`'s login shell; a third run targets a user whose
//! login shell is `nologin` and expects the transport's refusal.

use telepatch::{Host, Playbook, PlaybookFuture, TraceError, sh};

use crate::vars::Vars;

/// The account the setup makes (`useradd -m`), with a login shell.
pub const USER: &str = "tpuser";

/// The account the setup makes with `/usr/sbin/nologin` as its shell.
pub const NOLOGIN_USER: &str = "tpnologin";

/// Every `as_user`-over-local playbook.
pub fn all() -> Vec<Playbook<Vars>> {
    vec![
        Playbook::new("local_user", local_user_entry),
        Playbook::new("local_user_nologin", local_user_nologin_entry),
    ]
}

fn local_user_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { local_user(&h, USER).await })
}

fn local_user_nologin_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { local_user(&h, NOLOGIN_USER).await })
}

/// In `user`'s login shell: a file op (a capturing op, so the undo
/// directories of that user are prepared) and a line that says who the
/// shell is. Both land in `~user`, which the script reads as root.
async fn local_user(h: &Host<Vars>, user: &str) -> Result<(), TraceError> {
    let u = h.as_user(user);
    u.file("~/file-marker").content("written by the file op\n");
    // HACK(test): records `id -un` in the user's own shell, which no primitive reads (the proof must see who the shell is, not who the op names)
    sh!(u, "id -un > \"$HOME/marker\"");
    Ok(())
}

//! `tmux`: the terminal multiplexer and its session manager, from the
//! distro. Port of `roles/tmux/tasks/main.yml:1-6`; the understanding is in
//! `conversion/dev_desktop.md` ("tmux and tmuxp per family").
//!
//! Ansible ran one `apt` call for `tmux` and `tmuxp` with no `when` guard
//! (`main.yml:3-6`), so the role failed on every host outside the Debian
//! family (bug 5; observed on Rocky 9, 2026-11-03). The `become: yes` at
//! `main.yml:2` is a no-op on a play that already runs as root (bug 4).

use telepatch::facts::os::Family;
use telepatch::{Host, TraceError, role};

use crate::vars::Vars;

#[role]
pub async fn tmux(h: &Host<Vars>) -> Result<(), TraceError> {
    // `tmux` is a distro package on every family. `tmuxp` is one only on
    // the Debian family (Debian 12 1.27.0, Ubuntu 24.04 1.38.0) and Arch
    // (1.76.0, `extra`, so Omarchy too); Fedora, the EL family and Amazon
    // Linux 2023 have none in their default repositories (probed
    // 2026-11-03), and tmuxp's own page installs it with pip, uv or
    // Homebrew there. Asking for it would fail the whole transaction and
    // lose `tmux` with it (the Ansible bug above), so those families get
    // `tmux` alone. An unknown family is `pkg`'s own trace error.
    // Source: https://tmuxp.git-pull.com/quickstart.html (accessed 2026-11-03)
    match h.os.family {
        Family::Debian | Family::Arch => h.pkg(["tmux", "tmuxp"]),
        _ => h.pkg(["tmux"]),
    };
    Ok(())
}

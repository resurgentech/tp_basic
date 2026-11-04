//! `tmux`: the terminal multiplexer and its session manager, from the
//! distro. Port of `roles/tmux/tasks/main.yml:1-6` of the ansible repo at
//! commit 79d1ca1 (kept as one `pkg` by the user's decision, 2026-11-04).
//! Only this playbook applies the role. The VM oracle compares it on
//! Ubuntu 24.04 (apt), where Ansible and the port install the same two
//! names, so there is no intended difference.
//!
//! Ansible ran one `apt` call for `tmux` and `tmuxp` with no `when` guard
//! (`main.yml:3-6`), so the role failed on every host outside the Debian
//! family (bug 5; observed on Rocky 9, 2026-11-03). The `become: yes` at
//! `main.yml:2` is a no-op on a play that already runs as root
//! (`playbooks/dev_desktop.yml:6`; bug 4). Observed 2026-11-03 in
//! rockylinux:9 with ansible-core 2.15.13: `"[Errno 2] No such file or
//! directory: b'apt-get'"`; the role worked on the Debian family only.

use telepatch::facts::os::Family;
use telepatch::{Host, TraceError, role};

use crate::vars::Vars;

#[role]
pub async fn tmux(h: &Host<Vars>) -> Result<(), TraceError> {
    // `tmux` is a distro package on every family. `tmuxp` is one only on
    // the Debian family (Debian 12 1.27.0, Ubuntu 24.04 1.38.0) and Arch
    // (1.76.0, `extra`, so Omarchy too); Fedora, the EL family and Amazon
    // Linux 2023 have none in their default repositories (probed
    // 2026-11-03; throwaway containers ubuntu:24.04, debian:12, archlinux,
    // fedora:43, rockylinux:9, rockylinux/rockylinux:10, amazonlinux:2023,
    // by `apt-cache policy tmuxp` and `pacman -Si tmuxp`; Ubuntu serves
    // 1.38.0-1ubuntu1), and tmuxp's own page installs it with pip, uv or
    // Homebrew there (it needs tmux >= 3.2 and Python >= 3.10). Asking for it
    // would fail the whole transaction and
    // lose `tmux` with it (the Ansible bug above), so those families get
    // `tmux` alone. An unknown family is `pkg`'s own trace error.
    // Source: https://tmuxp.git-pull.com/quickstart.html (accessed 2026-11-03)
    // Open: `docker run --rm rockylinux:9 sh -c 'dnf -y install
    // epel-release >/dev/null && dnf info tmuxp'` shows whether EPEL serves
    // `tmuxp` on the EL family.
    match h.os.family {
        Family::Debian | Family::Arch => h.pkg(["tmux", "tmuxp"]),
        _ => h.pkg(["tmux"]),
    };
    Ok(())
}

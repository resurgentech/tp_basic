//! `root_user`: root's ssh directory and two lines of `/etc/sudoers`. Port of
//! `roles/root_user/tasks/main.yml` of the ansible repo at 79d1ca1 (identical
//! in `ansible_labtwo_2`). Applied by `labtwo.yml`'s `servers` /
//! `storage_servers` play, second after `admin_users` (`playbooks/labtwo.yml`),
//! and nowhere else. Role vars: none (the YAML reads `default_password`, in
//! the dropped task below).
//!
//! The YAML has seven tasks: three kept, two dropped, two replaced by a ruling.
//! The three kept:
//!
//! 1. `/root/.ssh` is a directory, `0700`, `root:root` (`main.yml:20-26`).
//! 2. `/etc/sudoers` carries an include of `/etc/sudoers.d` (`:28-34`). The
//!    YAML appends `#includedir /etc/sudoers.d` unless a line starting with
//!    `#includedir` exists. Fault: Ubuntu 24.04 ships the same directive as
//!    `@includedir /etc/sudoers.d` (sudo 1.9.1 and later accept both
//!    spellings), the regexp `^#includedir` misses it, and the YAML appends a
//!    second include, so every drop-in is read twice. The port matches
//!    `^[#@]includedir` and sets the line to `@includedir /etc/sudoers.d`: a
//!    stock Ubuntu or Debian line is equal to it and is kept (no rewrite, no
//!    change on run 2). On a host whose sudoers carries `#includedir` (the
//!    RedHat family) the line is rewritten once to the `@` spelling, which
//!    the sudo of every supported RedHat release (1.9.x) reads, and is equal
//!    on the next run. The fix is named: the same one `admin_users` made for
//!    the same line (`src/roles/admin_users.rs`, same directive, a narrower
//!    regexp there).
//! 3. `/etc/sudoers` carries a `secure_path` (`:36-42`), matched with the
//!    YAML's regexp `^Defaults\s*secure_path`. The line is not the YAML's
//!    (`/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin:/usr/local/sbin`) but
//!    `admin_users`' per-distro one (`admin_users::secure_path_line`): the
//!    distro's own path with `/usr/local` first, where the YAML's drops
//!    `/snap/bin` on Ubuntu and puts `/usr/local` last. `admin_users` runs
//!    first in the same play and edits the same line, so two different
//!    lines would flip it on every run (neither run would ever reach
//!    CHANGED 0); one shared line converges. On a stock Ubuntu host the
//!    line already equals it. A distro `admin_users` has not probed gets no
//!    `secure_path` edit, for the reason given there.
//! 4. Both sudoers edits are validated with `/usr/sbin/visudo -cf %s`
//!    (`:34,42`): the candidate is checked before it replaces the file, as
//!    `file.validate` does.
//!
//! Dropped:
//!
//! - `Create root user` (`:3-7`, `user: name=root state=present`). Root always
//!   exists; the task can only report `ok`. Its `register` fed only the
//!   password task.
//! - `Set default password for root (when user is new)` (`:9-18`). It runs
//!   only when the previous task changed, which cannot happen (root always
//!   exists), so it never ran on any host. `default_password` is therefore
//!   not a var of this port.
//!
//! sshd: the port has no sshd op (user, 2026-11-15: "Leave as found"). The
//! YAML sets `PermitRootLogin yes` and `PasswordAuthentication yes` in
//! `/etc/ssh/sshd_config` with `sshd -t -f %s` validation
//! (`tasks/main.yml:44-56`). The port writes no drop-in, does not edit
//! `sshd_config` and does not reload. Existing lines are left in place: a
//! converged host's main-file `PermitRootLogin yes` stays.
//!
//! - Worst case: a host the YAML never ran on keeps its distro's default
//!   `PermitRootLogin prohibit-password`, so root cannot log in with a
//!   password. On every surveyed host (2026-11-15) password authentication
//!   is off anyway (`60-cloudimg-settings.conf`), so the effective difference
//!   is nil there.
//! - A conditional edit (read `sshd -T`, edit only when nothing would
//!   change) is machinery whose every outcome is a no-op. It is not built.
//! - Faults of the YAML, recorded so nobody restores it as written: the two
//!   `lineinfile` edits go to `sshd_config`, whose `Include
//!   /etc/ssh/sshd_config.d/*.conf` comes first on Ubuntu and wins (first
//!   value wins), so a cloud-init drop-in overrides them; and the role never
//!   reloads sshd, so an edit that did take effect applies only at the next
//!   sshd start.
//!
//! Equivalence: VM oracle `ubuntu2404 labtwo_root_user`, run on its own
//! (`OC_ROLES=root_user`). The oracle's `sudoers` section captures the
//! includedir and `secure_path` lines of `/etc/sudoers`, its `sshd` section
//! `sshd -T` `permitrootlogin` and `passwordauthentication`. Intended
//! differences, declared in `tests/oracle/intended/labtwo_root_user.txt`:
//! the Ansible side appends a duplicate `#includedir`; it writes the YAML's
//! `secure_path` where telepatch keeps Ubuntu's stock line; and `sshd -T`
//! gives `permitrootlogin yes` on the Ansible side (its appended main-file
//! line takes effect on the stock VM) against `without-password` on the
//! telepatch side (ruling: leave as found). `passwordauthentication` is equal
//! (`yes` on the oracle image). Passed 2026-11-15 (T153): gating diff equal
//! to the five declared lines, telepatch run 1 and run 2 CHANGED 0 (the
//! stock image already holds `/root/.ssh` at 0700 and both sudoers lines),
//! and the captures after run 2 log in over fresh ssh connections.
//!
//! Bugs the oracle cannot see, fixed by the shape of the port: the password
//! task that never runs (dropped, above). The duplicate include and the sshd
//! edits are visible to it and declared.

use telepatch::{Host, TraceError, role};

use crate::roles::admin_users::secure_path_line;
use crate::vars::Vars;

/// `main.yml:34,42`.
const VISUDO: &str = "/usr/sbin/visudo -cf %s";

/// `main.yml:31-32`, spelled with `@` so the line Ubuntu ships is kept; a
/// `#includedir` line is rewritten to it.
const INCLUDEDIR_RE: &str = "^[#@]includedir";
const INCLUDEDIR: &str = "@includedir /etc/sudoers.d";

/// `main.yml:40`, the YAML's regexp verbatim; the line is `admin_users`'.
const SECURE_PATH_RE: &str = r"^Defaults\s*secure_path";

#[role]
pub async fn root_user(h: &Host<Vars>) -> Result<(), TraceError> {
    // main.yml:20-26.
    h.file("/root/.ssh").dir().mode(0o700).owner("root:root");
    // main.yml:28-34.
    h.file("/etc/sudoers")
        .line_re(INCLUDEDIR_RE, INCLUDEDIR)
        .validate(VISUDO);
    // main.yml:36-42, with admin_users' line (module comment, item 3).
    if let Some(line) = secure_path_line(&h.os) {
        h.file("/etc/sudoers")
            .line_re(SECURE_PATH_RE, line)
            .validate(VISUDO);
    }
    // main.yml:44-56: no sshd op, by ruling (module comment).
    Ok(())
}

// Intended differences: see tests/oracle/intended/labtwo_root_user.txt.
// Open choices: none. secure_path takes admin_users' line (module comment).

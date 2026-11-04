//! `admin_users`: the people who administer a workstation can use `sudo`
//! without a password. Port of `roles/admin_users/tasks/{main,per_user}.yml`
//! and `templates/sudoers_template.j2`; the understanding is in
//! `conversion/admin_users.md`.
//!
//! Purpose: `dev_desktop` applies it first, as root. It makes two lines of
//! `/etc/sudoers` right, then for each name in `admin_users` makes sure the
//! account exists with `/bin/bash`, is in the group sudo's policy grants,
//! has a `~/.ssh` directory and has its own drop-in in `/etc/sudoers.d`.
//! The later roles that loop over `admin_users` rely on the accounts
//! existing by then.
//!
//! The port carries the intent of each task, not its text (decision of
//! 2026-11-04 in `conversion/admin_users.md`): the bugs the doc found are
//! fixed here, each at its line. What the Docker/VM oracle then sees is
//! declared in `tests/oracle/intended/dev_desktop_kept.txt` (T56).
//!
//! Not done, as in the YAML: `sudo` itself is not installed (every desktop
//! has it), and `authorized_keys` is not touched (`~/.ssh` is created and
//! left empty). The drop-in is read only because `/etc/sudoers` includes
//! the directory, which is why the include line below is not optional.

use telepatch::facts::os::{Distro, Family, Os};
use telepatch::{Host, TraceError, role};

use crate::vars::Vars;

/// `visudo -cf` on the candidate before it replaces the live file, as the
/// YAML (`main.yml:9,17`, `per_user.yml:41`); a bad line never lands, so a
/// typo cannot lock everyone out of sudo. The drop-in's 0440 guarantee also
/// holds only through this check.
const VISUDO: &str = "visudo -cf %s";

/// `roles/admin_users/templates/sudoers_template.j2:1-3`, byte for byte,
/// including the seven spaces after `(ALL)` and the final newline. The
/// password-free line, `requiretty` off, and `env_reset` off so the user's
/// environment passes through `sudo` unchanged (`:3`).
fn sudoers_dropin(u: &str) -> String {
    format!(
        "{u} ALL=(ALL)       NOPASSWD: ALL\n\
         Defaults:{u} !requiretty\n\
         Defaults:{u} !env_reset\n"
    )
}

/// Only the Debian family has a `sudo` group. Ansible chose `wheel` for
/// `redhat_based` and `sudo` for everything else, which fails on Arch and
/// Amazon Linux 2023, where no `sudo` group exists (admin_users.md bug 4;
/// observed `Group sudo does not exist`). Here `wheel` is the answer for
/// every family without a `sudo` group, an unknown one included.
fn sudo_group(os: &Os) -> &'static str {
    if os.family == Family::Debian {
        "sudo"
    } else {
        "wheel"
    }
}

/// The distro's own `secure_path` line with `/usr/local/sbin:/usr/local/bin`
/// ensured at the front (admin_users.md bug 2). Ansible replaced the line
/// with `/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin:/usr/local/sbin`,
/// which dropped `/snap/bin` on Ubuntu and `/var/lib/snapd/snap/bin` on
/// Fedora and Amazon Linux, and put `/usr/local` behind the system
/// directories. These are the stock lines (probed in docker 2026-11-04,
/// `cat -A`, sudo installed from the distro), so on a stock host the line
/// already equals the wanted one and nothing changes; only the EL family
/// differs from its stock (`/sbin:/bin:/usr/sbin:/usr/bin`) and gains
/// `/usr/local`, keeping its own order after it.
///
/// `None` for a distro that was not probed (Pop!_OS, Mint, anything
/// `Distro::Other` outside the Arch family): writing a guessed line would
/// replace a line this port has not seen, which is the bug itself, so such
/// a host keeps whatever its sudo ships.
fn secure_path_line(os: &Os) -> Option<&'static str> {
    // Debian and Ubuntu write a TAB between the words, no spaces around `=`.
    match os.distro {
        Distro::Ubuntu => Some(
            "Defaults\tsecure_path=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin\"",
        ),
        Distro::Debian => Some(
            "Defaults\tsecure_path=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"",
        ),
        Distro::Fedora | Distro::Amazon => Some(
            "Defaults    secure_path = /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/var/lib/snapd/snap/bin",
        ),
        Distro::Rocky | Distro::Alma => Some(
            "Defaults    secure_path = /usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin",
        ),
        // Arch, and Omarchy (parsed as Arch in the fixture and as
        // `Other("omarchy")` on a host; both are in the Arch family).
        _ if os.family == Family::Arch => {
            Some("Defaults secure_path=\"/usr/local/sbin:/usr/local/bin:/usr/bin\"")
        }
        _ => None,
    }
}

#[role]
pub async fn admin_users(h: &Host<Vars>) -> Result<(), TraceError> {
    // `main.yml:3-9`. sudo reads `/etc/sudoers.d` only through this
    // directive. `@includedir` is the current spelling (sudo >= 1.9.1;
    // every supported sudo is, sudo-rs on Ubuntu 26.04 included) and Ansible's
    // `^#includedir` regexp missed it, so it appended a second, old-style
    // include on Ubuntu, Debian and Arch and every drop-in was read twice
    // (admin_users.md bug 1). `^[#@]includedir` matches either spelling, so
    // a stock Debian-family or Arch host is unchanged and the EL family's
    // `#includedir` is rewritten once, never doubled.
    h.file("/etc/sudoers")
        .line_re(r"^[#@]includedir\s+/etc/sudoers\.d", "@includedir /etc/sudoers.d")
        .validate(VISUDO);

    // `main.yml:11-17`; see `secure_path_line` for bug 2 and for which
    // hosts get no edit.
    if let Some(line) = secure_path_line(&h.os) {
        h.file("/etc/sudoers")
            .line_re(r"^Defaults\s+secure_path", line)
            .validate(VISUDO);
    }

    let group = sudo_group(&h.os);
    for u in &h.vars.admin_users {
        // `per_user.yml:3-24`, three tasks as one op. The YAML set the shell
        // and the password only when the first task created the account, so
        // an existing user kept a wrong shell; the op enforces the shell and
        // applies the hash only on creation. An empty `default_password`
        // leaves the new account locked, which is also what the YAML did
        // (the `user` module ignored `password: ""`; admin_users.md bug 3,
        // not a bug to fix). The group is added with `append`, never
        // replacing the user's others (`groups_add`).
        h.user(u)
            .shell("/bin/bash")
            .groups_add([group])
            .password_hash(&h.vars.default_password);

        // `per_user.yml:27-33`. The YAML built `/home/<u>/.ssh` from the
        // name; `~<u>` is the account's own home, the same place wherever
        // homes live in `/home` and the right one elsewhere. Nothing is
        // put in the directory (no `authorized_keys`).
        h.file(&format!("~{u}/.ssh"))
            .dir()
            .mode(0o700)
            .owner(&format!("{u}:{u}"));

        // `per_user.yml:35-42`. One drop-in per user so one can be removed
        // without touching the others. 0440 root:root and `visudo -cf`
        // before it replaces anything; a drop-in that fails the check is
        // never written, which is what makes the mode safe.
        h.file(&format!("/etc/sudoers.d/{u}"))
            .content(sudoers_dropin(u))
            .mode(0o440)
            .owner("root:root")
            .validate(VISUDO);
    }
    Ok(())
}

//! `admin_users`: the people who administer a workstation can use `sudo`
//! without a password. Port of `roles/admin_users/tasks/{main,per_user}.yml`
//! and `templates/sudoers_template.j2` of the ansible repo at commit
//! 79d1ca1 (accepted by the user 2026-11-04).
//!
//! Purpose: `dev_desktop` applies it first, as root. It makes two lines of
//! `/etc/sudoers` right, then for each name in `admin_users` makes sure the
//! account exists with `/bin/bash`, is in the group sudo's policy grants,
//! has a `~/.ssh` directory and has its own drop-in in `/etc/sudoers.d`.
//! The later roles that loop over `admin_users` rely on the accounts
//! existing by then: `docker` (`roles/docker/vars/main.yml:2`), `golang`
//! (`roles/golang/tasks/main.yml:8`) and `vm_server`
//! (`roles/vm_server/tasks/main.yml:11`) loop over the same list, and the
//! playbook runs this role first (`playbooks/dev_desktop.yml:8`). No other
//! playbook applies it. The list is `admin_users: ["{{ ansible_user }}"]`
//! (`inventories/group_vars/all:16`) and the new account's password is
//! `default_password` (`:26`), `""` at that commit.
//!
//! The port carries the intent of each task, not its text (decision of the
//! user, 2026-11-04: "we should always be porting the intent"): the four
//! bugs of the YAML are fixed here, each at its line. What the Docker/VM
//! oracle then sees of bugs 1 and 2 is declared as intended differences,
//! with the bug named, in `tests/oracle/intended/dev_desktop_kept.txt`.
//! The oracle compares what the host holds afterwards: `/etc/sudoers`
//! lines (`includedir`, `secure_path`), `getent passwd`, `id -nG`,
//! `passwd -S` (the status letter, never the hash), `~/.ssh` mode and
//! owner, and the drop-in's mode, owner and content.
//!
//! Probes, 2026-11-03, throwaway containers with `sudo` installed from the
//! distro first (the stock images have no `/etc/sudoers`): sudo version,
//! include spelling, group.
//! - ubuntu:24.04 1.9.15p5 `@includedir` `sudo`; ubuntu:26.04 sudo-rs
//!   0.2.13 `@includedir` `sudo`; debian:12 1.9.13p3 and debian:13
//!   1.9.16p2 `@includedir` `sudo`.
//! - fedora:43 and the EL images (rockylinux 9 and 10, almalinux 9 and 10)
//!   1.9.17p2 `#includedir` `wheel`; amazonlinux:2023 1.9.15p5
//!   `#includedir` `wheel`; archlinux 1.9.17p2 `@includedir` `wheel`.
//! - The EL family ships `#includedir`, not `@includedir` (an earlier
//!   note assumed the opposite for Rocky); the double include of bug 1 is
//!   Ubuntu, Debian and Arch.
//! - ubuntu:26.04's `visudo` is sudo-rs's: `visudo -cf /etc/sudoers`
//!   prints `parsed OK` and accepts a file with `#includedir` appended
//!   (rc 0), so the `validate` command works there too.
//!
//! Open: `docker run --rm amazonlinux:2 sh -c 'yum -y -q install sudo
//! >/dev/null && grep -n -E "includedir|secure_path" /etc/sudoers'` for
//! Amazon Linux 2, which the YAML's playbook mentions and no image here
//! builds.
//!
//! Reproduce a probe row: `docker run --rm ubuntu:24.04 sh -c 'apt-get
//! update -qq && apt-get install -y -qq sudo && grep -n includedir
//! /etc/sudoers'`; on `rockylinux/rockylinux:10` use `dnf -y -q install
//! sudo`, on `archlinux` `pacman -Sy --noconfirm sudo`; `fedora:43` ships
//! the file already.
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
/// Amazon Linux 2023, where no `sudo` group exists (bug 4; the YAML
/// picks the group at `per_user.yml:24` and `redhat_based` omits both,
/// `inventories/group_vars/all:4`). Observed `Group sudo does not exist`
/// on archlinux with ansible-core 2.22.0 and on rockylinux:9, 2026-11-03;
/// so the Ansible role cannot run on those two families. Probed: after
/// installing sudo the group `sudo` exists on Ubuntu and Debian and is
/// absent on Rocky, Fedora, Arch and Amazon Linux 2023. Here `wheel` is
/// the answer for every family without a `sudo` group, an unknown one
/// included; no oracle image sees the difference, since Ansible fails
/// there.
fn sudo_group(os: &Os) -> &'static str {
    if os.family == Family::Debian {
        "sudo"
    } else {
        "wheel"
    }
}

/// The distro's own `secure_path` line with `/usr/local/sbin:/usr/local/bin`
/// ensured at the front (bug 2, `main.yml:11-17`). Ansible replaced the line
/// with `/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin:/usr/local/sbin`,
/// which dropped `/snap/bin` on Ubuntu and `/var/lib/snapd/snap/bin` on
/// Fedora and Amazon Linux, and put `/usr/local` behind the system
/// directories (observed 2026-11-03 with ansible-core 2.21.6 in
/// ubuntu:24.04: the stock `Defaults	secure_path="/usr/local/sbin:...:/snap/bin"`
/// became Ansible's line). On the EL family (stock
/// `/sbin:/bin:/usr/sbin:/usr/bin`) and Arch (`/usr/local/sbin:
/// /usr/local/bin:/usr/bin`) the Ansible line only added directories.
/// These are the stock lines (probed in docker 2026-11-04,
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
    // (bug 1; observed 2026-11-03, ansible-core 2.21.6, ubuntu:24.04:
    // `/etc/sudoers` held `57:@includedir /etc/sudoers.d` and
    // `58:#includedir /etc/sudoers.d`, `"msg": "line added"`; both lines are
    // valid, so nothing broke). `^[#@]includedir` matches either spelling,
    // so a stock Debian-family or Arch host is unchanged and the EL
    // family's `#includedir` is rewritten once, never doubled. `#includedir`
    // is a directive, not a comment: sudo treats `#include` and
    // `#includedir` as directives and accepts them for sudo before 1.9.1;
    // the old spelling must not be lost where `@includedir` is absent.
    // Source: https://www.sudo.ws/docs/man/sudoers.man/ (accessed 2026-11-03)
    // Why the old regexp misbehaved: a `lineinfile` whose regexp matches
    // nothing appends the line at end of file; when it matches, the last
    // matching line is replaced, so a second run added no third line.
    // Source: https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/lineinfile_module.html (accessed 2026-11-03)
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
        // (bug 3, not a bug to fix): observed 2026-11-03 that `password: ""`
        // (`per_user.yml:17`, `default_password` is `""`) does not give an
        // empty field. ansible-core 2.21.6 on ubuntu:24.04 reported
        // `changed` for the shell but `/etc/shadow` stayed `!` (`passwd -S`
        // letter `L`); ansible-core 2.15.13 on rockylinux:9 on an existing
        // user reported `changed: false`, field `!!` (`LK`). A plain
        // `usermod -p ""` does give `NP`, so the difference is in the
        // module. The YAML set shell and password only when the first task
        // created the account (`per_user.yml:12-18`). The group is added
        // with `append`, never replacing the user's others (`groups_add`).
        h.user(u)
            .shell("/bin/bash")
            .groups_add([group])
            .password_hash(&h.vars.default_password);

        // `per_user.yml:27-33`. The YAML built `/home/<u>/.ssh` from the
        // name (`per_user.yml:31`) and a group named `<u>`, true only for
        // accounts `useradd` creates under `/home`; `~<u>` is the account's
        // own home, the same place there and the right one elsewhere.
        // Nothing is put in the directory (no `authorized_keys`).
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

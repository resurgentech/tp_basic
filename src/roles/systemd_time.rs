//! `systemd_time`: set the host's time zone. Port of
//! `roles/systemd_time/tasks/main.yml` of the ansible repo at 79d1ca1
//! (identical in `ansible_labtwo_2`). Applied by `labtwo.yml`'s
//! `servers`/`storage_servers` play and nowhere else.
//!
//! The YAML reads the zone (`timedatectl show --property=Timezone --value`,
//! `changed_when: false`) and, when it differs from `iana_tz`, runs
//! `timedatectl set-timezone {{ iana_tz }}`. The read-then-act pair is one
//! shape, a guarded state, so it is one op: `h.timezone(tz)` reads the zone
//! `/etc/localtime` links to, does nothing when it already equals `tz`, and
//! sets it otherwise (`timedatectl set-timezone` under a running systemd,
//! else a link into `/usr/share/zoneinfo`; on the Debian family it also
//! writes `/etc/timezone`, so both paths end in one state). The YAML's
//! `shell:` carries `iana_tz` unquoted into a command line; the op rejects
//! an implausible name at trace time instead.
//!
//! `tzdata`. The YAML needed the zone database installed and never said so:
//! `timedatectl set-timezone` fails with "Invalid time zone" without
//! `/usr/share/zoneinfo`. Cloud images carry it, minimal images (some
//! containers) do not. The port installs it first, `h.pkg(["tzdata"])`, on
//! every family (the package has that name on Debian, RedHat, Amazon and
//! Arch alike). The timezone op reads `pkg:tzdata`, so the engine keeps it
//! after the install. Where `tzdata` is already present (every image the
//! oracle runs) the pkg op is a no-op.
//!
//! Gate: none. The YAML has no `when`; the role runs on every distro the
//! playbook reaches. Ubuntu 22.04 is deprecated (user ruling, 2026-11-14):
//! no branch. Root only, like the op; the play runs as root through `h`.
//!
//! Var: `iana_tz`, `America/Los_Angeles` (`group_vars/all` of
//! `ansible_labtwo_2`; the 79d1ca1 mirror has no such key, so the role did
//! not run there). It lives in `SystemdTimeVars` (`src/vars.rs`).
//!
//! `#TODO set ntp?` (`tasks/main.yml:13`) is the YAML's own note that the
//! role does not configure time synchronisation. It is recorded, not built:
//! no host this role reaches has been found to need it, and there is no ruling
//! on which service (`systemd-timesyncd`, chrony) or which servers.
//!
//! Equivalence: VM oracle `ubuntu2404 labtwo_systemd_time`
//! (`OC_EXTRA={"iana_tz":"America/Los_Angeles"}` on the Ansible side,
//! `vars/container.toml` on the telepatch side). The cloud image starts in
//! `Etc/UTC`, both sides end with `/etc/localtime` resolving to
//! `/usr/share/zoneinfo/America/Los_Angeles` (the oracle's `timezone`
//! section; under a running systemd the op runs `timedatectl` too), and a
//! second run changes nothing. Passed 2026-11-15 (T152): captures identical,
//! telepatch run 2 CHANGED 0. `/etc/timezone`
//! is not captured by `image-state.sh`, so the op's extra write on Debian
//! family hosts is invisible and needs no intended difference. `tzdata` is
//! in the image: no package difference.
//!
//! Bugs the oracle cannot see, fixed by the shape of the port: the missing
//! `tzdata` install (above), and the unquoted `iana_tz` in a shell line.

use telepatch::{Host, TraceError, role};

use crate::vars::Vars;

#[role]
pub async fn systemd_time(h: &Host<Vars>) -> Result<(), TraceError> {
    // Implicit in the YAML; see the module comment.
    h.pkg(["tzdata"]);
    // main.yml:3-11, the read and the `set-timezone`, as one guarded op.
    h.timezone(&h.vars.systemd_time.iana_tz);
    Ok(())
}

// Intended differences: none declared. `/etc/timezone` (written by the op on
// the Debian family) is not captured by the oracle.
// Open choices: none. NTP is recorded above, not built.

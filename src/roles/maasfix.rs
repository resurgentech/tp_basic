//! `maasfix`: undo two quirks of a MAAS-deployed Ubuntu 24.04 image. Port of
//! `roles/maasfix/{tasks,handlers}/*.yml` of the ansible repo at 79d1ca1
//! (identical in `ansible_labtwo_2`). Applied by `labtwo.yml`'s first play
//! (`playbooks/labtwo.yml:4-7`, group `maas_installs`) and nowhere else.
//!
//! Gate: Ubuntu 24.04 and later, and Pop!_OS 24.04 and later. The YAML gates
//! both includes on `ubuntu2404_based`, which is Ubuntu or Pop!_OS at exactly
//! 24.04 (`inventories/group_vars/all:13`); "and later" is the user's Q-L10-4
//! default, so Ubuntu 26.04 gets the fix too (no 24.04-only dead end when
//! the next MAAS image arrives). Ubuntu 22.04 is deprecated (user ruling,
//! 2026-11-14): no branch. Every other distro does nothing: the quirks are
//! those of the MAAS Ubuntu image.
//!
//! 1. `/etc/apt/sources.list`. A MAAS image keeps live entries there next to
//!    `/etc/apt/sources.list.d/ubuntu.sources`, so apt reads every
//!    repository twice. The end state is "`sources.list` holds only the
//!    pointer comment, when `ubuntu.sources` exists". The YAML reaches it
//!    through two tasks (`apt_sources_ubuntu2404.yml:8-20`): `lineinfile` to
//!    append the comment, then, when that changed the file, a shell `echo >`
//!    that overwrites the whole file with the same comment. The append is
//!    dead weight (bug: its only use is as a changed flag), and it has two
//!    faults the port does not carry. When the comment is already somewhere
//!    in the file, `lineinfile` reports no change, so the overwrite never
//!    runs and the live entries stay (the end state is not reached). When
//!    the file is missing, `lineinfile` fails. The port is one
//!    `file.content` op, which reaches the end state from any start and is a
//!    no-op once reached. The existence test is a fact read: no
//!    `ubuntu.sources` means a stock layout and the file is left alone.
//!    The write needs no `become` of its own (the play runs as root through
//!    `h`), and the shell `echo` is not coverage: `file.content` is the
//!    primitive. The file is `0644 root:root`, what `echo >` leaves on an
//!    existing file and what `file.content` creates; the old content is
//!    backed up by the op before it is replaced.
//! 2. `systemd-networkd-wait-online.service`. The default waits for every
//!    link, so an unconfigured second adapter stalls boot for two minutes.
//!    The drop-in `override.conf` clears `ExecStart=` and sets it to
//!    `--any --timeout=30` (`networkd_wait_ubuntu2404.yml:3-16`). One
//!    `h.unit(..).drop_in(..)` op does the YAML's directory task (mode
//!    `0755`), the `copy` (mode `0644`), and the `daemon-reload` handler
//!    (`handlers/main.yml:3-4`): a changed unit forces exactly one reload,
//!    so the handler is not ported as a command. The YAML's handler also
//!    ran at the end of the play only; the reload now follows the change.
//!    The unit is checked with `systemd-analyze verify` before it moves in.
//!    The unit's path is `/lib/systemd/systemd-networkd-wait-online`; on
//!    Ubuntu 24.04 `/lib` is `/usr/lib`, so the text is kept as the YAML
//!    wrote it.
//!
//!    Deliberate difference from the YAML, which never touches the unit's
//!    enablement (T173, the user's "yes, do it", 2026-11-18): where
//!    `systemd-networkd` manages no link, the unit is disabled; where it
//!    manages one, it is enabled. A host whose links NetworkManager owns
//!    (veritech02) otherwise waits the drop-in's 30 s at every boot and
//!    leaves the unit failed, while `NetworkManager-wait-online.service`
//!    already brings `network-online.target` up.
//!
//!    Detection is "any `*.network` file" (`h.glob`) in
//!    `/etc/systemd/network`, `/run/systemd/network` (netplan's and
//!    cloud-init's output) and `/usr/local/lib/systemd/network`, read before
//!    any op and stopping at the first directory with one. networkd manages
//!    a link only when a `.network` file matches it, so no file means it
//!    manages nothing, before boot finishes and whatever the carrier state;
//!    a host with networkd config whose links are down keeps the files and
//!    so keeps the unit (the conservative side). `networkctl`'s setup states
//!    are not used: they are runtime only, empty while networkd is stopped
//!    (which would misread as "none"), and drop a link absent at run time.
//!    `/usr/lib/systemd/network` is not read: its vendor `.network` files
//!    are match templates for virtual links (containers, VM taps, tunnels)
//!    that may ship on every Ubuntu host, and counting them would make the
//!    branch never fire. Worst case of leaving it out: a host whose only
//!    networkd config is a vendor file matching a real NIC, and that has no
//!    other `network-online` waiter, gets the unit disabled, so units after
//!    `network-online.target` may start before that link is up. No labtwo
//!    host is like that.
//!
//!    Disable, not mask. Disabling removes the
//!    `network-online.target.wants` link, so nothing pulls the unit at boot,
//!    and NetworkManager's waiter stays wanted by the target. Worst case: a
//!    systemd upgrade or `systemctl enable systemd-networkd` (its
//!    `[Install] Also=`) re-enables the unit, and the 30 s failure returns
//!    until the next run disables it again (Debian's `deb-systemd-helper`
//!    keeps an admin's disable across upgrades, so this is rare). Masking
//!    would survive those, but a host that later starts managing a link with
//!    networkd would keep a masked waiter, and `svc` has no unmask: new
//!    primitive surface for a rare, self-healing failure. The managed branch
//!    asks `.enabled()` (a no-op where the unit is enabled, as on veritech01
//!    and the VM image), so a host that goes from "none" to "some" converges
//!    back without a by-hand step. The drop-in is written on every 24.04+
//!    host either way: inert while the unit is disabled, needed again if the
//!    host becomes managed, and already present on the real hosts.
//!
//! Equivalence: VM oracle `ubuntu2404 labtwo_maasfix` with the MAAS
//! pre-seed (`scripts/oracle-preseed/labtwo_maasfix.sh`, three live `deb`
//! lines in `sources.list`). The oracle's `apt sources` section captures
//! `sources.list` and `sources.list.d/*` content, and its `units` section the
//! sha256 of the drop-in; both sides write the same bytes, so no intended
//! difference is declared. Passed 2026-11-15 (T151): captures identical,
//! telepatch run 2 CHANGED 0. Ubuntu 26.04 is a deliberate difference from the
//! YAML (which skips it), but the oracle runs only 24.04, where it is
//! invisible. The wait-online enablement (item 2) is invisible to it too:
//! the oracle's `units` section captures only drop-in files and their sha256
//! (`scripts/image-state.sh`), not enablement, and the VM image is
//! networkd-managed (netplan's `10-netplan-*.network` in
//! `/run/systemd/network`), so the role takes the managed branch there, whose
//! `.enabled()` is a no-op.
//!
//! Bugs the oracle cannot see, all fixed by the shape of the port: the
//! pointer-already-present case above (the live entries survive in the
//! YAML), the missing-file failure, and the exact-24.04 gate.
//! Source: https://manpages.debian.org/trixie/apt/sources.list.5.en.html (accessed 2026-10-30)

use telepatch::facts::os::Distro;
use telepatch::{Host, TraceError, role};

use crate::vars::Vars;

/// `apt_sources_ubuntu2404.yml:5`, the comment the file holds, and nothing
/// else, once `ubuntu.sources` exists.
const POINTER: &str = "# Ubuntu sources have moved to /etc/apt/sources.list.d/ubuntu.sources\n";

/// `apt_sources_ubuntu2404.yml:4`.
const UBUNTU_SOURCES: &str = "/etc/apt/sources.list.d/ubuntu.sources";

/// `networkd_wait_ubuntu2404.yml:11-14`. The empty `ExecStart=` resets the
/// distro's command before the next line sets ours.
const WAIT_ONLINE: &str = "systemd-networkd-wait-online.service";

/// Where an admin, netplan or cloud-init puts the `.network` files that make
/// networkd manage a link. Not `/usr/lib/systemd/network` (module comment,
/// item 2).
const NETWORKD_DIRS: [&str; 3] = [
    "/etc/systemd/network",
    "/run/systemd/network",
    "/usr/local/lib/systemd/network",
];

const WAIT_ONLINE_OVERRIDE: &str = "\
[Service]
ExecStart=
ExecStart=/lib/systemd/systemd-networkd-wait-online --any --timeout=30
";

#[role]
pub async fn maasfix(h: &Host<Vars>) -> Result<(), TraceError> {
    // `main.yml:5,9`: `ubuntu2404_based`, widened to "and later" (module
    // comment). `major()` is the year of an Ubuntu or Pop!_OS release, so
    // `>= 24` is 24.04 and everything after it.
    if !matches!(h.os.distro, Distro::Ubuntu | Distro::PopOs)
        || !h.os.version.major().is_some_and(|m| m >= 24)
    {
        return Ok(());
    }
    // T173: does systemd-networkd manage any link? Read before any op, so
    // the glob's `*` key splits no window (module comment, item 2).
    let mut networkd_manages = false;
    for dir in NETWORKD_DIRS {
        if !h.glob(&format!("{dir}/*.network")).await.is_empty() {
            networkd_manages = true;
            break;
        }
    }
    // apt_sources_ubuntu2404.yml:3-20. One write, not append-then-overwrite.
    if h.exists(UBUNTU_SOURCES).await {
        h.file("/etc/apt/sources.list")
            .content(POINTER)
            .mode(0o644)
            .owner("root");
    }
    // networkd_wait_ubuntu2404.yml:3-16 and handlers/main.yml:3-4.
    h.unit(WAIT_ONLINE)
        .drop_in("override", WAIT_ONLINE_OVERRIDE);
    // T173: the waiter only where networkd has a link to wait for.
    if networkd_manages {
        h.svc(WAIT_ONLINE).enabled();
    } else {
        h.svc(WAIT_ONLINE).disabled();
    }
    Ok(())
}

// Intended differences: none declared. The gate is wider than the YAML's
// (Ubuntu 26.04 and later), which no oracle image of this role shows. The
// wait-online unit is disabled where networkd manages no link and enabled
// where it manages one (module comment, item 2), which the YAML never does;
// the oracle captures no enablement and its image is networkd-managed, so
// it sees only the managed branch's no-op.
// Open choices: none.

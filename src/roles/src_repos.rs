//! `src_repos`: turn on `deb-src` source repositories on the Debian family.
//! Port of `roles/src_repos/tasks/*.yml`. It exists so `kernel_build` can run
//! `apt build-dep linux`, which needs source indexes.
//!
//! Purpose: `container/kernel_build` (and `latest_kernel_build`) apply it
//! after `dev_common` and before `kernel_build`, as root. Outside the Debian
//! family it does nothing.
//!
//! Dispatch is on the file layout, not the distro or its version: the YAML
//! looks for `/etc/apt/sources.list.d/*.sources` and takes the deb822 branch
//! when any exist. The distro-version flags (`ubuntu2204_based` and others)
//! play no part. The port dispatches the same way, so a Pop!_OS or Debian
//! host with either layout takes the right branch. All four Debian-family
//! images (debian12/13, ubuntu2404/2604) use deb822; both of each image's
//! stanzas (main and security) are edited.
//!
//! The edit is guarded and exact. It does nothing if any `*.sources` file
//! already has a `Types:` line mentioning `deb-src` (one file with it skips
//! all files), and it rewrites only lines that are exactly `Types: deb`: a
//! stanza that reads `Types: deb` plus other text, or lists the types in
//! another order, is left alone. It leaves no backup file. The YAML prints
//! `SOURCES_CHANGED` after a change, and that is the only thing its apt cache
//! update waited for.
//!
//! The deb822 format is current: apt's `sources.list(5)` says the one-line
//! format "is deprecated and may eventually be removed, but not before
//! 2029", and Ubuntu 24.04 made `ubuntu.sources` the default. Ubuntu's
//! kernel team documents this same edit (add `deb-src` to `Types:`, then
//! `apt update`, then `apt build-dep`).
//! Source: https://manpages.debian.org/trixie/apt/sources.list.5.en.html (accessed 2026-10-30)
//! Source: https://discourse.ubuntu.com/t/spec-apt-deb822-sources-by-default/29333 (accessed 2026-10-30)
//! Source: https://documentation.ubuntu.com/kteam-docs/public/how-to/build-kernel.html (accessed 2026-10-30)
//!
//! Dropped branch: the legacy one-line `sources.list` branch
//! (`apt_sources_list.yml`, reached only when no `*.sources` file exists).
//! No image reaches it, and it never worked: it copies `sources.list` to
//! `sources.list.ansible`, then runs `sed -i` on
//! `sources.list.ansible-src`, a file nothing creates, and reads and removes
//! it. The script has no `set -e`, so the errors scroll past and the exit
//! status is that of the last command, which succeeds. Observed on a stand-in
//! file (2026-10-30): with no `deb-src` line it prints three errors, exits 0
//! and leaves the file unchanged; only when `# deb-src` lines already exist
//! does it work, by uncommenting them. Nobody should port its sed as if it
//! worked. It also ran no apt cache update, so a host that took it would run
//! `build-dep` against lists lacking the source indexes. Consequence: on a
//! host with a one-line layout (an older Debian or Ubuntu workstation, or a
//! Pop!_OS host with no `*.sources` file) this role does nothing and
//! `build-dep` fails for lack of `deb-src` lines.
//!
//! Equivalence (2026-10-30): the docker oracle reported ubuntu2404 and
//! rockylinux10 identical on `kernel_build` (gating and versions) against
//! ansible 79d1ca16bfdeb678496986e1d7a0d407b06f4b45. Only ubuntu2404
//! exercises this role (rockylinux10 skips it). The other 11 images were not
//! run as a gate; debian12/13 and ubuntu2604 follow the same code path, and
//! their plan snapshots were read against the YAML.
//!
//! Open: whether a Pop!_OS workstation uses deb822 files
//! (`ls /etc/apt/sources.list.d/*.sources` on one). If it prints nothing the
//! host takes the dropped legacy branch.

use telepatch::facts::os::Distro;
use telepatch::{Host, Key, TraceError, role, sh};

use crate::vars::Vars;

/// The deb822 sources files the edit works on.
const SOURCES_GLOB: &str = "/etc/apt/sources.list.d/*.sources";

#[role]
pub async fn src_repos(h: &Host<Vars>) -> Result<(), TraceError> {
    // main.yml:4-15. `debian_based` (`inventories/group_vars/all:6`) tests
    // the distribution. Nothing runs elsewhere.
    if !matches!(h.os.distro, Distro::Debian | Distro::Ubuntu | Distro::PopOs) {
        return Ok(());
    }

    // main.yml:4-12 and apt_sources_deb822.yml:7-15. The YAML finds
    // `*.sources` files first and takes the deb822 branch when any exist;
    // there is no glob fact, so the guard sits in the op: skip when no
    // `*.sources` file exists, or when any already has a `deb-src` type
    // (apt_sources_deb822.yml:9-11, one file with it skips all). Only lines
    // that are exactly `Types: deb` are rewritten (:12).
    //
    // The legacy sources.list branch (main.yml:14-15,
    // apt_sources_list.yml) is not ported: no image reaches it and it is
    // broken as written (its `.ansible-src` file is never created, :8-10).
    //
    // The op declares the sources files as its writes, not `*`: that still
    // makes the next apt op refresh the cache (apt_sources_deb822.yml:17-22,
    // "Update apt package cache again" is that rule) and does not fence the
    // package installs around it. The refresh matters: the source indexes
    // exist only after it, the Dockerfile's own `apt-get update` ran against
    // the old sources, and the layer that built `dev_base` deleted the lists.
    // The `build-dep` after this role must stay after the edit and its
    // refresh (a barrier() on the role if a merge ever hoists it). The rule
    // is static, so the refresh runs on every play, not only when the sed
    // changed something as in the YAML (cost: one oracle-invisible
    // `apt-get update`).
    sh!(
        h,
        "sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/*.sources\necho SOURCES_CHANGED",
        unless = "! ls /etc/apt/sources.list.d/*.sources >/dev/null 2>&1 || grep -qs '^Types:.*deb-src' /etc/apt/sources.list.d/*.sources",
        changed_if = "SOURCES_CHANGED"
    )
    .writes([Key::file(SOURCES_GLOB)]);
    Ok(())
}

// Intended differences: none. Open choices: none.
// Replace the `sh!` with the `repo` primitive when it is built (a sed over a
// glob has no primitive today).

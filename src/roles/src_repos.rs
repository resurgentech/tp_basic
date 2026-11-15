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
//! The edit is the engine's `h.distro_repos().source_packages()` (T143):
//! `deb-src` is added to every stanza of the distro's own deb822 file
//! (`ubuntu.sources`, `debian.sources`) that lacks it, and nothing else in
//! that file changes. Unlike the YAML's `sed` over `*.sources`, third-party
//! sources (docker's, written by `repo`) are never touched: a repository
//! that publishes no sources would make `apt-get update` fail. The YAML
//! skipped every file once any had `deb-src`; the primitive settles per
//! stanza, so a half-enabled file is finished. The op writes the file's key,
//! so the next apt op refreshes the cache, as the YAML's
//! `SOURCES_CHANGED` did; the original is backed up before the rewrite.
//!
//! Converging the old labtwo result: the labtwo copy of this role
//! (`ansible_labtwo_2/roles/src_repos/tasks/apt_sources_list_d.yml:3-15`)
//! wrote `/etc/apt/sources.list.d/ubuntu-src.sources`, a second copy of
//! `ubuntu.sources` with `Types: deb-src` only. With deb-src now on
//! `ubuntu.sources` itself, that copy makes apt warn that every source is
//! configured multiple times, on every update. So on Ubuntu the role
//! removes it first (the user's 2026-11-14 ruling: the role converges those
//! hosts; nothing is done by hand).
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
//! host with a one-line layout (no `ubuntu.sources`/`debian.sources`) the
//! op fails with `telepatch: distro_repos: no <path> (one-line sources.list
//! layout is not supported)`, where the old port skipped and let
//! `build-dep` fail later.
//!
//! Equivalence (2026-10-30): the docker oracle reported ubuntu2404 and
//! rockylinux10 identical on `kernel_build` (gating and versions) against
//! ansible 79d1ca16bfdeb678496986e1d7a0d407b06f4b45. Only ubuntu2404
//! exercises this role (rockylinux10 skips it). The other 11 images were not
//! run as a gate; debian12/13 and ubuntu2604 follow the same code path, and
//! their plan snapshots were read against the YAML.
//!
//! Pop!_OS keeps its sources in `system.sources`, which the primitive does
//! not know (no recording), so on Pop!_OS the op is a trace error naming the
//! distro: loud, where a silent skip would let `build-dep` fail later. No
//! playbook in this repo targets Pop!_OS with this role today.

use telepatch::facts::os::Distro;
use telepatch::{Host, TraceError, role};

use crate::vars::Vars;

/// The old labtwo role's deb-src-only copy of `ubuntu.sources`.
const LEGACY_SRC: &str = "/etc/apt/sources.list.d/ubuntu-src.sources";

#[role]
pub async fn src_repos(h: &Host<Vars>) -> Result<(), TraceError> {
    // main.yml:4-15. `debian_based` (`inventories/group_vars/all:6`) tests
    // the distribution. Nothing runs elsewhere.
    if !matches!(h.os.distro, Distro::Debian | Distro::Ubuntu | Distro::PopOs) {
        return Ok(());
    }
    // Converge the old labtwo result before the edit (module comment).
    if h.os.distro == Distro::Ubuntu {
        h.file(LEGACY_SRC).absent();
    }
    // apt_sources_deb822.yml:7-22: deb-src on the distro's own sources, and
    // the cache refresh the next apt op runs because the file's key is
    // written. The `build-dep` after this role must stay after the edit and
    // its refresh; the op writes a `repo:` key, so no distro pkg op is
    // hoisted across it.
    h.distro_repos().source_packages();
    Ok(())
}

// Intended differences: third-party `.sources` files keep their types (the
// YAML's sed gave them deb-src too); the old labtwo `ubuntu-src.sources` is
// removed. Neither is visible to the oracle's images, which hold only the
// distro's file. Open choices: none.

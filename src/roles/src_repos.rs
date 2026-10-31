//! `src_repos`: turn on `deb-src` source repositories on the Debian family.
//! Port of `roles/src_repos/tasks/*.yml`; the decisions are in
//! `conversion/kernel_build.md`.

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
    // package installs around it.
    sh!(
        h,
        "sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/*.sources\necho SOURCES_CHANGED",
        unless = "! ls /etc/apt/sources.list.d/*.sources >/dev/null 2>&1 || grep -qs '^Types:.*deb-src' /etc/apt/sources.list.d/*.sources",
        changed_if = "SOURCES_CHANGED"
    )
    .writes([Key::file(SOURCES_GLOB)]);
    Ok(())
}

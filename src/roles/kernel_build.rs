//! `kernel_build`: build dependencies for the distro's kernel packages.
//! Port of `roles/kernel_build/tasks/*.yml`.
//!
//! Purpose: `container/kernel_build` turns a `dev_base` image into one that
//! can build the distro's own kernel packages: `dev_common` (again), then
//! `src_repos`, then this role, as root, for all 13 distros. The role also
//! runs in `latest_kernel_build`, on top of `rust_build`. `kernel_build`
//! deliberately uses the distro's own kernel toolchain, Rust included, and
//! not rustup; no file of this role installs rustup. Rust arrives per
//! family: Arch installs the distro `rust`, `rust-bindgen` and `rust-src`
//! (the YAML says the rest are kernel makedeps that `makepkg --syncdeps`
//! would otherwise download on every build); Ubuntu gets `rustc` only as a
//! dependency of the `linux` source package; Debian and the RedHat family
//! get none.
//!
//! One if/else chain per family, each with its own list. Amazon Linux 2023
//! is not RedHat (the YAML's `redhat_based` omits Amazon) and its list omits
//! `redhat-rpm-config`, `java-devel`, `libnl3-devel`, `kabi-dw` and
//! `libbabeltrace-devel`; do not merge the two lists into one table. Pop!_OS
//! is both `debian_based` and `ubuntu_based`, so it takes the Ubuntu branch.
//!
//! The port is 1:1 with the Ansible role: every quirk is carried over so the
//! equivalence oracle can tell a port bug from a chosen change. Changes that
//! alter what the oracle sees are listed at the end of this file under
//! "After equivalence" and are not made yet.
//!
//! Equivalence (2026-10-30): the docker oracle (package names and arch,
//! system pip names, rustup state, apt sources, `/usr/local/bin` names)
//! reported ubuntu2404 and rockylinux10 identical on `kernel_build`, gating
//! and versions, against ansible 79d1ca16bfdeb678496986e1d7a0d407b06f4b45.
//! The other 11 images were not run as a gate; their plan snapshots were read
//! against the YAML. Installed names differ from requested names in places
//! (see "Provided names" below), and the oracle compares installed names.
//!
//! Dropped branches, which no image reaches and which are not ported: Debian
//! 10 (`debian10.yml` is the same list as `debian.yml`, and a Debian 10 host
//! would have run both), Amazon Linux 2 (`amazonlinux2.yml` installs EPEL 7,
//! runs `yumdownloader --source kernel` with no `creates` so it re-downloads
//! on every play, and pip-installs by `shell`), `debian_long.yml` (no
//! `include_tasks` names it), and the commented hack in `ubuntu.yml:26-29`.
//! No image of Debian 10, Amazon Linux 2, Ubuntu 20.04 or 22.04 exists. The
//! Ubuntu 20.04/22.04/24.04 flags in `group_vars` are not read by this role.
//!
//! Provided names. Requested names resolve to other installed names, and the
//! port requests the same names as the YAML: `java-devel` (to
//! `java-25-openjdk-devel` on Fedora, `java-17-` on EL9, `java-21-` on
//! EL10), `zlib-devel` (to `zlib-ng-compat-devel` on Fedora and EL10),
//! `perl(ExtUtils::Embed)` (to `perl-ExtUtils-Embed`) and, on Ubuntu,
//! `libbabeltrace-ctf-dev` (installed as `libbabeltrace-dev`, whose dpkg
//! status carries `Provides: libbabeltrace-ctf-dev`).
//!
//! Open: the build-dep package set is archive-dependent (whatever the `linux`
//! source package declares that day), so the oracle sees its names, not the
//! YAML's; a fresh build of kernel_build-ubuntu2404 against its `dev_base`
//! parent on another day may differ.
//!
//! Open: `just` is present in the reference `kernel_build-ubuntu2404` image
//! and installed by no role of this playbook; `docker history --no-trunc` on
//! that image names its layer, and both oracle sides must be built from the
//! same base.

use telepatch::facts::os::{Distro, Family, Os};
use telepatch::{Host, TraceError, role};

use crate::vars::Vars;

/// `inventories/group_vars/all:8`. Ubuntu and Pop!_OS.
fn ubuntu_based(os: &Os) -> bool {
    matches!(os.distro, Distro::Ubuntu | Distro::PopOs)
}

/// `inventories/group_vars/all:6`. Tests the distribution, not the family.
fn debian_based(os: &Os) -> bool {
    matches!(os.distro, Distro::Debian | Distro::Ubuntu | Distro::PopOs)
}

/// `inventories/group_vars/all:4`. Amazon is not in the list.
fn redhat_based(os: &Os) -> bool {
    os.family == Family::RedHat
        && match &os.distro {
            Distro::Fedora | Distro::Rocky | Distro::Alma => true,
            Distro::Other(id) => id == "centos" || id == "rhel",
            _ => false,
        }
}

/// `inventories/group_vars/all:5`. Tests the family (omarchy is Arch).
fn arch_based(os: &Os) -> bool {
    os.family == Family::Arch
}

/// `inventories/group_vars/all:10`.
fn amazonlinux2023_based(os: &Os) -> bool {
    os.distro == Distro::Amazon && os.version.major() == Some(2023)
}

#[role]
pub async fn kernel_build(h: &Host<Vars>) -> Result<(), TraceError> {
    // main.yml:4-30. Dropped branches (debian10, amazonlinux2,
    // debian_long.yml) are not ported (see the module doc).
    if ubuntu_based(&h.os) {
        // ubuntu.yml:1-24. build-dep first, then the extras: the YAML gives
        // no reason for Ubuntu's order or Debian's reverse, and order shows
        // in which package satisfies a dependency (the extras include a
        // provided name, libbabeltrace-ctf-dev), so each family keeps its
        // own order rather than being normalised. The build-dep reads the
        // source package's dependency list, not a list of names, so it is
        // not mergeable with the plain installs around it. It must run after
        // src_repos' edit and the cache refresh that follows it; the apt
        // calls here never refresh the cache themselves, and the plan's apt
        // cache rule does it before the first apt op after the sources edit.
        // If a merge ever hoists it, give the role a `barrier()`.
        // `build-dep linux` is the documented method on both families; the
        // Ubuntu guide's second argument (the running kernel's source
        // package) has no meaning inside a container.
        // Source: https://documentation.ubuntu.com/kteam-docs/public/how-to/build-kernel.html (accessed 2026-10-30)
        // Source: https://kernel-team.pages.debian.net/kernel-handbook/ch-common-tasks.html (accessed 2026-10-30)
        h.pkg(["linux"]).build_dep();
        // The extras' python3-pip/jinja2/yaml/git repeat dev_common
        // (ubuntu.yml:19-22) and are not repeated: deduplicating changes no
        // installed name. python3-lxml is the only new Python name.
        h.pkg([
            "libperl-dev",
            "libzstd-dev",
            "libpython3-dev",
            "binutils-dev",
            "equivs",
            "dwarves",
            "systemtap-sdt-dev",
            "libbabeltrace-dev",
            "libbabeltrace-ctf-dev",
            "python3-lxml",
        ]);
    } else if debian_based(&h.os) {
        // debian.yml:1-19. The extras first, build-dep last: the reverse of
        // Ubuntu, kept as written. The plan keeps the order because the
        // build-dep op writes `*`, so no later install merges above it.
        h.pkg([
            "libncurses-dev",
            "libssl-dev",
            "libelf-dev",
            "libudev-dev",
            "libpci-dev",
            "libiberty-dev",
            "equivs",
            "dwarves",
            "dkms",
        ]);
        h.pkg(["linux"]).build_dep();
    } else if redhat_based(&h.os) {
        // redhat.yml:1-5. Kept: upgrade pip itself to the latest, before
        // the dnf work, on the RedHat family only (Amazon and the Debian and
        // Arch files have no such task). Needs the rpm python3-pip that
        // dev_common installs just before; no base image has it. The task
        // names no interpreter, so the target is the system python3, as
        // root, into the same place as the YAML. The result is visible to
        // the oracle: a second pip tree under
        // `/usr/local/lib/python3.N/site-packages` that shadows the rpm one,
        // and `pip`, `pip3`, `pip3.N` newly in `/usr/local/bin` (observed
        // 2026-10-30: 26.0.1 or 26.2.2 over rpm copies of 21.3.1 to 26.0.1).
        // The version is whatever PyPI holds on the build day; the oracle
        // compares names. No PEP 668 flag: the RedHat family has no
        // `EXTERNALLY-MANAGED` marker (see dev_common).
        // Source: https://pip.pypa.io/en/stable/installation/ (accessed 2026-10-30)
        // Source: https://peps.python.org/pep-0668/ (accessed 2026-10-30)
        h.pip(["pip"]).latest();
        // redhat.yml:7-40. A fixed approximation of what `dnf builddep` on
        // the kernel spec computes; it does not follow the spec when the
        // spec changes (see "After equivalence"). All 30 names resolved on
        // the six RedHat-family images (2026-10-30). No fetched vendor page
        // names `kabi-dw` or `libbabeltrace-devel`.
        // Source: https://fedoraproject.org/wiki/Building_a_custom_kernel (accessed 2026-10-30)
        h.pkg([
            "rpmdevtools",
            "rpm-build",
            "redhat-rpm-config",
            "audit-libs-devel",
            "binutils-devel",
            "elfutils-devel",
            "elfutils-libelf-devel",
            "java-devel",
            "libcap-devel",
            "ncurses-devel",
            "newt-devel",
            "numactl-devel",
            "openssl-devel",
            "pciutils-devel",
            "libnl3-devel",
            "xz-devel",
            "zlib-devel",
            "perl-interpreter",
            "perl-devel",
            "perl-generators",
            "perl-Carp",
            "perl(ExtUtils::Embed)",
            "python3-sphinx",
            "dwarves",
            "kabi-dw",
            "libbabeltrace-devel",
            "libbpf-devel",
            "libcap-ng-devel",
            "libmnl-devel",
            "bpftool",
        ]);
        // redhat.yml:42-48: jinja2, GitPython, pyaml again; dev_common
        // already installed them (dropped).
    } else if amazonlinux2023_based(&h.os) {
        // amazonlinux2023.yml:1-30. Its own list, not RedHat's: it omits
        // redhat-rpm-config, java-devel, libnl3-devel, kabi-dw and
        // libbabeltrace-devel. On the image `amazon-rpm-config` provides
        // the first and the other four are not installed. No pip upgrade:
        // the file has no such task, so the system pip stays the rpm one.
        h.pkg([
            "rpmdevtools",
            "rpm-build",
            "audit-libs-devel",
            "binutils-devel",
            "elfutils-devel",
            "elfutils-libelf-devel",
            "libcap-devel",
            "ncurses-devel",
            "newt-devel",
            "numactl-devel",
            "openssl-devel",
            "pciutils-devel",
            "xz-devel",
            "zlib-devel",
            "perl-interpreter",
            "perl-devel",
            "perl-generators",
            "perl-Carp",
            "perl(ExtUtils::Embed)",
            "python3-sphinx",
            "dwarves",
            "libbpf-devel",
            "libcap-ng-devel",
            "libmnl-devel",
            "bpftool",
        ]);
        // amazonlinux2023.yml:32-38: python libs again (dropped; the YAML
        // comment says they are "required for the our build scripts", which
        // live outside this playbook).
    } else if arch_based(&h.os) {
        // archlinux.yml:1-14. `bc` repeats dev_common and is requested
        // again as written. `rust` installs rustc and cargo from the
        // distro, not rustup. `pahole`, `pacman-contrib`, `bc` and
        // `devtools` are the role's own choices for makepkg (no fetched page
        // lists them); the kernel's Rust quick-start names `rust`,
        // `rust-src` and `rust-bindgen`, and says the standard library
        // source is needed because the build cross-compiles `core`.
        // Source: https://www.kernel.org/doc/html/latest/rust/quick-start.html (accessed 2026-10-30)
        // Source: https://man.archlinux.org/man/pkgctl-repo-clone.1.en (accessed 2026-10-30)
        h.pkg([
            "devtools",
            "pacman-contrib",
            "bc",
            "pahole",
            "rust",
            "rust-bindgen",
            "rust-src",
        ]);
    }
    Ok(())
}

// After equivalence. Each changes what the oracle sees, so each is its own
// change with its own oracle diff, made only once the 13-image oracle is
// green:
// - Remove the RedHat `pip` latest or pin pip; removing it removes `pip`,
//   `pip3` and `pip3.N` from `/usr/local/bin` and the second pip tree.
//   Decide whether the build scripts need a newer pip than the rpm copy.
// - Replace the fixed RedHat package list with the output of
//   `dnf builddep --assumeno kernel.spec` (package list changes).
// - Decide whether `python3-lxml` and the Python libraries belong to the
//   kernel image or to `dev_common` (package list changes on Ubuntu).
// - Name the Ubuntu build-dep source packages instead of the archive default
//   (package list changes).
// - Check the Arch list against `makedepends` from `pkgctl repo clone linux`
//   and `makepkg --printsrcinfo` (an open check, not needed for equivalence).

//! `kernel_build`: build dependencies for the distro's kernel packages.
//! Port of `roles/kernel_build/tasks/*.yml`; the decisions and the reasons
//! for each list are in `conversion/kernel_build.md`.

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
    // debian_long.yml) are not ported.
    if ubuntu_based(&h.os) {
        // ubuntu.yml:1-24. build-dep first, then the extras. It runs after
        // src_repos' edit and the cache refresh that follows it.
        h.pkg(["linux"]).build_dep();
        // The extras' python3-pip/jinja2/yaml/git repeat dev_common
        // (ubuntu.yml:19-22) and are not repeated; python3-lxml is new.
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
        // debian.yml:1-19. The extras first, build-dep last.
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
        // redhat.yml:1-5. Kept: upgrade pip itself, before the dnf work.
        // Needs the rpm python3-pip that dev_common installs.
        h.pip(["pip"]).latest();
        // redhat.yml:7-40.
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
        // amazonlinux2023.yml:1-30. Its own list, not RedHat's.
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
        // amazonlinux2023.yml:32-38: python libs again (dropped).
    } else if arch_based(&h.os) {
        // archlinux.yml:1-14.
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

//! `dev_common`: the common development toolchain. Port of
//! `roles/dev_common/tasks/*.yml`; the decisions and the reasons for each
//! list are in `conversion/dev_base.md`.

use telepatch::facts::os::{Distro, Family, Os};
use telepatch::{Host, TraceError, role, sh};

use crate::vars::Vars;

/// `inventories/group_vars/all:4`. Amazon is not in the list.
fn redhat_based(os: &Os) -> bool {
    os.family == Family::RedHat
        && match &os.distro {
            Distro::Fedora | Distro::Rocky | Distro::Alma => true,
            Distro::Other(id) => id == "centos" || id == "rhel",
            _ => false,
        }
}

/// `inventories/group_vars/all:6`. Tests the distribution, not the family.
fn debian_based(os: &Os) -> bool {
    matches!(os.distro, Distro::Debian | Distro::Ubuntu | Distro::PopOs)
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
pub async fn dev_common(h: &Host<Vars>) -> Result<(), TraceError> {
    // main.yml:4-22. One branch per image; an image no flag matches gets none.
    if debian_based(&h.os) {
        // debian.yml:1-50. The python deps run on the whole family
        // (debian.yml:44 has no `when`).
        h.pkg(["python3-apt", "python3-pip"]);
        h.pkg([
            "build-essential",
            "cmake",
            "clang",
            "llvm",
            "lld",
            "git",
            "rsync",
            "gcc",
            "gnupg",
            "rpm",
            "cppcheck",
            "autoconf",
            "asciidoc",
            "bc",
            "cpio",
            "bison",
            "flex",
            "gawk",
            "gettext",
            "gzip",
            "hostname",
            "m4",
            "net-tools",
            "openssl",
            "xmlto",
            "zstd",
            "diffstat",
            "sshpass",
            "btop",
            "acl",
            "curl",
        ]);
        h.pkg([
            "python3-jinja2",
            "python3-git",
            "python3-yaml",
            "python3-hvac",
        ]);
    } else if redhat_based(&h.os) {
        // redhat.yml:1-31
        h.pkg([
            "@Development Tools",
            "cmake",
            "clang",
            "llvm",
            "lld",
            "bison",
            "flex",
            "git",
            "rsync",
            "gcc",
            "zlib-devel",
            "gnupg",
            "bc",
            "newt",
            "slang",
            "xmlto",
            "net-tools",
            "rpm-build",
            "dpkg-devel",
            "dpkg",
            "dpkg-dev",
            "zstd",
            "python3",
            "python3-devel",
            "python3-docutils",
            "python3-pip",
        ]);
    } else if amazonlinux2023_based(&h.os) {
        // amazonlinux2023.yml:1-25
        h.pkg([
            "@Development Tools",
            "cmake",
            "clang",
            "llvm",
            "lld",
            "git",
            "rsync",
            "gcc",
            "zlib-devel",
            "bc",
            "newt",
            "slang",
            "xmlto",
            "net-tools",
            "rpm-build",
            "zstd",
            "wget",
            "python3",
            "python3-devel",
            "python3-pip",
        ]);
    } else if arch_based(&h.os) {
        // archlinux.yml:1-24
        h.pkg([
            "base-devel",
            "cmake",
            "clang",
            "llvm",
            "lld",
            "git",
            "rsync",
            "gnupg",
            "bc",
            "cpio",
            "xmlto",
            "zstd",
            "wget",
            "python",
            "python-pip",
            "python-yaml",
            "python-jinja",
            "python-gitpython",
            "python-pytest",
        ]);
    }

    // main.yml:26-32. PEP 668: Debian and Arch Python is externally managed,
    // their branches installed these as distro packages. pip itself came
    // from `python3-pip` in the branch above.
    if !(debian_based(&h.os) || arch_based(&h.os)) {
        h.pip(["jinja2", "GitPython", "pyaml"]);
    }

    // main.yml:34-37. Runs every time, as in the YAML (guarding it is an
    // "after equivalence" item). Needs curl: installed by the Debian branch
    // above, shipped by the other bases. The subshell keeps `pipefail` from
    // leaking into the persistent shell.
    sh!(
        h,
        "(set -o pipefail && curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh)"
    );
    Ok(())
}

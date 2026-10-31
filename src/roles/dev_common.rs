//! `dev_common`: the common development toolchain. Port of
//! `roles/dev_common/tasks/*.yml`.
//!
//! Purpose: `container/dev_base` installs the common development toolchain
//! into every image above a distro's `base` image (13 distros: debian12/13,
//! ubuntu2404/2604, fedora43/44, rockylinux9/10, almalinux9/10,
//! amazonlinux2023, arch, omarchy), as root. Workstations (including
//! Pop!_OS) get the same role through the same distro flags. The role is
//! applied again on top of `dev_base` by `kernel_build`, `rust_build` and
//! `latest_kernel_build`, so every later image re-runs it.
//!
//! The package upgrade and the cache cleanup around each image build belong
//! to the Dockerfiles in `docker_images`, not to this role. Keep the full
//! upgrade there: Debian `apt-get upgrade`, RedHat `dnf update`, Arch
//! `pacman -Syu` (Arch has no partial upgrade).
//!
//! The port is 1:1 with the Ansible role: every known fragility is carried
//! over so the equivalence oracle can tell a port bug from a chosen change.
//! Changes that alter what the oracle sees are listed at the end of this
//! file under "After equivalence" and are not made yet.
//!
//! Equivalence (2026-10-30): the docker oracle (package names and arch,
//! system pip names, rustup state, apt sources, `/usr/local/bin` names)
//! reported ubuntu2404 and rockylinux10 identical against ansible
//! 79d1ca16bfdeb678496986e1d7a0d407b06f4b45. The other 11 images were not
//! run; fedora43 and fedora44 carry the open `@Development Tools` caveat
//! below.
//!
//! Dropped branches, which no image reaches and which are not ported:
//! Amazon Linux 2 (its own task file), and the Debian 10 and Ubuntu 20.04
//! and 22.04 flags, which this role never read. The flags stay in the
//! Ansible `group_vars` for roles not yet ported. Consequence: an Amazon
//! Linux 2 host gets no package branch but would still take the pip step,
//! as the Ansible flags say.

use telepatch::facts::os::{Distro, Family, Os};
use telepatch::{Host, TraceError, role, sh};

use crate::vars::Vars;

/// Amazon Linux is not in this family, although telepatch parses it as
/// `Family::RedHat`: it has its own task file per release and never takes the
/// RedHat branch. The bake file maps amazonlinux2023 to the `redhat`
/// Dockerfile, which only picks `dnf`; the playbook still sees distro
/// Amazon, so `os` must keep it apart. Mirrors `redhat_based` in the
/// inventory `group_vars`.
fn redhat_based(os: &Os) -> bool {
    os.family == Family::RedHat
        && match &os.distro {
            Distro::Fedora | Distro::Rocky | Distro::Alma => true,
            Distro::Other(id) => id == "centos" || id == "rhel",
            _ => false,
        }
}

/// Tests the distribution, not the family, so a Debian-family distro outside
/// this list (Mint, say) gets no branch, as in the YAML. Pop!_OS stays a
/// member because workstations use it, though no image builds it.
fn debian_based(os: &Os) -> bool {
    matches!(os.distro, Distro::Debian | Distro::Ubuntu | Distro::PopOs)
}

/// Tests the family, the one flag that does: Omarchy reaches the Arch branch
/// only through its OS family (telepatch parses omarchy as Arch).
fn arch_based(os: &Os) -> bool {
    os.family == Family::Arch
}

/// Amazon Linux 2023 only; its package list differs from RedHat's.
fn amazonlinux2023_based(os: &Os) -> bool {
    os.distro == Distro::Amazon && os.version.major() == Some(2023)
}

#[role]
pub async fn dev_common(h: &Host<Vars>) -> Result<(), TraceError> {
    // One branch per image; an image no flag matches gets none.
    if debian_based(&h.os) {
        // `python3-apt` is what Ansible's `apt` module imports on the target;
        // it serves Ansible, not a developer, and stays until the role no
        // longer runs under Ansible (see "After equivalence").
        // Source: https://docs.ansible.com/ansible/latest/collections/ansible/builtin/apt_module.html (accessed 2026-10-30)
        h.pkg(["python3-apt", "python3-pip"]);
        // The optimizer merges the three Debian calls into one apt install,
        // which also does the one cache refresh the YAML left to the
        // Dockerfile's `apt-get update`. Names are requested as the YAML
        // requests them. `rsync` is listed once (the YAML repeats it) and
        // `gcc` sits beside `build-essential` as in the YAML; both are
        // harmless redundancy. `curl` is here because the uv step below needs
        // it and the Debian and Ubuntu bases ship none (observed
        // 2026-10-30).
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
        // PEP 668: Debian Python is externally managed, so these libraries
        // come as distro packages, not pip (see the pip step below). This runs
        // on the whole Debian family (Debian 12/13, Ubuntu 24.04/26.04,
        // Pop!_OS); the Ansible task was misnamed "Ubuntu2404 python deps"
        // though it had no condition. `python3-yaml` is PyYAML, not `pyaml`.
        // `python3-hvac` is there for Ansible's vault/openbao lookups, not for
        // development; it stays until equivalence (see "After equivalence").
        h.pkg([
            "python3-jinja2",
            "python3-git",
            "python3-yaml",
            "python3-hvac",
        ]);
    } else if redhat_based(&h.os) {
        // `@Development Tools` is a dnf group requested by display name. On EL
        // the name is the group and the ID `development-tools` does not exist;
        // on Fedora the ID is `development-tools`. The explicit `gcc`, `clang`,
        // `bison`, `flex` beside the group keep a compiler present whatever the
        // group holds. Names resolve through package provides, so the
        // installed rpm name can differ from the requested one (`gnupg`); the
        // oracle compares installed names. EPEL and CRB, enabled by `base.el`
        // outside this repo, serve `dpkg`, `dpkg-dev`, `dpkg-devel` and the
        // `*-devel` packages (observed 2026-10-30: epel on Rocky 9). Amazon
        // below lacks the `dpkg*` names (the Amazon 2 task file says `dpkg-dev`
        // was lost). Open: fedora43 and fedora44 run dnf5, whose CLI rejects
        // the display name ("No match for argument: Development Tools",
        // observed 2026-10-30), so this port can fail there where the Ansible
        // `dnf` module may not; Fedora is outside the oracle's acceptance set
        // and the capture from the existing images settles it. telepatch's own
        // installed-group check (`dnf group list --installed | grep`) is not
        // the module's either.
        // Source: https://discussion.fedoraproject.org/t/cant-install-development-tools-on-fedora-linux-silverblue-41/134864 (accessed 2026-10-30)
        // Source: https://docs.ansible.com/ansible/latest/collections/ansible/builtin/dnf_module.html (accessed 2026-10-30)
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
        // Own branch: Amazon is outside `redhat_based`. Same `@Development
        // Tools` group as above, by name (dnf 4 here). Differs from the
        // RedHat list: no `gnupg`, `bison`, `flex`, `dpkg*` or
        // `python3-docutils`; adds `wget`.
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
        // PEP 668: Arch Python is externally managed, so the libraries are
        // distro packages here. The role's claim for Arch rests on its own
        // comment; the marker file was observed on arch and omarchy
        // 2026-10-30. The Omarchy repo comes from the base image, not this
        // role. `python-pytest` is carried over as written.
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

    // PEP 668: Debian and Arch Python is externally managed (an
    // `EXTERNALLY-MANAGED` marker makes pip refuse installs), so their
    // branches installed these as distro packages. Fedora never shipped the
    // marker, so pip works as root on the RedHat family and Amazon; the
    // marker was observed on exactly the Debian, Ubuntu and Arch images and
    // on no other of the 13 (2026-10-30). The condition is "not Debian and
    // not Arch", so a host no flag matches also gets pip, as in the YAML.
    // pip itself comes from `python3-pip` in the branch above; no base image
    // has it. `GitPython` and `pyaml` always arrive by pip here (no base
    // has them); Jinja2 and PyYAML are already rpm-provided on fedora43,
    // fedora44 and rockylinux10 and pip leaves an installed copy of an
    // unpinned requirement alone, so the pip names the oracle sees depend on
    // the base. Open: almalinux9 and almalinux10 were not probed for
    // Jinja2 and PyYAML; the `pip list` capture settles them. `pyaml` is not
    // `PyYAML` (it pulls PyYAML as a dependency); keep both names as written.
    // Source: https://peps.python.org/pep-0668/ (accessed 2026-10-30)
    // Source: https://fedoraproject.org/wiki/Changes/PythonMarkExternallyManaged (accessed 2026-10-30)
    if !(debian_based(&h.os) || arch_based(&h.os)) {
        h.pip(["jinja2", "GitPython", "pyaml"]);
    }

    // The uv installer. Kept unguarded and unpinned as in the YAML: it
    // re-downloads and replaces `uv` and `uvx` on every run (observed
    // 2026-10-30: a second run on an identical version reinstalls both
    // binaries), always reports changed, and is piped from the network with no
    // checksum. Because three later playbooks re-apply this role, every later
    // image re-installs uv. The version is whatever the script carries that
    // day; the oracle compares names, not versions. `UV_INSTALL_DIR` is the
    // documented way to pick `/usr/local/bin`, giving `uv` and `uvx` and
    // nothing else. The installer edits no shell profile because that
    // directory is already on `PATH`; it does create `~/.config/uv`. Needs
    // curl: installed by the Debian branch above, shipped by the other bases
    // (observed 2026-10-30); a port that stops relying on the base image must
    // add `curl` to the other branches. The subshell keeps `pipefail` from
    // leaking into the persistent shell (Ansible ran it in its own bash).
    // The op declares `writes [*]`, so it runs after the merged apt op.
    // Source: https://docs.astral.sh/uv/reference/installer/ (accessed 2026-10-30)
    // Source: https://astral.sh/uv/install.sh (accessed 2026-10-30)
    sh!(
        h,
        "(set -o pipefail && curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh)"
    );
    Ok(())
}

// After equivalence. Each changes what the oracle sees, so each is its own
// change with its own oracle diff, made only once the 13-image oracle is
// green:
// - Remove `python3-hvac` and `python3-apt` from Debian-family images once
//   the role no longer runs under Ansible there (package list changes).
// - Make the uv install idempotent (guard on `/usr/local/bin/uv`) and pin its
//   version; prefer `UV_UNMANAGED_INSTALL` for a system install
//   (`/usr/local/bin` metadata and later images' uv version change).
// - Name the dnf group per family (ID `development-tools` on Fedora, the name
//   "Development Tools" on EL and Amazon) and decide whether the RedHat
//   group content is still wanted (package list changes on Fedora if the
//   content differs).
// - Decide whether `pyaml` is wanted, or only PyYAML (pip list changes).
// - Decide whether `python-pytest` on Arch belongs to a development base
//   (package list changes).

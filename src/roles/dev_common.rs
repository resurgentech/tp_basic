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
//! The port reaches the Ansible role's end state, with the bugs the oracle
//! cannot see fixed: the uv installer is a `pkg` with a `Script` source,
//! probed before it runs (it reran on every run and on every layer),
//! `rsync` is listed once, and the dnf group is given by
//! the id dnf5 wants on Fedora. Changes that alter what the oracle sees are
//! listed at the end of this file under "After equivalence" and are not
//! made yet.
//!
//! Intended divergence (2026-11-03, goal 5a): after uv the role installs
//! mise system-wide (`/usr/local/bin/mise`, a `Script` source), puts its
//! shims on login shells' PATH (`/etc/profile.d/mise.sh`) and installs
//! `just` through mise's system layer (the `Mise` source). The Ansible
//! original has none of it; the oracle applies the lines listed in
//! `tests/oracle/intended/<container>.txt` to the Ansible side and diffs.
//!
//! Hacks (a `sh!` or a workaround standing in for a primitive; the marker
//! is what a search for `HACK(` finds when the primitive lands):
//! - `HACK(pkg: dnf5 group id)`: the per-manager group spec in the RedHat
//!   branch; `pkg` should resolve a group's display name on dnf5.
//!
//! Equivalence (2026-10-30): the docker oracle (package names and arch,
//! system pip names, rustup state, apt sources, `/usr/local/bin` names)
//! reported ubuntu2404 and rockylinux10 identical against ansible
//! 79d1ca16bfdeb678496986e1d7a0d407b06f4b45; the 2026-10-31 matrix had
//! every distro identical except debian13 (`sq`, see src_repos) and
//! fedora43/44, which failed on the group name fixed below.
//!
//! Dropped branches, which no image reaches and which are not ported:
//! Amazon Linux 2 (its own task file), and the Debian 10 and Ubuntu 20.04
//! and 22.04 flags, which this role never read. The flags stay in the
//! Ansible `group_vars` for roles not yet ported. Consequence: an Amazon
//! Linux 2 host gets no package branch but would still take the pip step,
//! as the Ansible flags say.

use telepatch::facts::os::{Distro, Family, Os};
use telepatch::ops::pkg::{Latest, ScriptSpec};
use telepatch::{Host, TraceError, role};

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
        // `@Development Tools` is a dnf group requested by display name, and
        // no single spelling works across the branch: dnf4 (EL9, EL10)
        // resolves the display name and rejects `development-tools` (its id
        // for the group is `development`); dnf5 (fedora43 5.2.18, fedora44
        // 5.4.6) resolves group specs by id only, `development-tools`, and
        // rejects the display name ("No match for argument: Development
        // Tools"). Ansible's dnf and dnf5 modules both resolve by name through
        // the library, which is why the YAML never noticed (probed 2026-10-31
        // with `dnf install --assumeno` and `dnf group info -v` on fedora43,
        // rockylinux9, rockylinux10, almalinux10).
        // HACK(pkg: dnf5 group id): the port picks the spec per distro. The
        // fix belongs in `pkg`: resolve a `@name` through `dnf group info`
        // before rendering the install line.
        // Source: https://dnf5.readthedocs.io/en/latest/commands/install.8.html (accessed 2026-10-31)
        // Source: https://docs.ansible.com/ansible/latest/collections/ansible/builtin/dnf5_module.html (accessed 2026-10-31)
        //
        // The explicit `gcc`, `clang`, `bison`, `flex` beside the group keep a
        // compiler present whatever the group holds. Names resolve through
        // package provides, so the installed rpm name can differ from the
        // requested one (`gnupg` -> `gnupg2`, `zlib-devel` ->
        // `zlib-ng-compat-devel` on Fedora and EL10); the oracle compares
        // installed names and both sides resolve alike. EPEL and CRB, enabled
        // by `base.el` outside this repo, serve `dpkg`, `dpkg-dev`,
        // `dpkg-devel` and the `*-devel` packages (observed 2026-10-30: epel
        // on Rocky 9). Amazon below lacks the `dpkg*` names (the Amazon 2
        // task file says `dpkg-dev` was lost).
        let dev_tools = if h.os.distro == Distro::Fedora {
            "@development-tools"
        } else {
            "@Development Tools"
        };
        h.pkg([
            dev_tools,
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

    // The uv installer: intent is `uv` and `uvx` present in `/usr/local/bin`
    // for every user. The YAML ran the one-liner unguarded and unpinned, so
    // it re-downloaded and replaced both binaries on every run and on every
    // layer (three later playbooks re-apply this role), reported changed each
    // time, could not tell drift, and installed whatever version the source
    // served that day (0.13.6 on 2026-10-31). The oracle compares names, not
    // versions, so it never saw it; the `pkg` probe fixes the rerun.
    //
    // A `pkg` with a `Script` source, its five parts settled by probe on
    // 2026-10-31: binary `/usr/local/bin/uv`; installed version from
    // `uv self version --short` (prints `0.13.6`); latest from the GitHub
    // releases of `astral-sh/uv` (resolved on the host, only for
    // `.latest()`); install the YAML's one-liner; update `uv self update`.
    // Wanted is `Present` (any version), as the YAML had no pin. The op
    // posts `pkg:script:root:uv` and `file:/usr/local/bin/uv`.
    //
    // Run exactly as the YAML ran it so the oracle stays identical: with
    // `UV_INSTALL_DIR` set and `UV_NO_MODIFY_PATH` unset the installer also
    // writes `env` and `env.fish` beside the binaries (the oracle lists all
    // four names in `/usr/local/bin`) and appends `. "/usr/local/bin/env"` to
    // root's `.bashrc`, `.profile` and `.bash_profile`, which point at a
    // directory already on PATH (probed 2026-10-31 in a rockylinux9
    // container from the downloaded script). Needs curl: installed by the
    // Debian branch above, shipped by the other bases (observed 2026-10-30).
    // The subshell keeps `pipefail` from leaking into the persistent shell.
    // Non-distro sources write `*` by default, so it runs after the merged
    // apt op that installs curl.
    // Source: https://docs.astral.sh/uv/getting-started/installation/ (accessed 2026-10-31)
    // Source: https://docs.astral.sh/uv/reference/installer/ (accessed 2026-10-31)
    h.script(
        "uv",
        ScriptSpec::new()
            .bin("/usr/local/bin/uv")
            .version("uv self version --short")
            .latest(Latest::github_release("astral-sh/uv"))
            .install(
                "(set -o pipefail && curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh)",
            )
            .update("uv self update"),
    );

    // Intended divergence from the Ansible original (the role at 79d1ca1 has
    // no mise and no just), the first in a ported role: the next three ops
    // are listed line by line in `tests/oracle/intended/<container>.txt`,
    // which the oracle applies to the Ansible side before it diffs.
    //
    // The mise binary: intent is `mise` present in `/usr/local/bin` for every
    // user, the system-wide installer for tools distros package badly or
    // late. A `pkg` with a `Script` source, its five parts settled by probe
    // on 2026-11-03: binary `/usr/local/bin/mise`; installed version from
    // `mise version` (prints `2026.10.25 linux-x64 (2026-10-31)`); latest
    // from the GitHub releases of `jdx/mise` (resolved on the host, only
    // for `.latest()`; mise.run holds new releases back 24h, so it can name
    // one mise.run will not install yet); install mise.run with
    // `MISE_INSTALL_PATH` so the binary lands outside root's home; update
    // `mise self-update -y`. Wanted is `Present`, like uv; pinning it is an
    // "After equivalence" item. Needs curl, as uv does (installed by the
    // Debian branch, shipped by the other bases). The subshell keeps
    // `pipefail` from leaking into the persistent shell.
    // Source: https://mise.jdx.dev/installing-mise.html (accessed 2026-11-03)
    h.script(
        "mise",
        ScriptSpec::new()
            .bin("/usr/local/bin/mise")
            .version("mise version")
            .latest(Latest::github_release("jdx/mise"))
            .install(
                "(set -o pipefail && curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh)",
            )
            .update("mise self-update -y"),
    );

    // The system shims on every login shell's PATH: intent is that any user
    // runs a tool mise installed system-wide by its name. A shim in
    // `/usr/local/share/mise/shims` is a link to the mise binary that starts
    // the version `/etc/mise/config.toml` asks for; it works for a non-root
    // user with only that dir on PATH (probed 2026-11-03, T39's live test).
    // Login shells only (`bash -l`, `su -`, `sudo -i` and SSH logins read
    // `/etc/profile.d`); Docker `RUN` lines and non-login `bash -c` do not
    // need it, and `/etc/environment` is not edited. The whole file is
    // these two lines, mode 0644 like the other profile.d files.
    // Source: https://mise.jdx.dev/dev-tools/shims.html (accessed 2026-11-03)
    // Source: https://mise.jdx.dev/configuration.html (accessed 2026-11-03)
    h.file("/etc/profile.d/mise.sh")
        .content(
            "# mise system shims for login shells (telepatch dev_common)\nexport PATH=\"/usr/local/share/mise/shims:$PATH\"\n",
        )
        .mode(0o644);

    // `just` through mise's system layer: intent is the `just` command for
    // every user, from the shim `/usr/local/share/mise/shims/just`, not
    // `/usr/local/bin/just`. A `pkg` with the `Mise` source (root only): the
    // name is mise's registry name `just`; installed means a system install
    // under `/usr/local/share/mise/installs/just`; latest is `mise latest
    // just` on the host, only for `.latest()`; the op adds `just = "latest"`
    // to `/etc/mise/config.toml` and keeps any other line; install is `mise
    // install --system just` then `mise reshim --system`. Wanted is
    // `Present`: the first run installs the newest release and later runs
    // leave it alone (mise does not re-resolve "latest" by itself), and the
    // probe needs no network. Ansible master later added its own `just`
    // role (a pinned release binary in `/usr/local/bin`); the oracle stays
    // on 79d1ca1, which has none.
    // Source: https://mise.jdx.dev/cli/install.html (accessed 2026-11-03)
    // Source: https://mise.jdx.dev/cli/config/set.html (accessed 2026-11-03)
    h.mise(["just"]);
    Ok(())
}

// After equivalence. Each changes what the oracle sees, so each is its own
// change with its own oracle diff, made only once the 13-image oracle is
// green:
// - Remove `python3-hvac` and `python3-apt` from Debian-family images once
//   the role no longer runs under Ansible there (package list changes).
// - Set `UV_NO_MODIFY_PATH=1` on the uv installer: drops `env` and `env.fish`
//   from `/usr/local/bin` and the three root profile edits.
// - Pin uv to a version in `vars/container.toml`: `.pin(v)` on the op, with
//   the versioned installer URL `https://astral.sh/uv/$TP_WANT/install.sh`
//   as `install` (the non-gating versions diff shows it).
// - Pin the mise binary (`.pin(v)` with `MISE_VERSION` in the installer),
//   and decide whether `just` should be pinned (Ansible master pins 1.59.0)
//   or `.latest()`; both show only in the non-gating versions diff.
// - Replace pip `pyaml` with `PyYAML`, matching the Debian and Arch branches
//   (the pip section loses `pyaml`).
// - Name the dnf group per family (ID `development-tools` on Fedora, the name
//   "Development Tools" on EL and Amazon) and decide whether the RedHat
//   group content is still wanted (package list changes on Fedora if the
//   content differs).
// - Decide whether `pyaml` is wanted, or only PyYAML (pip list changes).
// - Decide whether `python-pytest` on Arch belongs to a development base
//   (package list changes).
